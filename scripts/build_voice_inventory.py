#!/usr/bin/env python3
"""Build a normalized VOICEVOX voice-token inventory from offline WAV samples.

Input manifest example:
{
  "inventory_id": "my_ja_voice",
    "model_id": "my-voicevox-speaker",
  "tokens": [
    {"id": "a", "text": "あ", "phones": ["a"], "wavs": ["samples/a_64.wav"]}
  ]
}
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import librosa
import numpy as np


def acoustic_features(path: Path, sample_rate: int) -> np.ndarray:
    audio, _ = librosa.load(path, sr=sample_rate, mono=True)
    audio, _ = librosa.effects.trim(audio, top_db=45)
    if audio.size == 0:
        raise ValueError(f"empty audio: {path}")
    rms = float(np.sqrt(np.mean(audio * audio)))
    if rms > 1e-8:
        audio = audio * (0.1 / rms)

    mfcc = librosa.feature.mfcc(y=audio, sr=sample_rate, n_mfcc=13)
    centroid = librosa.feature.spectral_centroid(y=audio, sr=sample_rate)
    flatness = librosa.feature.spectral_flatness(y=audio)
    rolloff = librosa.feature.spectral_rolloff(y=audio, sr=sample_rate)
    zcr = librosa.feature.zero_crossing_rate(audio)
    duration = np.array([audio.size / sample_rate], dtype=np.float64)
    return np.concatenate(
        [
            np.mean(mfcc, axis=1),
            np.std(mfcc, axis=1),
            np.mean(centroid, axis=1) / sample_rate,
            np.std(centroid, axis=1) / sample_rate,
            np.mean(flatness, axis=1),
            np.std(flatness, axis=1),
            np.mean(rolloff, axis=1) / sample_rate,
            np.std(rolloff, axis=1) / sample_rate,
            np.mean(zcr, axis=1),
            np.std(zcr, axis=1),
            duration,
        ]
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--dimensions", type=int, default=12)
    parser.add_argument("--sample-rate", type=int, default=22050)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    root = args.manifest.parent
    token_rows: list[np.ndarray] = []
    tokens = manifest.get("tokens", [])
    if not tokens:
        raise ValueError("manifest must contain tokens")

    for token in tokens:
        sample_rows = [
            acoustic_features((root / wav).resolve(), args.sample_rate)
            for wav in token.get("wavs", [])
        ]
        if not sample_rows:
            raise ValueError(f"token {token.get('id')} has no wavs")
        token_rows.append(np.median(np.stack(sample_rows), axis=0))

    matrix = np.stack(token_rows)
    median = np.median(matrix, axis=0)
    q25, q75 = np.percentile(matrix, [25, 75], axis=0)
    scale = np.where((q75 - q25) > 1e-9, q75 - q25, 1.0)
    standardized = (matrix - median) / scale

    _, singular_values, vt = np.linalg.svd(standardized, full_matrices=False)
    dimensions = max(1, min(args.dimensions, vt.shape[0], len(tokens)))
    projected = standardized @ vt[:dimensions].T
    low = np.min(projected, axis=0)
    high = np.max(projected, axis=0)
    width = np.where((high - low) > 1e-9, high - low, 1.0)
    normalized = np.clip((projected - low) / width, 0.0, 1.0)

    result_tokens = []
    for token, embedding in zip(tokens, normalized):
        result_tokens.append(
            {
                "id": str(token["id"]),
                "text": str(token.get("text", token["id"])),
                "phones": [str(phone) for phone in token["phones"]],
                "embedding": [round(float(value), 8) for value in embedding],
            }
        )

    total_variance = float(np.sum(singular_values**2))
    retained_variance = float(np.sum(singular_values[:dimensions] ** 2))
    output = {
        "inventory_id": str(manifest["inventory_id"]),
        "model_id": str(manifest.get("model_id", "unknown")),
        "feature_version": "voicevox-wav-mfcc-pca-v1",
        "source": "measured from target VOICEVOX WAV samples",
        "dimensions": dimensions,
        "explained_variance_ratio": retained_variance / total_variance if total_variance else 1.0,
        "tokens": result_tokens,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
