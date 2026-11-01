"""Settings "Use Barestate Muse" and the proxy route (D74, VAL-API-007), against a stub that
stands where the Barestate API would be: it records requests, registers a device for the one
good code, and answers /v1/muse/responses with the proxy's 402 limit message. It never answers
with model-shaped output. The real proxy run (invite code, live spend, revoke) is the feature
verification, not this file.

The app runs hermetically: no MODEL_API_KEY, an empty BARESTATE_ENV_FILE, the Keychain
suppressed by --test-hooks, and BARESTATE_API_URL pointing at the stub, so the device-token
route is the only one possible.
"""
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import bs
from appcase import LOG_DIR
from test_settings import SettingsCase

GOOD_CODE = "e2e-good-code"
DEVICE_TOKEN = "e2e-device-token-0123456789abcdef"
LIMIT_MESSAGE = ("Barestate Muse daily limit reached for this device. Try again tomorrow, "
                 "or use your own model key in Settings.")
RECOVERY = "Muse is unavailable. Web search still works."


class StubAPI(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port):
        self.requests = []
        self.overload = False  # /v1/muse/responses answers 503, standing for an outage
        super().__init__(("127.0.0.1", port), self.handler())

    def handler(outer):
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                outer.requests.append({
                    "path": self.path,
                    "authorization": self.headers.get("Authorization", ""),
                    "body": json.loads(body) if body else None})
                if self.path == "/v1/devices":
                    if json.loads(body).get("invite_code") == GOOD_CODE:
                        status, payload = 201, {"device_token": DEVICE_TOKEN}
                    else:
                        status, payload = 403, {"error": {"message": "Unknown invite code."}}
                else:
                    if outer.overload:
                        status, payload = 503, {"error": {"message": "upstream overloaded"}}
                    else:
                        status, payload = 402, {"error": {"message": LIMIT_MESSAGE}}
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass
        return Handler

    def calls(self, path):
        return [request for request in self.requests if request["path"].startswith(path)]


class BarestateMuseTests(SettingsCase):
    @classmethod
    def setUpClass(cls):
        cls.api = StubAPI(bs.provider_port())
        threading.Thread(target=cls.api.serve_forever, daemon=True).start()
        cls.data_dir = f"/tmp/bs-muse-{os.getpid()}"
        cls.app = bs.App(cls.data_dir, LOG_DIR, label=cls.__name__, env={
            **bs.HERMETIC_ENV, "MODEL_API_KEY": "",
            "BARESTATE_API_URL": f"http://127.0.0.1:{cls.api.server_address[1]}/v1/muse",
        }).start()

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        cls.api.shutdown()
        cls.api.server_close()

    def muse(self):
        return self.settings()["muse"]

    def connect_with(self, code):
        """Types the code and clicks Connect; returns the settled Muse section."""
        self.open_settings()
        self.call("test.click", {"target": "settings.muse.invite"})
        # A failed attempt keeps the field's text; select it before typing over it.
        self.call("test.key", {"key": "a", "modifiers": ["cmd"], "window": "settings"})
        self.call("test.type", {"text": code, "window": "settings"})
        connects = self.muse()["connects"]
        self.call("test.click", {"target": "settings.muse.connect"})
        return bs.wait_until(
            lambda: (lambda m: m if m["connects"] == connects + 1 and not m["connecting"]
                     else None)(self.muse()),
            what="the connect attempt to settle")

    def shot(self, name):
        self.call("test.motion", {"settle": True})
        self.call("test.screenshot",
                  {"path": os.path.join(LOG_DIR, name), "window": "settings"})

    def test_1_without_a_key_or_token_muse_offers_the_invite_code(self):
        settings = self.open_settings()
        muse = settings["muse"]
        self.assertEqual(settings["model"], "Unavailable")
        self.assertEqual((muse["offered"], muse["connected"], muse["connecting"],
                          muse["error"]), (True, False, False, ""))
        labels = self.labels()
        for expected in ("Use Barestate Muse", "Invite code", "Connect"):
            self.assertIn(expected, labels)
        loop = settings["keyLoop"]
        at = loop.index("Bing")
        self.assertEqual(loop[at + 1:at + 3], ["Invite code", "Connect"])
        self.assertFalse(os.path.exists(os.path.join(self.data_dir, "device-token")))
        self.shot("muse-not-connected.png")
        self.close_settings()

    def test_2_a_bad_code_shows_one_clear_line(self):
        muse = self.connect_with("e2e-wrong-code")
        self.assertEqual(muse["error"], "Unknown invite code.")
        self.assertFalse(muse["connected"])
        registrations = self.api.calls("/v1/devices")
        self.assertEqual(len(registrations), 1)
        self.assertEqual(registrations[0]["body"]["invite_code"], "e2e-wrong-code")
        self.assertTrue(registrations[0]["body"]["device_name"])
        self.assertEqual(registrations[0]["authorization"], "")
        self.shot("muse-bad-code.png")

    def test_3_connecting_stores_the_token_and_muse_turns_available(self):
        muse = self.connect_with(GOOD_CODE)
        self.assertEqual((muse["connected"], muse["error"]), (True, ""))
        self.assertEqual(self.settings()["model"], "Available")
        self.assertIn("Disconnect", self.labels())
        token_path = os.path.join(self.data_dir, "device-token")
        with open(token_path) as source:
            self.assertEqual(source.read(), DEVICE_TOKEN)
        self.assertEqual(oct(os.stat(token_path).st_mode & 0o777), "0o600")
        motion = self.call("test.motion")
        fades = [m for m in motion["recent"] + motion["inFlight"] if m["kind"] == "museState"]
        self.assertTrue(fades, motion)
        self.assertEqual(fades[-1]["purpose"], "status-fade")
        self.shot("muse-connected.png")

    def test_4_a_call_reaches_the_proxy_with_the_token_and_a_402_surfaces_its_message(self):
        before = len(self.api.calls("/v1/muse"))
        with self.assertRaises(bs.RpcError) as caught:
            self.call("test.model.call",
                      {"prompt": "Reply with exactly: pong", "source": "e2e:muse"})
        message = caught.exception.message
        self.assertTrue(message.startswith("rejected:"), message)
        self.assertIn("daily limit reached", message)
        calls = self.api.calls("/v1/muse")
        self.assertEqual(len(calls), before + 1, "one request, no retry")
        self.assertEqual(calls[-1]["path"], "/v1/muse/responses")
        self.assertEqual(calls[-1]["authorization"], f"Bearer {DEVICE_TOKEN}")
        self.assertEqual(calls[-1]["body"]["model"], "muse-spark-1.3")
        self.assertFalse(os.path.exists(os.path.join(self.data_dir, "spend.json")),
                         "a rejected call bills nothing")

    def test_5_disconnect_returns_to_the_recovery_state(self):
        self.open_settings()
        self.call("test.click", {"target": "settings.muse.connect"})  # now reads Disconnect
        muse = bs.wait_until(lambda: (lambda m: m if not m["connected"] else None)(self.muse()),
                             what="Muse disconnected")
        self.assertTrue(muse["offered"])
        self.assertFalse(os.path.exists(os.path.join(self.data_dir, "device-token")))
        self.assertEqual(self.settings()["model"], "Unavailable")
        self.close_settings()
        self.key("t", "cmd")
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the launcher")
        self.call("test.type", {"text": "click Save on the page"})
        state = bs.wait_until(
            lambda: (lambda l: l if any(r["kind"] == "startTask" for r in l["rows"]) else None)(
                self.ui()["launcher"]),
            what="the Start task row")
        task = next(r for r in state["rows"] if r["kind"] == "startTask")
        # Committing it meets the outage and lands in the usual recovery state (VAL-TASK-007).
        self.call("test.click", {"target": f"launcherRow:{task['id']}"})
        state = bs.wait_until(
            lambda: (lambda l: l if any(r["kind"] == "retry" for r in l["rows"]) else None)(
                self.ui()["launcher"]),
            what="the recovery state")
        task = next(r for r in state["rows"] if r["kind"] == "startTask")
        self.assertEqual((task["enabled"], task["subtitle"]), (False, RECOVERY))
        self.assertEqual(self.call("run.list")["runs"], [])
        self.key("Escape")
        self.wait_launcher(False)

    def test_6_reconnecting_after_an_outage_clears_muse(self):
        """A connect while the outage latch is set clears it through the same probe Retry uses."""
        muse = self.connect_with(GOOD_CODE)
        self.assertTrue(muse["connected"])
        self.assertEqual(self.settings()["model"], "Available")
        self.close_settings()
        self.api.overload = True
        try:
            self.key("t", "cmd")
            bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the launcher")
            self.call("test.type", {"text": "click Save on the page"})
            state = bs.wait_until(
                lambda: (lambda l: l if any(r["kind"] == "startTask" for r in l["rows"])
                         else None)(self.ui()["launcher"]),
                what="the Start task row")
            task = next(r for r in state["rows"] if r["kind"] == "startTask")
            self.call("test.click", {"target": f"launcherRow:{task['id']}"})
            # The run's call meets 503 (and its one retry), latching Muse unavailable.
            bs.wait_until(lambda: self.settings()["model"] == "Unavailable" or None,
                          what="the outage latch")
        finally:
            self.api.overload = False
        self.wait_launcher(False)  # committing the task closed it
        # Disconnect and connect again: no Retry click, yet the latch is gone.
        self.open_settings()
        self.call("test.click", {"target": "settings.muse.connect"})  # reads Disconnect
        bs.wait_until(lambda: not self.muse()["connected"], what="Muse disconnected")
        fades_before = self.muse_fades()
        muse = self.connect_with(GOOD_CODE)
        self.assertTrue(muse["connected"])
        self.assertEqual(self.settings()["model"], "Available")
        self.assertGreater(self.muse_fades(), fades_before,
                           "the reconnect fades even though the latch-clearing probe repainted")
        self.close_settings()

    def muse_fades(self):
        motion = self.call("test.motion")
        return len([m for m in motion["recent"] + motion["inFlight"]
                    if m["kind"] == "museState"])

    def test_7_codes_and_the_token_stay_out_of_logs_and_files(self):
        leaks = []
        for root, dirs, files in os.walk(self.data_dir):
            dirs[:] = [d for d in dirs if d != "profile"]
            for name in files:
                path = os.path.join(root, name)
                if path == os.path.join(self.data_dir, "device-token"):
                    continue  # the token's own 0600 store, present while connected
                if not os.path.isfile(path):
                    continue
                with open(path, "rb") as source:
                    content = source.read()
                for secret in (GOOD_CODE.encode(), b"e2e-wrong-code", DEVICE_TOKEN.encode()):
                    if secret in content:
                        leaks.append((path, secret.decode()))
        self.assertEqual(leaks, [])


if __name__ == "__main__":
    unittest.main()
