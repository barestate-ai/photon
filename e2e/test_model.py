"""ModelProvider and SpendLedger on the real app, through test.model.call.

The capture server answers 503 on purpose: it only records what the Baseten adapter sends (a
server fault a real API cannot produce on demand). It never returns a completion, so no test
here runs against a model stand-in. Live tests need BARESTATE_LIVE_META=1, MODEL_API_KEY in the
environment and BARESTATE_SPEND_LOG pointing at the real ledger; they are skipped otherwise.
"""
import base64
import json
import os
import struct
import tempfile
import threading
import time
import unittest
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import bs

CAPTURE_PORT = 47885
LOG_DIR = os.environ.get("BS_E2E_LOGDIR") or tempfile.mkdtemp(prefix="bs-e2e-logs-")
LEDGER_KEYS = {"ts", "source", "model", "endpoint", "input_tokens", "output_tokens",
               "cached_tokens", "usd", "pricing_basis"}


class Capture(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        self.requests = []
        super().__init__(("127.0.0.1", CAPTURE_PORT), self.handler())

    def handler(outer):
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                outer.requests.append({"path": self.path, "authorization": bool(
                    self.headers.get("Authorization", "").startswith("Bearer ")),
                    "body": json.loads(body)})
                payload = b'{"error":{"message":"capture only"}}'
                self.send_response(503)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass
        return Handler


def png(size=32):
    """A white square, enough for a model to accept as an image."""
    row = b"\x00" + b"\xff\xff\xff" * size

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(row * size)) + chunk(b"IEND", b""))


def text_of(path):
    with open(path) as source:
        return source.read()


def ledger(path):
    return json.loads(text_of(path))


class ModelApp(unittest.TestCase):
    env = {}

    @classmethod
    def setUpClass(cls):
        cls.data_dir = f"/tmp/bs-model-{os.getpid()}-{cls.__name__[:6]}"
        cls.app = bs.App(cls.data_dir, LOG_DIR, label=cls.__name__, env=cls.env).start()

    @classmethod
    def tearDownClass(cls):
        cls.app.stop()

    def call(self, method, params=None):
        return self.app.call(method, params)

    def model(self, **params):
        return self.call("test.model.call", {"prompt": "Reply with exactly: pong", **params})


class FaultTests(ModelApp):
    """VAL-MODEL-004, VAL-MODEL-006, VAL-MODEL-008 against the Baseten adapter."""

    spend = os.path.join(tempfile.mkdtemp(prefix="bs-spend-"), "spend.json")
    env = {"BASETEN_API_KEY": "baseten-dummy", "MODEL_API_KEY": "meta-dummy",
           "BARESTATE_ENV_FILE": "/dev/null", "BARESTATE_SPEND_LOG": spend,
           "BARESTATE_BASETEN_URL": f"http://127.0.0.1:{CAPTURE_PORT}/v1"}

    @classmethod
    def setUpClass(cls):
        cls.capture = Capture()
        threading.Thread(target=cls.capture.serve_forever, daemon=True).start()
        super().setUpClass()

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        cls.capture.shutdown()
        cls.capture.server_close()

    def setUp(self):
        self.capture.requests.clear()
        self.write_ledger(0)

    def write_ledger(self, total):
        with open(self.spend, "w") as out:
            json.dump({"cap_usd": 40, "per_run_cap_usd": 3, "total_usd": total, "entries": []}, out)

    def refused(self, **params):
        with self.assertRaises(bs.RpcError) as caught:
            self.model(**params)
        return caught.exception.message

    def test_baseten_request_shape(self):
        """VAL-MODEL-006"""
        self.assertTrue(self.refused().startswith("server:"))
        (request,) = self.capture.requests
        self.assertEqual(request["path"], "/v1/chat/completions")
        self.assertTrue(request["authorization"])
        self.assertEqual(request["body"]["model"], "meta-models/muse-spark-open")
        self.assertEqual(request["body"]["messages"][0]["role"], "user")
        self.assertNotIn("computer", json.dumps(request["body"]))

    def test_baseten_has_no_computer_tool(self):
        """VAL-MODEL-006: asking for the computer tool is refused locally."""
        self.assertTrue(self.refused(computer=True).startswith("refused:"))
        self.assertEqual(self.capture.requests, [])

    def test_the_cap_refuses_without_a_request_and_below_it_a_request_goes_out(self):
        """VAL-MODEL-004"""
        self.write_ledger(40)
        before = text_of(self.spend)
        self.assertTrue(self.refused().startswith("cap-reached:"))
        self.assertEqual(self.capture.requests, [])
        self.assertEqual(text_of(self.spend), before)
        self.write_ledger(39.99)
        self.assertTrue(self.refused().startswith("server:"))
        self.assertEqual(len(self.capture.requests), 1)

    def test_an_outage_is_a_typed_error_and_the_app_stays_up(self):
        """VAL-MODEL-008"""
        self.write_ledger(1)
        before = text_of(self.spend)
        self.call("test.modelOffline", {"on": True})
        try:
            for _ in range(2):  # the agent loop and the verifier take the same path
                started = time.monotonic()
                self.assertTrue(self.refused().startswith("unreachable:"))
                self.assertLess(time.monotonic() - started, 15)
            self.assertTrue(self.app.status()["ready"])
            self.assertIn("tabs", self.call("tabs"))
        finally:
            self.call("test.modelOffline", {"on": False})
        self.assertEqual(self.capture.requests, [])
        self.assertEqual(text_of(self.spend), before)


@unittest.skipUnless(
    os.environ.get("BARESTATE_LIVE_META") == "1" and os.environ.get("MODEL_API_KEY")
    and os.environ.get("BARESTATE_SPEND_LOG"), "live Meta call: not run (no BARESTATE_LIVE_META/key)")
class LiveTests(ModelApp):
    """VAL-MODEL-003, VAL-MODEL-002, VAL-MODEL-007 against api.meta.ai."""

    env = {"BASETEN_API_KEY": "", "BARESTATE_ENV_FILE": "/dev/null", "BARESTATE_MODEL": ""}

    @classmethod
    def setUpClass(cls):
        cls.spend = os.environ["BARESTATE_SPEND_LOG"]
        assert ledger(cls.spend)["total_usd"] < 40, "spend cap reached"
        super().setUpClass()

    def test_calls_append_exact_spend_and_the_key_stays_out_of_every_file(self):
        before = ledger(self.spend)
        text = self.model(source="e2e:text")
        streamed = self.model(source="e2e:stream", stream=True)
        computer = self.model(source="e2e:computer", computer=True, maxOutputTokens=400,
                              image="data:image/png;base64," + base64.b64encode(png()).decode())
        after = ledger(self.spend)

        self.assertEqual(after["entries"][:len(before["entries"])], before["entries"])
        new = after["entries"][len(before["entries"]):]
        self.assertEqual([entry["source"] for entry in new], ["e2e:text", "e2e:stream", "e2e:computer"])
        for entry in new:
            self.assertEqual(set(entry), LEDGER_KEYS)
            self.assertEqual(entry["model"], "muse-spark-1.3")
            fresh = entry["input_tokens"] - entry["cached_tokens"]
            expected = (fresh * 1.25 + entry["cached_tokens"] * 0.15 + entry["output_tokens"] * 4.25) / 1e6
            self.assertAlmostEqual(entry["usd"], expected, delta=1e-6)
        self.assertAlmostEqual(after["total_usd"] - before["total_usd"],
                               sum(entry["usd"] for entry in new), delta=2e-6)
        self.assertIn("pong", text["text"].lower())
        self.assertEqual(text["endpoint"], "/responses")
        self.assertEqual(streamed["endpoint"], "/responses (stream)")
        self.assertGreater(streamed["deltas"], 0)
        self.assertEqual(computer["model"], "muse-spark-1.3")
        self.assertTrue(text["requestId"])

        self.assertIn("model call provider=meta model=muse-spark-1.3",
                      text_of(os.path.join(self.data_dir, "logs", "photon.log")))
        key = os.environ["MODEL_API_KEY"].encode()
        leaks = []
        for root, dirs, files in os.walk(self.data_dir):
            dirs[:] = [d for d in dirs if d != "profile"]
            for name in files:
                path = os.path.join(root, name)
                if not os.path.isfile(path):
                    continue
                with open(path, "rb") as source:
                    if key in source.read():
                        leaks.append(name)
        with open(self.spend, "rb") as source:
            if key in source.read():
                leaks.append("spend.json")
        self.assertEqual(leaks, [])


@unittest.skipUnless(
    os.environ.get("BARESTATE_LIVE_META") == "1" and os.environ.get("MODEL_API_KEY")
    and os.environ.get("BARESTATE_SPEND_LOG"), "live Meta call: not run (no BARESTATE_LIVE_META/key)")
class LiveWonderOverride(ModelApp):
    """VAL-MODEL-007: BARESTATE_MODEL=muse-wonder-1.0 plus the computer tool goes to Spark."""

    env = {"BASETEN_API_KEY": "", "BARESTATE_ENV_FILE": "/dev/null",
           "BARESTATE_MODEL": "muse-wonder-1.0"}

    def test_the_computer_turn_is_routed_to_spark(self):
        self.assertLess(ledger(os.environ["BARESTATE_SPEND_LOG"])["total_usd"], 40)
        reply = self.model(source="e2e:wonder-computer", computer=True,
                           image="data:image/png;base64," + base64.b64encode(png()).decode())
        self.assertEqual(reply["model"], "muse-spark-1.3")


if __name__ == "__main__":
    unittest.main()
