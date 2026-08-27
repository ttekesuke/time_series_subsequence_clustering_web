#!/usr/bin/env python3
"""Render VOICEVOX token samples and build the existing acoustic inventory."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def synthesize(engine_url: str, speaker: int, text: str) -> bytes:
    query = urllib.parse.urlencode({"text": text, "speaker": speaker})
    query_request = urllib.request.Request(
        f"{engine_url.rstrip('/')}/audio_query?{query}", method="POST"
    )
    with urllib.request.urlopen(query_request, timeout=600) as response:
        audio_query = response.read()
    request = urllib.request.Request(
        f"{engine_url.rstrip('/')}/synthesis?{urllib.parse.urlencode({'speaker': speaker})}",
        data=audio_query,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=600) as response:
        return response.read()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("tokens", type=Path, help="JSON array of {id, text, phones}")
    parser.add_argument("output", type=Path, help="Output inventory JSON")
    parser.add_argument("--engine-url", default="http://127.0.0.1:50021")
    parser.add_argument("--speaker", type=int, default=0)
    parser.add_argument("--sample-rate", type=int, default=22050)
    parser.add_argument("--dimensions", type=int, default=12)
    args = parser.parse_args()

    tokens = json.loads(args.tokens.read_text(encoding="utf-8"))
    if isinstance(tokens, dict):
        tokens = tokens.get("tokens", [])
    if not isinstance(tokens, list) or not tokens:
        raise ValueError("tokens must be a non-empty JSON array")
    sample_dir = args.output.parent / f"{args.output.stem}_samples"
    sample_dir.mkdir(parents=True, exist_ok=True)
    manifest_tokens = []
    for token in tokens:
        token_id = str(token["id"])
        text = str(token.get("text", token_id))
        wav = sample_dir / f"{token_id}.wav"
        wav.write_bytes(synthesize(args.engine_url, args.speaker, text))
        manifest_tokens.append({
            "id": token_id,
            "text": text,
            "phones": [str(phone) for phone in token.get("phones", [token_id])],
            "wavs": [wav.name],
        })
    manifest = sample_dir / "manifest.json"
    manifest.write_text(json.dumps({
        "inventory_id": args.output.stem,
        "model_id": f"voicevox-speaker-{args.speaker}",
        "tokens": manifest_tokens,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    subprocess.run([
        sys.executable, str(Path(__file__).with_name("build_voice_inventory.py")),
        str(manifest), str(args.output), "--sample-rate", str(args.sample_rate),
        "--dimensions", str(args.dimensions),
    ], check=True)


if __name__ == "__main__":
    main()