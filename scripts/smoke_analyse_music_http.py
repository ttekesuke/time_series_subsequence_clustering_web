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


def post(payload):
    request = urllib.request.Request(
        BASE + "/api/web/time_series/analyse_music",
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
    command = [
        "julia", "--project=.", "-e",
        f'using Genie; Genie.loadapp(); Genie.up({PORT}, "127.0.0.1"; async=false)',
    ]
    with tempfile.TemporaryFile(mode="w+t") as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 120
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
            status, raw, result = post(payload)
            elapsed = time.monotonic() - started
            assert status == 200, (status, result)
            assert result["timing"]["stepCount"] == 2, result["timing"]
            assert result["dimensionOrder"][0] == "note"
            assert len(result["dimensions"]["note"]["values"]["global"]) == 2
            assert len(result["pianoRoll"]["streams"]) == 1
            assert "compressedClusters" in result["dimensions"]["note"]
            assert elapsed < 60, f"short MusicAnalyse HTTP response took {elapsed:.1f}s"

            invalid = {"analyse_music": {"source_type": "upload", "filename": "wrong.txt",
                                         "musicxml_text": XML}}
            error_status, _, error = post(invalid)
            assert error_status == 422 and error["code"] == "unsupported_file_type", error
            print(f"analyse_music_http,sha={os.getenv('GITHUB_SHA', 'local')},"
                  f"steps=2,response_bytes={len(raw)},elapsed_s={elapsed:.3f},invalid_status={error_status}")
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
