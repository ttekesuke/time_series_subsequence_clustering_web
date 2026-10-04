"""Benchmark the audit-baseline base64 render path without changing its render logic."""

from __future__ import annotations

import argparse
import base64
import json
import math
import os
import time
import urllib.error
import urllib.request


def peak_rss_bytes() -> int:
    try:
        with open("/proc/self/status", "r", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("VmHWM:"):
                    parts = line.split()
                    return int(parts[1]) * 1024 if len(parts) >= 2 else 0
    except (OSError, ValueError):
        pass
    return 0


def post_json(base_url: str, path: str, payload: dict, method: str = "POST", timeout: float = 3600.0):
    req = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read()
            return response.status, raw, json.loads(raw)
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            body = {"raw": raw.decode("utf-8", errors="replace")}
        return exc.code, raw, body


def build_payload(steps: int, bpm: float, text: str) -> dict:
    voice = [[60], 0.8, 0.5, 0.1, 0.8, 0.1, 0.3, 0.6, 0.0, 0.0, 0.0]
    return {
        "time_series": [[voice] for _ in range(steps)],
        "stream_ids": [[1] for _ in range(steps)],
        "voice_plan": [[{"streamId": 1, "mode": "voice", "text": text}] for _ in range(steps)],
        "bpm": bpm,
        "future_bpm": [bpm] * steps,
        "tail_pad_seconds": 0.05,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=os.getenv("RENDER_BENCHMARK_BASE_URL", "http://127.0.0.1:19116"))
    parser.add_argument("--steps", type=int, default=500)
    parser.add_argument("--bpm", type=float, default=240.0)
    parser.add_argument("--text", default="あ")
    parser.add_argument("--timeout", type=float, default=3600.0)
    args = parser.parse_args()

    if args.steps <= 0:
        parser.error("--steps must be positive")
    if not math.isfinite(args.bpm) or args.bpm <= 0:
        parser.error("--bpm must be a positive finite number")

    payload = build_payload(args.steps, args.bpm, args.text)
    started = time.monotonic()
    status, raw, result = post_json(
        args.base_url,
        "/api/web/supercolliders/render_polyphonic",
        payload,
        timeout=args.timeout,
    )
    render_seconds = time.monotonic() - started
    if status != 200:
        raise RuntimeError(f"render failed HTTP {status}: {result}")
    if result.get("error"):
        raise RuntimeError(f"render failed: {result['error']}")

    audio_data = str(result.get("audio_data", ""))
    if "," in audio_data:
        audio_data = audio_data.split(",", 1)[1]
    if not audio_data:
        raise RuntimeError("missing audio_data")

    decoded = base64.b64decode(audio_data.encode("ascii"))
    if len(decoded) <= 44 or decoded[:4] != b"RIFF" or decoded[8:12] != b"WAVE":
        raise RuntimeError(f"invalid decoded WAV: {len(decoded)} bytes")

    metrics = {
        "mode": "voice",
        "steps": args.steps,
        "bpm": args.bpm,
        "estimated_duration_seconds": round(args.steps * 60.0 / args.bpm + 0.05, 6),
        "render_seconds": round(render_seconds, 6),
        "render_response_bytes": len(raw),
        "final_audio_bytes": len(decoded),
        "final_audio_base64_chars": len(audio_data),
        "client_peak_rss_bytes": peak_rss_bytes(),
        "wall_seconds": round(time.monotonic() - started, 6),
    }
    print("legacy_render_audio_benchmark=" + json.dumps(metrics, ensure_ascii=False))

    cleanup = {
        "cleanup": {
            "scd_file_path": result.get("scd_file_path", ""),
            "sound_file_path": result.get("sound_file_path", ""),
        }
    }
    try:
        post_json(args.base_url, "/api/web/supercolliders/cleanup", cleanup, method="DELETE", timeout=30)
    except Exception:
        pass


if __name__ == "__main__":
    main()
