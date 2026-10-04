"""Local HTTP tests; no VOICEVOX Engine or network service is required."""

import json
import io
import unittest
from unittest import mock

import worker


def stem(stream_id=1):
    return {
        "stream_id": stream_id,
        "start_time": 0.0,
        "segments": [{"text": "あ", "duration": 0.2}],
        "controls": [{"time": 0.0, "carrier_note": 60}],
    }


class WorkerHttpTests(unittest.TestCase):
    def post_raw(self, body, path="/render"):
        data = json.dumps(body).encode("utf-8")
        handler = object.__new__(worker.Handler)
        handler.path = path
        handler.headers = {"Content-Length": str(len(data))}
        handler.rfile = io.BytesIO(data)
        handler.wfile = io.BytesIO()
        handler.send_response = mock.Mock()
        handler.send_header = mock.Mock()
        handler.end_headers = mock.Mock()
        handler.do_POST()
        headers = {
            call.args[0]: call.args[1]
            for call in handler.send_header.call_args_list
        }
        return (
            handler.send_response.call_args.args[0],
            handler.wfile.getvalue(),
            headers,
        )

    def post(self, body, path="/render"):
        status, raw, _ = self.post_raw(body, path)
        return status, json.loads(raw)

    def test_request_validation(self):
        for invalid in ({}, {"stems": []}, {"stems": [stem() | {"start_time": -1}]},
                        {"stems": [stem() | {"controls": []}]}):
            with self.subTest(invalid=invalid):
                status, body = self.post(invalid)
                self.assertEqual(status, 400)
                self.assertIn("error", body)
        self.assertEqual(self.post({"stems": [stem()]}, "/missing")[0], 404)

    def test_binary_single_stem_endpoint(self):
        payload = {"stems": [stem(7)]}
        with mock.patch.object(
            worker, "_render_stem", return_value=(b"RIFF-WAVE", "fake-binary")
        ) as render:
            status, raw, headers = self.post_raw(payload, "/render-stem")

        self.assertEqual(status, 200)
        self.assertEqual(raw, b"RIFF-WAVE")
        self.assertEqual(headers["Content-Type"], "audio/wav")
        self.assertEqual(headers["X-Voicevox-Stream-Id"], "7")
        self.assertEqual(headers["X-Voicevox-Backend"], "fake-binary")
        self.assertEqual(headers["X-Voicevox-Audio-Bytes"], str(len(b"RIFF-WAVE")))
        self.assertGreaterEqual(int(headers["X-Voicevox-Peak-Rss-Bytes"]), 0)
        self.assertEqual(render.call_count, 1)

        status, body = self.post(
            {"stems": [stem(1), stem(2)]}, "/render-stem")
        self.assertEqual(status, 400)
        self.assertIn("exactly one stem", body["error"])

    def test_success_and_second_stem_failure_never_return_partial_audio(self):
        payload = {"stems": [stem(1), stem(2)]}
        with mock.patch.object(worker, "_render_stem", return_value=(b"RIFF", "fake")) as render:
            status, body = self.post(payload)
        self.assertEqual(status, 200)
        self.assertEqual([item["stream_id"] for item in body["stems"]], [1, 2])
        self.assertEqual(render.call_count, 2)

        with mock.patch.object(worker, "_render_stem",
                               side_effect=[(b"RIFF", "fake"), RuntimeError("engine failed")]):
            status, body = self.post(payload)
        self.assertEqual(status, 400)
        self.assertIn("engine failed", body["error"])
        self.assertNotIn("stems", body)


if __name__ == "__main__":
    unittest.main()
