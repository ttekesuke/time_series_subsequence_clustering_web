"""Measure binary polyphonic render transfer and memory metrics over HTTP."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request


def request_json(base_url: str, path: str, payload: dict, method: str = "POST", timeout: float = 3600.0):
    request = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            return response.status, raw, json.loads(raw), dict(response.headers.items())
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError:
            decoded = {"raw": raw.decode("utf-8", errors="replace")}
        return exc.code, raw, decoded, dict(exc.headers.items())


def request_binary(base_url: str, path: str, payload: dict, timeout: float = 3600.0):
    request = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read(), dict(response.headers.items())
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(), dict(exc.headers.items())


def header(headers: dict[str, str], name: str, default: str = "") -> str:
    wanted = name.lower()
    for key, value in headers.items():
        if key.lower() == wanted:
            return value
    return default


def process_peak_rss_bytes() -> int:
    status_path = "/proc/self/status"
    try:
        with open(status_path, "r", encoding="utf-8") as handle:
            for line in handle:
                if not line.startswith("VmHWM:"):
                    continue
                fields = line.split()
                return int(fields[1]) * 1024 if len(fields) >= 2 else 0
    except (OSError, ValueError):
        return 0
    return 0


def legacy_base64_bytes(raw_bytes: int) -> int:
    raw_bytes = max(0, int(raw_bytes))
    return 4 * math.ceil(raw_bytes / 3) if raw_bytes else 0


def build_payload(steps: int, bpm: float, mode: str, text: str) -> dict:
    voice = [[60], 0.8, 0.5, 0.1, 0.8, 0.1, 0.3, 0.6, 0.0, 0.0, 0.0]
    time_series = [[voice] for _ in range(steps)]
    stream_ids = [[1] for _ in range(steps)]
    if mode == "voice":
        voice_plan = [[{"streamId": 1, "mode": "voice", "text": text}] for _ in range(steps)]
    else:
        voice_plan = [[{"streamId": 1, "mode": "synth", "text": None}] for _ in range(steps)]

    return {
        "time_series": time_series,
        "stream_ids": stream_ids,
        "voice_plan": voice_plan,
        "bpm": bpm,
        "future_bpm": [bpm] * steps,
        "tail_pad_seconds": 0.05,
        "return_audio_base64": False,
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Render a deterministic long polyphonic fixture and print binary-transfer "
            "bytes/RSS metrics as one JSON line."
        )
    )
    parser.add_argument(
        "--base-url",
        default=os.getenv("RENDER_BENCHMARK_BASE_URL", "http://127.0.0.1:9111"),
    )
    parser.add_argument("--mode", choices=("synth", "voice"), default="voice")
    parser.add_argument("--steps", type=int, default=500)
    parser.add_argument("--bpm", type=float, default=240.0)
    parser.add_argument("--text", default="あ")
    parser.add_argument("--timeout", type=float, default=3600.0)
    args = parser.parse_args()

    if args.steps <= 0:
        parser.error("--steps must be positive")
    if not math.isfinite(args.bpm) or args.bpm <= 0:
        parser.error("--bpm must be a positive finite number")
    if args.mode == "voice" and not args.text.strip():
        parser.error("--text must be non-empty in voice mode")

    payload = build_payload(args.steps, args.bpm, args.mode, args.text)
    wall_started = time.monotonic()
    render_started = time.monotonic()
    status, render_raw, render_result, _ = request_json(
        args.base_url,
        "/api/web/supercolliders/render_polyphonic",
        payload,
        timeout=args.timeout,
    )
    render_seconds = time.monotonic() - render_started
    if status != 200:
        raise RuntimeError(f"render_polyphonic failed HTTP {status}: {render_result}")
    if render_result.get("error"):
        raise RuntimeError(f"render_polyphonic failed: {render_result['error']}")

    job_id = str(render_result.get("render_job_id", ""))
    if not job_id:
        raise RuntimeError("render_polyphonic returned no render_job_id")

    try:
        client_peak_before_audio = process_peak_rss_bytes()
        transfer_started = time.monotonic()
        audio_status, audio_raw, audio_headers = request_binary(
            args.base_url,
            "/api/web/supercolliders/render_audio",
            {"render_job_id": job_id},
            timeout=args.timeout,
        )
        transfer_seconds = time.monotonic() - transfer_started
        client_peak_after_audio = process_peak_rss_bytes()

        if audio_status != 200:
            raise RuntimeError(
                f"render_audio failed HTTP {audio_status}: "
                f"{audio_raw.decode('utf-8', errors='replace')}"
            )
        if len(audio_raw) <= 44 or audio_raw[:4] != b"RIFF" or audio_raw[8:12] != b"WAVE":
            raise RuntimeError(f"render_audio returned invalid WAV ({len(audio_raw)} bytes)")

        final_audio_bytes_header = int(header(audio_headers, "X-Audio-Bytes", "0") or 0)
        final_server_peak_rss = int(
            header(audio_headers, "X-Server-Peak-Rss-Bytes", "0") or 0
        )
        voice_audio_bytes = int(render_result.get("voiceAudioBytes") or 0)

        metrics = {
            "mode": args.mode,
            "steps": args.steps,
            "bpm": args.bpm,
            "estimated_duration_seconds": round(args.steps * 60.0 / args.bpm + 0.05, 6),
            "render_seconds": round(render_seconds, 6),
            "render_response_bytes": len(render_raw),
            "voice_stem_count": int(render_result.get("voiceStemCount") or 0),
            "voice_audio_bytes": voice_audio_bytes,
            "voice_worker_peak_rss_bytes": int(
                render_result.get("voiceWorkerPeakRssBytes") or 0
            ),
            "voice_julia_peak_rss_bytes": int(
                render_result.get("voiceJuliaPeakRssBytes") or 0
            ),
            "final_audio_transfer_seconds": round(transfer_seconds, 6),
            "final_audio_bytes": len(audio_raw),
            "final_audio_bytes_header": final_audio_bytes_header,
            "final_server_peak_rss_bytes": final_server_peak_rss,
            "client_peak_rss_before_audio_bytes": client_peak_before_audio,
            "client_peak_rss_after_audio_bytes": client_peak_after_audio,
            "legacy_voice_base64_transport_bytes_estimate": legacy_base64_bytes(
                voice_audio_bytes
            ),
            "legacy_final_base64_transport_bytes_estimate": legacy_base64_bytes(
                len(audio_raw)
            ),
            "wall_seconds": round(time.monotonic() - wall_started, 6),
        }
        print("render_audio_benchmark=" + json.dumps(metrics, ensure_ascii=False))
    finally:
        try:
            request_json(
                args.base_url,
                "/api/web/supercolliders/cleanup",
                {"cleanup": {"render_job_id": job_id}},
                method="DELETE",
                timeout=30,
            )
        except Exception as cleanup_error:
            print(f"cleanup_failed={cleanup_error}", file=sys.stderr)


if __name__ == "__main__":
    main()
