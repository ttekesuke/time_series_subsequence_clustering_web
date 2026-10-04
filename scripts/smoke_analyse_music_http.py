"""Bounded route/JSON smoke test for MusicAnalyse; no ASAP dataset is needed."""

import json
import os
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PORT = 19113
BASE = f"http://127.0.0.1:{PORT}"
XML = """<score-partwise version="4.0">
<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
<part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice></note>
<note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice></note>
</measure></part></score-partwise>"""


def post(path, payload):
    request = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            raw = response.read()
            return response.status, raw, json.loads(raw)
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        return exc.code, raw, json.loads(raw)


def main():
    env = os.environ.copy()
    env["GENIE_ENV"] = "test"
    env["HOST"] = "127.0.0.1"
    env["PORT"] = str(PORT)
    env["CLUSTERING_QUERY_ENABLED"] = "false"
    env["STARTUP_WARMUP_ENABLED"] = "false"
    command = ["julia", "--project=.", "scripts/start_server.jl"]
    with tempfile.TemporaryFile(mode="w+t") as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"Genie exited with {process.returncode}")
                try:
                    with urllib.request.urlopen(BASE + "/api/health", timeout=1) as response:
                        if response.status == 200:
                            break
                except (urllib.error.URLError, TimeoutError):
                    time.sleep(0.5)
            else:
                raise TimeoutError("Genie did not become ready")

            payload = {"analyse_music": {"source_type": "upload", "filename": "short.musicxml",
                                          "musicxml_text": XML, "compact_cluster_view": True}}
            started = time.monotonic()
            status, raw, result = post("/api/web/time_series/analyse_music", payload)
            elapsed = time.monotonic() - started
            assert status == 200, (status, result)
            assert result["timing"]["stepCount"] == 2, result["timing"]
            assert result["dimensionOrder"][0] == "note"
            assert len(result["dimensions"]["note"]["values"]["global"]) == 2
            assert len(result["pianoRoll"]["streams"]) == 1
            assert "compressedClusters" in result["dimensions"]["note"]
            assert elapsed < 60, f"short MusicAnalyse HTTP response took {elapsed:.1f}s"

            job_status_code, _, job_start = post(
                "/api/web/time_series/analyse_music_job_start", payload)
            assert job_status_code == 200, (job_status_code, job_start)
            job_id = job_start["jobId"]
            job_started = time.monotonic()
            while True:
                poll_status, _, job_status = post(
                    "/api/web/time_series/analyse_music_job_status",
                    {"job_id": job_id},
                )
                assert poll_status == 200, (poll_status, job_status)
                if job_status["status"] == "completed":
                    break
                if job_status["status"] in ("failed", "cancelled", "interrupted"):
                    raise AssertionError(job_status)
                if time.monotonic() - job_started > 60:
                    raise TimeoutError(f"MusicAnalyse job timed out: {job_status}")
                time.sleep(0.05)

            result_status, job_raw, job_result = post(
                "/api/web/time_series/analyse_music_job_result",
                {"job_id": job_id},
            )
            assert result_status == 200, (result_status, job_result)
            for key in (
                "metadata", "timing", "streams", "pianoRoll", "dimensionOrder",
                "dimensions", "streamCountSeries", "soundingNoteCountSeries",
            ):
                assert job_result[key] == result[key], key
            assert job_status["resultBytes"] == len(job_raw)
            assert job_status["serializeSeconds"] >= 0
            assert job_status["peakRssBytes"] >= 0

            invalid = {"analyse_music": {"source_type": "upload", "filename": "wrong.txt",
                                         "musicxml_text": XML}}
            error_status, _, error = post("/api/web/time_series/analyse_music", invalid)
            assert error_status == 422 and error["code"] == "unsupported_file_type", error
            print(f"analyse_music_http,sha={os.getenv('GITHUB_SHA', 'local')},"
                  f"steps=2,response_bytes={len(raw)},elapsed_s={elapsed:.3f},invalid_status={error_status},"
                  f"job_bytes={len(job_raw)},job_elapsed_s={time.monotonic() - job_started:.3f},"
                  f"job_serialize_s={job_status['serializeSeconds']},peak_rss_bytes={job_status['peakRssBytes']}")
        except Exception:
            log.seek(0)
            print(log.read()[-12000:])
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":
    main()
