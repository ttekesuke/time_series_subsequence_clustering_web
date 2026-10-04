"""Measure MusicAnalyse job compute/serialize/transfer time without CI-running a long score."""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path


TERMINAL_STATES = {"completed", "failed", "cancelled", "interrupted"}


def post_json(base_url: str, path: str, payload: dict, timeout: float = 90.0):
    request = urllib.request.Request(
        base_url.rstrip("/") + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
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


def post_raw(base_url: str, path: str, payload: dict, timeout: float = 90.0):
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


def cancel_job(base_url: str, job_id: str) -> None:
    try:
        post_json(
            base_url,
            "/api/web/time_series/analyse_music_job_cancel",
            {"job_id": job_id},
            timeout=15,
        )
    except Exception:
        pass


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Run one persisted MusicAnalyse job and print compute, serialize, "
            "result-transfer, result bytes, and peak RSS separately."
        )
    )
    parser.add_argument("musicxml", nargs="?", type=Path, help="Local MusicXML file to analyse")
    parser.add_argument(
        "--asap-path",
        help="ASAP repository-relative MusicXML path, e.g. Bach/Fugue/bwv_846/xml_score.musicxml",
    )
    parser.add_argument("--asap-composer", default="")
    parser.add_argument("--asap-folder", default="")
    parser.add_argument(
        "--base-url",
        default=os.getenv("ANALYSE_MUSIC_BASE_URL", "http://127.0.0.1:8000"),
    )
    parser.add_argument("--poll-interval", type=float, default=1.0)
    parser.add_argument("--timeout", type=float, default=4 * 60 * 60)
    parser.add_argument("--request-timeout", type=float, default=120.0)
    parser.add_argument("--merge-threshold-ratio", type=float, default=0.02)
    parser.add_argument("--expected-steps", type=int)
    parser.add_argument("--full-cluster-view", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    if bool(args.musicxml) == bool(args.asap_path):
        parser.error("Specify exactly one of local musicxml or --asap-path")

    if args.asap_path:
        asap_path = str(args.asap_path).replace("\\", "/").strip("/")
        parts = [part for part in asap_path.split("/") if part]
        composer = args.asap_composer or (parts[0] if parts else "")
        folder = args.asap_folder or "/".join(parts[:-1])
        payload = {
            "analyse_music": {
                "source_type": "asap",
                "filename": parts[-1] if parts else "xml_score.musicxml",
                "composer": composer,
                "folder": folder,
                "xml_score": asap_path,
                "compact_cluster_view": not args.full_cluster_view,
                "merge_threshold_ratio": args.merge_threshold_ratio,
            }
        }
        benchmark_name = asap_path
    else:
        xml_path = args.musicxml.resolve()
        xml_text = xml_path.read_text(encoding="utf-8")
        benchmark_name = xml_path.name
        payload = {
            "analyse_music": {
                "source_type": "upload",
                "filename": benchmark_name,
                "musicxml_text": xml_text,
                "compact_cluster_view": not args.full_cluster_view,
                "merge_threshold_ratio": args.merge_threshold_ratio,
            }
        }

    wall_started = time.monotonic()
    status_code, _, started, _ = post_json(
        args.base_url,
        "/api/web/time_series/analyse_music_job_start",
        payload,
        timeout=args.request_timeout,
    )
    if status_code != 200:
        raise RuntimeError(f"job start failed HTTP {status_code}: {started}")

    job_id = str(started["jobId"])
    deadline = wall_started + args.timeout
    last_progress = None

    try:
        poll_retry_count = 0
        while True:
            try:
                status_code, _, status, _ = post_json(
                    args.base_url,
                    "/api/web/time_series/analyse_music_job_status",
                    {"job_id": job_id},
                    timeout=args.request_timeout,
                )
            except (TimeoutError, urllib.error.URLError, ConnectionError, OSError) as exc:
                poll_retry_count += 1
                if time.monotonic() >= deadline:
                    cancel_job(args.base_url, job_id)
                    raise TimeoutError(
                        f"MusicAnalyse job timed out after {args.timeout:.1f}s "
                        f"while polling status ({poll_retry_count} transient poll failures)"
                    ) from exc
                if not args.quiet:
                    print(
                        "poll_retry,"
                        f"count={poll_retry_count},error={type(exc).__name__}: {exc}",
                        flush=True,
                    )
                time.sleep(max(args.poll_interval, 0.05))
                continue

            if status_code != 200:
                raise RuntimeError(f"status failed HTTP {status_code}: {status}")

            state = str(status.get("status", ""))
            progress = (
                state,
                str(status.get("phase", "")),
                str(status.get("label", "")),
                int(status.get("processed") or 0),
                int(status.get("total") or 0),
                int(status.get("percent") or 0),
            )
            if not args.quiet and progress != last_progress:
                print(
                    "progress,"
                    f"status={progress[0]},phase={progress[1]},label={progress[2]},"
                    f"processed={progress[3]},total={progress[4]},percent={progress[5]}",
                    flush=True,
                )
                last_progress = progress

            if state in TERMINAL_STATES:
                break
            if time.monotonic() >= deadline:
                cancel_job(args.base_url, job_id)
                raise TimeoutError(f"MusicAnalyse job timed out after {args.timeout:.1f}s")
            time.sleep(max(args.poll_interval, 0.05))

        if state != "completed":
            raise RuntimeError(
                f"MusicAnalyse job ended as {state}: "
                f"{status.get('errorCode')} {status.get('errorMessage')}"
            )

        transfer_started = time.monotonic()
        result_status, result_raw, result_headers = post_raw(
            args.base_url,
            "/api/web/time_series/analyse_music_job_result",
            {"job_id": job_id},
            timeout=args.request_timeout,
        )
        transfer_s = time.monotonic() - transfer_started
        if result_status != 200:
            raise RuntimeError(
                f"result failed HTTP {result_status}: "
                f"{result_raw.decode('utf-8', errors='replace')}"
            )

        result = json.loads(result_raw)
        wall_s = time.monotonic() - wall_started
        timing = result.get("timing", {}) if isinstance(result, dict) else {}
        step_count = timing.get("stepCount")
        if args.expected_steps is not None and step_count != args.expected_steps:
            raise AssertionError(
                f"expected stepCount={args.expected_steps}, got {step_count}"
            )

        metrics = {
            "job_id": job_id,
            "filename": benchmark_name,
            "step_count": step_count,
            "processing_seconds": status.get("processingSeconds"),
            "serialize_seconds": status.get("serializeSeconds"),
            "result_bytes_status": status.get("resultBytes"),
            "peak_rss_bytes": status.get("peakRssBytes"),
            "result_transfer_seconds": round(transfer_s, 6),
            "result_response_bytes": len(result_raw),
            "result_bytes_header": int(
                header(result_headers, "X-Analysis-Result-Bytes", "0") or 0
            ),
            "result_read_ms_header": float(
                header(result_headers, "X-Analysis-Result-Read-Ms", "0") or 0
            ),
            "wall_seconds": round(wall_s, 6),
            "poll_retry_count": poll_retry_count,
            "compact_cluster_view": not args.full_cluster_view,
            "merge_threshold_ratio": args.merge_threshold_ratio,
        }

        print("analyse_music_job_benchmark=" + json.dumps(metrics, ensure_ascii=False))
    except KeyboardInterrupt:
        cancel_job(args.base_url, job_id)
        raise


if __name__ == "__main__":
    main()
