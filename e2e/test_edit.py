"""Edit-menu shortcuts with a first responder that handles none of them must do nothing.

An explicit target that lacks cut:/copy:/paste:/selectAll:/undo: raises NSInvalidArgumentException,
which Chromium's NSApplicationCrashOnExceptions turns into SIGTRAP.
"""
import os
import tempfile
import unittest

import bs

LOG_DIR = os.environ.get("BS_E2E_LOGDIR") or tempfile.mkdtemp(prefix="bs-e2e-logs-")
EDIT_KEYS = [("x", ["cmd"]), ("c", ["cmd"]), ("v", ["cmd"]), ("a", ["cmd"]), ("z", ["cmd"]),
             ("z", ["cmd", "shift"])]


class EditShortcutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = bs.App(f"/tmp/bs-edit-{os.getpid()}", LOG_DIR, label="EditShortcuts").start()

    @classmethod
    def tearDownClass(cls):
        cls.app.stop()

    def ui(self):
        return self.app.call("test.ui")

    def snapshot(self):
        ui = self.ui()
        with open(os.path.join(self.app.data_dir, "settings.json")) as settings:
            return ([(t["id"], t["url"]) for t in ui["tabs"]], ui["settings"]["selectedEngine"]
                    if ui["settings"]["open"] else None, settings.read())

    def open_settings(self):
        self.app.call("test.key", {"key": ",", "modifiers": ["cmd"]})
        bs.wait_until(lambda: (lambda s: s["open"] and s["key"])(self.ui()["settings"]),
                      what="Settings open and key")

    def close_settings(self):
        closes = self.ui()["settings"]["closes"]
        self.app.call("test.key", {"key": "w", "modifiers": ["cmd"]})
        bs.wait_until(lambda: self.ui()["settings"]["closes"] == closes + 1, what="Settings closed")

    def press_edit_keys(self):
        before = self.snapshot()
        for key, modifiers in EDIT_KEYS:
            self.app.call("test.key", {"key": key, "modifiers": modifiers})
            self.assertIsNone(self.app.proc.poll(), f"the app died on {modifiers} {key}")
        self.ui()
        self.assertEqual(self.snapshot(), before)

    def test_settings_window_with_no_text_responder(self):
        self.open_settings()
        self.press_edit_keys()
        self.close_settings()

    def test_main_window_after_settings_closed(self):
        self.open_settings()
        self.close_settings()
        self.press_edit_keys()

    def test_main_window_after_the_command_button_was_clicked(self):
        self.app.call("test.click", {"target": "commandButton"})
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the launcher")
        self.app.call("test.key", {"key": "Escape"})
        bs.wait_until(lambda: not self.ui()["launcher"]["open"], what="the launcher to close")
        self.press_edit_keys()


if __name__ == "__main__":
    unittest.main()
