"""The Settings window: sections, the search engine, the model status, Remote pairing and the Reduce Motion note."""
import hashlib
import http.client
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest

import bs
from appcase import LOG_DIR, AppCase, save, url


def flatten(nodes):
    for node in nodes:
        yield node
        yield from flatten(node.get("children", []))


class SettingsCase(AppCase):
    def settings(self):
        return self.ui()["settings"]

    def labels(self):
        return {node.get("label") for node in flatten(self.call("test.ax", {"window": "settings"}))}

    def open_settings(self):
        self.key(",", "cmd")
        return bs.wait_until(lambda: self.settings()["open"] and self.settings()["key"]
                             and self.settings(), what="Settings open and key")

    def close_settings(self):
        """⌘W closes the Settings window when it is the key window; waits for the close itself."""
        closes = self.settings()["closes"]
        self.key("w", "cmd")
        bs.wait_until(lambda: self.settings()["closes"] == closes + 1
                      and not self.settings()["open"], what="Settings closed")

    def saved(self):
        with open(os.path.join(self.data_dir, "settings.json")) as source:
            return json.load(source)


class SettingsTests(SettingsCase):
    def test_comma_opens_one_window_with_every_section(self):
        """VAL-TABS-001"""
        self.open_settings()
        self.key(",", "cmd")
        settings = self.settings()
        self.assertEqual(settings["windows"], 1)
        self.assertEqual(settings["sections"], ["Search engine", "Model", "Remote", "Motion"])
        self.assertEqual(settings["selectedEngine"], "DuckDuckGo")
        self.assertNotIn("selectedLayout", settings)
        self.assertNotIn("layout", settings)
        labels = self.labels()
        for expected in ("DuckDuckGo", "Google", "Bing", "Model status",
                         "Enable Remote", "Pair a phone", "Paired devices"):
            self.assertIn(expected, labels)
        for removed in ("Horizontal tabs", "Vertical tabs", "Tab layout", "Sidebar"):
            self.assertNotIn(removed, labels)
        self.assertTrue(any("Reduce Motion" in (label or "") for label in labels))
        self.assertTrue(any("Keychain item meta-model-api" in (label or "") for label in labels))
        self.assertFalse(any("Barestate" in (label or "") or "sidebar" in (label or "")
                             for label in labels))
        self.call("test.screenshot", {"path": os.path.join(LOG_DIR, "settings.png"), "window": "settings"})
        self.close_settings()

    def test_open_and_close_are_stable(self):
        """Closing waits on the window-closed count, never on a delay."""
        for _ in range(5):
            self.open_settings()
            self.close_settings()
        self.assertEqual(self.settings()["windows"], 0)

    def close_with_the_browser_holding_key(self):
        """Key status leaves Settings (the browser window takes it, or nobody does in a locked
        session) while Settings stays on top; ⌘W must still close Settings and never the page."""
        self.open_settings()
        tabs = self.tab_ids()
        self.call("test.keyMainWindow")
        self.close_settings()
        self.assertEqual(self.tab_ids(), tabs)
        with open(os.path.join(self.data_dir, "logs", "photon.log")) as log:
            routed = [line for line in log if " info window close shortcut " in line]
        self.assertRegex(routed[-1], r"key=(browser|none) front=settings target=settings")

    def test_cmd_w_closes_the_settings_on_top_when_it_is_not_the_key_window(self):
        self.close_with_the_browser_holding_key()

    def test_cmd_w_reaches_the_settings_on_top_of_an_open_launcher(self):
        """The launcher swallows shortcuts except the ones for the window on top."""
        self.key("t", "cmd")
        self.wait_launcher(True)
        self.close_with_the_browser_holding_key()
        self.key("Escape")
        self.wait_launcher(False)

    def test_the_engine_choice_is_saved_and_used_by_the_next_search(self):
        """VAL-TABS-001"""
        self.open_settings()
        self.call("test.click", {"target": "settings.engine.google"})
        self.assertEqual(self.settings()["selectedEngine"], "Google")
        self.assertEqual(self.saved()["searchEngine"], "https://www.google.com/search?q=%s")
        self.close_settings()
        before = set(self.tab_ids())
        self.key("t", "cmd")
        self.wait_launcher(True)
        self.call("test.type", {"text": "kyoto weather"})
        row = bs.wait_until(lambda: next((r for r in self.ui()["launcher"]["rows"]
                                          if r["kind"] == "search" and r["visible"]), None),
                            what="a Search the web row")
        self.call("test.click", {"target": f"launcherRow:{row['id']}"})
        opened = bs.wait_until(lambda: next((t for t in self.tabs() if t["id"] not in before), None),
                               what="the search tab")
        self.assertTrue(opened["url"].startswith("https://www.google.com/search?q=kyoto"), opened)
        self.open_settings()
        self.call("test.click", {"target": "settings.engine.duckduckgo"})
        self.assertEqual(self.saved()["searchEngine"], "https://duckduckgo.com/?q=%s")
        self.close_settings()
        self.call("test.closeTab", {"tabId": opened["id"]})


GATEWAY_PORT = 47820
PING = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}).encode()


def tailnet_host():
    """This Mac's Funnel host, read the way the app reads it; None without Tailscale."""
    for binary in ("/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"):
        if os.path.exists(binary):
            out = subprocess.run([binary, "status", "--json"], capture_output=True, text=True)
            try:
                return json.loads(out.stdout)["Self"]["DNSName"].rstrip(".") or None
            except (ValueError, KeyError):
                return None
    return None


def gateway(method, path, token=None, body=None, stream=False):
    conn = http.client.HTTPConnection("127.0.0.1", GATEWAY_PORT, timeout=10)
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    conn.request(method, path, body=body, headers=headers)
    response = conn.getresponse()
    if stream:
        return conn, response
    response.read()
    conn.close()
    return response.status


def gateway_listening():
    try:
        socket.create_connection(("127.0.0.1", GATEWAY_PORT), timeout=1).close()
        return True
    except OSError:
        return False


class RemoteSettingsTests(SettingsCase):
    """Pairing in Settings (architecture §8). The Funnel mount is a later feature: the gateway is
    reached on loopback and the QR code only has to name the public host."""

    @classmethod
    def setUpClass(cls):
        cls.host = tailnet_host()
        super().setUpClass()

    def setUp(self):
        if not self.host:
            self.skipTest("not run: Tailscale gives no Funnel host on this Mac")
        self.open_settings()
        self.addCleanup(self.remote_off)

    def remote(self):
        return self.settings()["remote"]

    def remote_off(self):
        if self.remote()["on"] or self.settings()["remote"]["status"].startswith("Starting"):
            self.call("test.click", {"target": "settings.remote.enable"})
        bs.wait_until(lambda: not self.remote()["on"] and not gateway_listening(),
                      what="Remote off and the gateway gone")
        if self.settings()["open"]:
            self.close_settings()

    def remote_on(self):
        self.call("test.click", {"target": "settings.remote.enable"})
        bs.wait_until(lambda: self.remote()["on"], what="Remote on")
        bs.wait_until(lambda: gateway_listening() and gateway("GET", "/__health") == 200,
                      what="the gateway to answer")

    def shot(self, name):
        path = os.path.join(LOG_DIR, name)
        self.call("test.motion", {"settle": True})
        time.sleep(0.5)  # the window resizes for the section, and a capture in between is blank
        self.call("test.screenshot", {"path": path, "window": "settings"})
        return path

    def test_remote_is_off_until_enabled_and_off_again_when_disabled(self):
        self.assertFalse(self.remote()["on"])
        self.assertFalse(gateway_listening())
        self.assertTrue(self.remote()["status"].startswith("Off"))
        self.shot("remote-off.png")
        self.remote_on()
        self.assertTrue(self.remote()["status"].startswith("On"))
        self.call("test.click", {"target": "settings.remote.enable"})
        bs.wait_until(lambda: not gateway_listening(), what="the gateway to stop")
        self.assertFalse(self.remote()["on"])

    def test_pair_a_phone_shows_a_qr_whose_token_works_and_is_stored_only_as_a_hash(self):
        """VAL-REMOTE-004"""
        self.remote_on()
        self.call("test.click", {"target": "settings.remote.pair"})
        bs.wait_until(lambda: self.remote()["qrShown"], what="the QR code")
        png = self.shot("remote-qr.png")
        decoded = self.call("test.qrDecode", {"path": png})["messages"]
        self.assertEqual(len(decoded), 1, "one QR code in the window")
        match = re.fullmatch(rf"https://{re.escape(self.host)}:10000/barestate/#t=([0-9a-f]{{64}})",
                             decoded[0])
        self.assertIsNotNone(match, re.sub(r"[0-9a-f]{64}", "<token>", decoded[0]))
        token = match.group(1)
        self.assertNotEqual(gateway("POST", "/mcp", token, PING), 401)
        self.assertEqual(gateway("POST", "/mcp", "0" * 64, PING), 401)

        with open(os.path.join(self.data_dir, "pairing.json")) as source:
            stored = json.load(source)["pairings"]
        digest = hashlib.sha256(token.encode()).hexdigest()
        self.assertIn(digest, [p["hash"] for p in stored])
        for pairing in stored:
            self.assertEqual(sorted(pairing), ["created", "hash", "label"])
            self.assertRegex(pairing["hash"], r"^[0-9a-f]{64}$")
        for root in (self.data_dir, LOG_DIR):
            found = subprocess.run(["grep", "-rIls", token, root], capture_output=True, text=True)
            self.assertEqual(found.stdout, "", "the token is on disk")
        shown = self.remote()["devices"]
        self.assertEqual(shown[-1]["hash"], digest)
        self.assertEqual(shown[-1]["label"], f"Phone {len(shown)}")
        save("settings-remote-qr.json", {"decoded": re.sub(r"[0-9a-f]{64}", "<token>", decoded[0]),
                                         "hash8": digest[:8]})

    def test_the_qr_code_goes_away_with_the_window_and_with_remote(self):
        self.remote_on()
        self.call("test.click", {"target": "settings.remote.pair"})
        bs.wait_until(lambda: self.remote()["qrShown"], what="the QR code")
        self.close_settings()
        self.open_settings()
        self.assertFalse(self.remote()["qrShown"])
        self.call("test.click", {"target": "settings.remote.pair"})
        bs.wait_until(lambda: self.remote()["qrShown"], what="the QR code")
        self.call("test.click", {"target": "settings.remote.enable"})
        bs.wait_until(lambda: not self.remote()["on"], what="Remote off")
        self.assertFalse(self.remote()["qrShown"])

    def test_the_qr_fades_in_and_follows_reduce_motion(self):
        self.remote_on()
        for reduced in (False, True):
            self.call("test.reduceMotion", {"on": reduced})
            self.addCleanup(self.call, "test.reduceMotion", {"on": False})
            self.call("test.click", {"target": "settings.remote.pair"})
            bs.wait_until(lambda: self.remote()["qrShown"], what="the QR code")
            state = self.call("test.motion")
            reveals = [m for m in state["inFlight"] + state["recent"] if m["kind"] == "qrReveal"]
            self.assertTrue(reveals, state)
            reveal = max(reveals, key=lambda m: m["id"])
            self.assertEqual(reveal["keyPaths"], ["opacity"])
            self.assertEqual(reveal["curve"], "easeOut")
            self.assertFalse(reveal["transformChanged"])
            self.assertLessEqual(reveal["durationMs"], 140 if not reduced else 120)
            self.assertEqual(reveal["reduced"], reduced)

    def test_paired_devices_are_listed_and_revoke_ends_a_token_and_its_open_stream(self):
        self.remote_on()
        first = self.call("test.pairToken", {"label": "Kitchen iPad"})
        second = self.call("test.pairToken", {"label": "Office phone"})
        listed = {d["hash"]: d for d in self.remote()["devices"]}
        for paired, label in ((first, "Kitchen iPad"), (second, "Office phone")):
            self.assertEqual(listed[paired["hash"]]["label"], label)
            self.assertRegex(listed[paired["hash"]]["created"], r"^\d{4}-\d\d-\d\dT")
            self.assertIsNone(listed[paired["hash"]]["lastSeen"])
        self.assertEqual(gateway("POST", "/mcp", first["token"], PING), 200)
        self.open_settings()
        seen = bs.wait_until(lambda: {d["hash"]: d for d in self.remote()["devices"]}[
            first["hash"]]["lastSeen"], what="Kitchen iPad to show a last-seen time")
        self.assertRegex(seen, r"^\d{4}-\d\d-\d\dT")
        self.assertIsNone({d["hash"]: d for d in self.remote()["devices"]}[second["hash"]]["lastSeen"])
        conn, response = gateway("GET", "/api/events", first["token"], stream=True)
        self.addCleanup(conn.close)
        self.assertEqual(response.status, 200)
        self.shot("remote-devices.png")

        self.call("test.click", {"target": f"settings.remote.revoke.{first['hash'][:8]}"})
        hashes = [d["hash"] for d in self.remote()["devices"]]
        self.assertNotIn(first["hash"], hashes)
        self.assertIn(second["hash"], hashes)
        self.assertEqual(gateway("POST", "/mcp", first["token"], PING), 401)
        self.assertEqual(gateway("POST", "/mcp", second["token"], PING), 200)
        response.fp.raw._sock.settimeout(20)
        response.read()  # the stream ends within a keepalive tick or two
        with open(os.path.join(self.data_dir, "pairing.json")) as source:
            self.assertNotIn(first["hash"], source.read())
        with open(os.path.join(self.data_dir, "logs", "photon.log")) as log:
            text = log.read()
        self.assertIn(f"remote revoke hash={first['hash'][:8]}", text)
        self.assertNotIn(first["token"], text)

    def test_a_decoder_finds_nothing_in_a_window_without_a_code(self):
        png = self.shot("remote-no-qr.png")
        self.assertEqual(self.call("test.qrDecode", {"path": png})["messages"], [])


class RemoteLifetimeTests(unittest.TestCase):
    def test_the_gateway_exits_when_the_app_is_killed(self):
        if not tailnet_host():
            self.skipTest("not run: Tailscale gives no Funnel host on this Mac")
        data_dir = f"/tmp/bs-life-{os.getpid()}"
        app = bs.App(data_dir, LOG_DIR, label="remote-life").start()
        try:
            app.call("test.key", {"key": ",", "modifiers": ["cmd"]})
            bs.wait_until(lambda: app.call("test.ui")["settings"]["open"], what="Settings")
            app.call("test.click", {"target": "settings.remote.enable"})
            bs.wait_until(lambda: gateway_listening(), what="the gateway")
            app.allow_exit(-signal.SIGKILL)
            os.kill(app.proc.pid, signal.SIGKILL)
            bs.wait_until(lambda: not gateway_listening(), what="the gateway to follow the app")
        finally:
            app.expect_crash((-signal.SIGKILL,))
            app.stop()


class SettingsKeyboardTests(SettingsCase):
    ACTIONABLE = ["DuckDuckGo", "Google", "Bing", "Enable Remote"]

    def press(self, key, *modifiers):
        self.call("test.key", {"key": key, "modifiers": list(modifiers), "window": "settings"})

    def focused(self):
        return self.settings()["focused"]

    def walk_from(self, start, step):
        """The loop the hook reports, walked from `start` in one direction."""
        loop = self.settings()["keyLoop"]
        at = loop.index(start)
        return [loop[(at + step * (i + 1)) % len(loop)] for i in range(len(loop))]

    def test_every_control_has_a_real_role_and_the_enabled_ones_press(self):
        """VAL-CROSS-007: no AXUnknown, and a press action wherever there is something to press."""
        self.open_settings()
        nodes = list(flatten(self.call("test.ax", {"window": "settings"})))
        self.assertEqual([n["label"] for n in nodes if n.get("role") == "AXUnknown"], [])
        by_label = {n["label"]: n for n in nodes if "label" in n}
        for label in self.ACTIONABLE:
            role = "AXCheckBox" if label == "Enable Remote" else "AXRadioButton"
            self.assertEqual(by_label[label]["role"], role, label)
            self.assertIn("AXPress", by_label[label]["actions"], label)
        self.assertEqual(by_label["Pair a phone"]["role"], "AXButton")
        self.close_settings()

    def test_tab_and_shift_tab_reach_every_actionable_control_in_a_stable_order(self):
        """VAL-CROSS-007: at 720x600 and text scale 1.0, 1.5 and 2.0."""
        self.call("test.windowSize", {"w": 720, "h": 600})
        self.addCleanup(self.call, "test.textScale", {"scale": 1})
        self.open_settings()
        orders = {}
        for scale in (1.0, 1.5, 2.0):
            self.call("test.textScale", {"scale": scale})
            self.assertEqual(self.settings()["keyLoop"], self.ACTIONABLE, scale)
            forward = []
            for _ in self.ACTIONABLE:
                self.press("Tab")
                forward.append(self.focused())
            start = forward[-1]
            self.assertEqual(forward, self.walk_from(start, 1), scale)
            backward = []
            for _ in self.ACTIONABLE:
                self.press("Tab", "shift")
                backward.append(self.focused())
            self.assertEqual(backward, self.walk_from(start, -1), scale)
            orders[scale] = forward
        save("settings-tab-order.json", orders)
        self.close_settings()

    def test_space_on_a_focused_engine_changes_it_once_like_a_click(self):
        """VAL-CROSS-007"""
        self.open_settings()
        before = self.settings()["engineChanges"]
        for _ in self.ACTIONABLE:
            if self.focused() == "Google":
                break
            self.press("Tab")
        self.press("Space")
        settings = self.settings()
        self.assertEqual(settings["selectedEngine"], "Google")
        self.assertEqual(settings["engineChanges"], before + 1)
        self.assertEqual(self.saved()["searchEngine"], "https://www.google.com/search?q=%s")
        self.close_settings()


class SettingsPersistenceTests(unittest.TestCase):
    def test_a_keyboard_choice_survives_a_relaunch(self):
        """VAL-CROSS-007"""
        data_dir = f"/tmp/bs-kbd-{os.getpid()}"
        app = bs.App(data_dir, LOG_DIR, label="keyboard-settings").start()
        try:
            app.call("test.key", {"key": ",", "modifiers": ["cmd"]})
            bs.wait_until(lambda: app.call("test.ui")["settings"]["key"], what="Settings key")
            for _ in range(3):
                if app.call("test.ui")["settings"]["focused"] == "Bing":
                    break
                app.call("test.key", {"key": "Tab", "window": "settings"})
            app.call("test.key", {"key": "Space", "window": "settings"})
            self.assertEqual(app.call("test.ui")["settings"]["selectedEngine"], "Bing")
        finally:
            app.stop(remove_data=False)
        app = bs.App(data_dir, LOG_DIR, label="keyboard-settings-again").start(fresh=False)
        try:
            self.assertEqual(app.call("test.ui")["settings"]["searchEngine"],
                             "https://www.bing.com/search?q=%s")
        finally:
            app.stop()

    def test_the_engine_survives_a_relaunch_and_old_layout_keys_are_ignored(self):
        """VAL-TABS-001 / VAL-SHELL-002"""
        data_dir = f"/tmp/bs-set-{os.getpid()}"
        shutil.rmtree(data_dir, ignore_errors=True)
        os.makedirs(data_dir)
        with open(os.path.join(data_dir, "settings.json"), "w") as out:
            json.dump({"searchEngine": "https://www.bing.com/search?q=%s", "tabLayout": "vertical",
                       "sidebarPinned": True, "sidebarMode": "hidden"}, out)
        app = bs.App(data_dir, LOG_DIR, label="legacy-settings").start(fresh=False)
        try:
            ui = app.call("test.ui")
            self.assertEqual(ui["settings"]["searchEngine"], "https://www.bing.com/search?q=%s")
            self.assertNotIn("sidebar", ui)
            self.assertEqual(ui["window"]["title"], "Photon")
        finally:
            app.stop(remove_data=False)
        shutil.rmtree(data_dir, ignore_errors=True)


class ModelStatusTests(unittest.TestCase):
    def status(self, env_text):
        data_dir = f"/tmp/bs-model-{os.getpid()}"
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as handle:
            handle.write(env_text)
        app = bs.App(data_dir, LOG_DIR, label="model", env={"BARESTATE_ENV_FILE": handle.name, "MODEL_API_KEY": ""})
        try:
            app.start()
            app.call("test.key", {"key": ",", "modifiers": ["cmd"]})
            bs.wait_until(lambda: app.call("test.ui")["settings"]["open"], what="Settings")
            settings = app.call("test.ui")["settings"]
            tree = json.dumps(app.call("test.ax", {"window": "settings"}))
            return settings["model"], tree
        finally:
            app.stop()
            os.unlink(handle.name)

    def test_status_follows_the_key_and_never_shows_it(self):
        """VAL-TABS-001"""
        status, _ = self.status("OTHER=1\n")
        self.assertEqual(status, "Unavailable")
        status, tree = self.status("MODEL_API_KEY=sk-test-not-a-real-key\n")
        self.assertEqual(status, "Available")
        self.assertNotIn("sk-test-not-a-real-key", tree)


if __name__ == "__main__":
    unittest.main()
