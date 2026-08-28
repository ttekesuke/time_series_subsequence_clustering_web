#!/usr/bin/env python3
"""Small HTTP boundary around the VOICEVOX Engine talk and Song APIs."""

from __future__ import annotations

import base64
import json
import os
import pathlib
import tempfile
import urllib.parse
import urllib.error
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


ENGINE_URL = os.getenv("VOICEVOX_ENGINE_URL", "http://voicevox:50021").rstrip("/")
SPEAKER = int(os.getenv("VOICEVOX_SPEAKER", "0"))
SINGING_TEACHER = int(os.getenv("VOICEVOX_SINGING_TEACHER", "6000"))
SINGER = int(os.getenv("VOICEVOX_SINGER", "3003"))
RENDER_MODE = os.getenv("VOICEVOX_RENDER_MODE", "sing").strip().lower()
MAX_BODY_BYTES = int(os.getenv("VOICEVOX_MAX_BODY_BYTES", str(32 * 1024 * 1024)))
DEFAULT_FRAME_RATE = 93.75
_frame_rate: float | None = None


def _validate_request(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, dict) or not isinstance(raw.get("stems"), list):
        raise ValueError("stems must be a non-empty array")
    stems = []
    for stem in raw["stems"]:
        if not isinstance(stem, dict):
            raise ValueError("each stem must be an object")
        stream_id = int(stem["stream_id"])
        start_time = float(stem.get("start_time", 0.0))
        if start_time < 0.0:
            raise ValueError("start_time must be non-negative")
        segments = stem.get("segments")
        if not isinstance(segments, list) or not segments:
            raise ValueError(f"stream {stream_id} has no segments")
        clean = []
        for segment in segments:
            if not isinstance(segment, dict):
                raise ValueError("each segment must be an object")
            text = str(segment.get("text", "")).strip()
            duration = float(segment.get("duration", 0.0))
            if not text or duration <= 0.0:
                raise ValueError("segment text and positive duration are required")
            clean.append({"text": text, "duration": duration})
        controls = stem.get("controls", [])
        if not isinstance(controls, list) or len(controls) != len(clean):
            raise ValueError(f"stream {stream_id} controls must match segments")
        clean_controls = []
        for control in controls:
            if not isinstance(control, dict):
                raise ValueError("each control must be an object")
            clean_controls.append({"time": float(control.get("time", start_time)), "carrier_note": control.get("carrier_note")})
        stems.append({"stream_id": stream_id, "start_time": start_time, "segments": clean, "controls": clean_controls})
    if not stems:
        raise ValueError("stems must be a non-empty array")
    return stems


def _wav_duration(data: bytes) -> float:
    with wave.open(__import__("io").BytesIO(data), "rb") as wav:
        return wav.getnframes() / float(wav.getframerate())


def _fit_wav(data: bytes, duration: float, params: tuple) -> bytes:
    frame_count = max(0, round(duration * params.framerate))
    with wave.open(__import__("io").BytesIO(data), "rb") as source:
        frames = source.readframes(frame_count)
    expected_bytes = frame_count * params.sampwidth * params.nchannels
    return frames[:expected_bytes].ljust(expected_bytes, b"\0")


def _post_json(path: str, payload: dict[str, Any], query: dict[str, Any]) -> bytes:
    request = urllib.request.Request(
        f"{ENGINE_URL}{path}?{urllib.parse.urlencode(query)}",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace").strip()
        raise RuntimeError(f"VOICEVOX {path} returned HTTP {exc.code}: {detail or exc.reason}") from exc


def _synthesize_talk(text: str) -> bytes:
    query_url = f"{ENGINE_URL}/audio_query?{urllib.parse.urlencode({'text': text, 'speaker': SPEAKER})}"
    request = urllib.request.Request(query_url, method="POST")
    with urllib.request.urlopen(request, timeout=600) as response:
        query = json.loads(response.read().decode("utf-8"))
    return _post_json("/synthesis", query, {"speaker": SPEAKER})


def _song_frame_rate() -> float:
    global _frame_rate
    if _frame_rate is None:
        try:
            with urllib.request.urlopen(f"{ENGINE_URL}/engine_manifest", timeout=10) as response:
                _frame_rate = float(json.loads(response.read().decode("utf-8")).get("frame_rate", DEFAULT_FRAME_RATE))
        except Exception:
            _frame_rate = DEFAULT_FRAME_RATE
    return _frame_rate


def _song_notes(segments: list[dict[str, Any]], controls: list[dict[str, Any]], start_time: float) -> list[dict[str, Any]]:
    """Make a monophonic Song score with drift-free frame quantization."""
    frame_rate = _song_frame_rate()
    # The Engine's Song implementation currently raises an internal array-size
    # error when the obligatory initial rest is one frame and the first lyric
    # starts with a consonant. Two frames is its smallest safe lead-in.
    cursor_frame = max(2, round(start_time * frame_rate))
    notes = [{"key": None, "frame_length": cursor_frame, "lyric": ""}]
    cursor = start_time
    for segment, control in zip(segments, controls):
        time = max(cursor, float(control.get("time", cursor)))
        time_frame = round(time * frame_rate)
        gap_frames = time_frame - cursor_frame
        # Floating-point accumulation can create a phantom 1-frame rest between
        # adjacent steps. The Song Engine rejects a <=1-frame pause followed by
        # a consonant mora, so ignore sub-frame drift and make real rests safe.
        if gap_frames >= 2:
            notes.append({"key": None, "frame_length": gap_frames, "lyric": ""})
            cursor_frame += gap_frames
        key = int(control.get("carrier_note", 60) or 60)
        # Song's Score.key is a MIDI note. Keep the composition pitch intact;
        # any singer-specific range shift must be an explicit f0 adjustment.
        end_time = time + float(segment["duration"])
        end_frame = round(end_time * frame_rate)
        note_frames = max(2, end_frame - cursor_frame)
        notes.append({"key": max(0, min(127, key)), "frame_length": note_frames, "lyric": segment["text"]})
        cursor_frame += note_frames
        cursor = end_time
    notes.append({"key": None, "frame_length": max(1, round(0.05 * frame_rate)), "lyric": ""})
    return notes


def _synthesize_song(segments: list[dict[str, Any]], controls: list[dict[str, Any]], start_time: float) -> bytes:
    score = {"notes": _song_notes(segments, controls, start_time)}
    query = json.loads(_post_json("/sing_frame_audio_query", score, {"speaker": SINGING_TEACHER}).decode("utf-8"))
    return _post_json("/frame_synthesis", query, {"speaker": SINGER})


def _render_stem(segments: list[dict[str, Any]], controls: list[dict[str, Any]], start_time: float) -> tuple[bytes, str]:
    if RENDER_MODE == "talk":
        audio, backend = _synthesize_talk("".join(segment["text"] for segment in segments)), "voicevox-talk"
    elif RENDER_MODE == "sing":
        audio, backend = _synthesize_song(segments, controls, start_time), "voicevox-song"
    else:
        raise ValueError("VOICEVOX_RENDER_MODE must be 'sing' or 'talk'")
    with wave.open(__import__("io").BytesIO(audio), "rb") as first:
        params = first.getparams()
    if RENDER_MODE == "talk":
        silence_frames = max(0, round(start_time * params.framerate))
        rendered = b"\0" * (silence_frames * params.sampwidth * params.nchannels)
        rendered += _fit_wav(audio, sum(float(segment["duration"]) for segment in segments), params)
    else:
        # The Song Engine works in 93.75 Hz frames. Trim/pad the rendered WAV
        # to the original step timeline so frame rounding cannot slow a long
        # 0.125-second (BPM 480) sequence by seconds.
        total_duration = max(float(control.get("time", start_time)) + float(segment["duration"]) for segment, control in zip(segments, controls))
        rendered = _fit_wav(audio, total_duration, params)
    output = __import__("io").BytesIO()
    with wave.open(output, "wb") as target:
        target.setparams(params)
        target.writeframes(rendered)
    return output.getvalue(), backend


class Handler(BaseHTTPRequestHandler):
    server_version = "VoicevoxWorker/1.0"

    def _json(self, status: int, body: dict[str, Any]) -> None:
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:  # noqa: N802
        self._json(200 if self.path == "/health" else 404, {"status": "ok", "backend": "voicevox"} if self.path == "/health" else {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/render":
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY_BYTES:
                raise ValueError("invalid request size")
            stems = _validate_request(json.loads(self.rfile.read(length).decode("utf-8")))
            print(f"[voicevox-worker] render request stems={len(stems)} streams={[stem['stream_id'] for stem in stems]} start_times={[stem['start_time'] for stem in stems]} segments={[(segment['text'], segment['duration']) for stem in stems for segment in stem['segments']]} song_keys={[max(0, min(127, int(control.get('carrier_note', 60) or 60))) for stem in stems for control in stem['controls']]}", flush=True)
            rendered = []
            for stem in stems:
                audio, backend = _render_stem(stem["segments"], stem["controls"], stem["start_time"])
                rendered.append({"stream_id": stem["stream_id"], "audio_base64": base64.b64encode(audio).decode("ascii"), "backend": backend})
            print(f"[voicevox-worker] render complete bytes={[len(base64.b64decode(item['audio_base64'])) for item in rendered]}", flush=True)
            self._json(200, {"backend": rendered[0]["backend"] if rendered else "voicevox", "stems": rendered})
        except Exception as exc:
            self._json(400, {"error": str(exc)})


def main() -> None:
    host = os.getenv("VOICEVOX_WORKER_HOST", "0.0.0.0")
    port = int(os.getenv("VOICEVOX_WORKER_PORT", "9120"))
    ThreadingHTTPServer((host, port), Handler).serve_forever()


if __name__ == "__main__":
    main()
