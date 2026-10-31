"""Chromium's code-sign clone (a ~335 MB copy of the bundle per launch) is never created, so no way
of leaving the app (quit, SIGTERM, SIGKILL) can leak it."""
import os
import signal
import unittest

import bs
from appcase import LOG_DIR


class NoCodeSignCloneTests(unittest.TestCase):
    def launch(self, name):
        self.before = bs.clone_entries()
        self.app = bs.App(f"/tmp/bs-clone-{os.getpid()}-{name}", LOG_DIR, label=f"clone-{name}").start()
        self.addCleanup(self.app.stop)
        return self.app

    def assert_no_new_clone(self, when):
        self.assertEqual(sorted(bs.clone_entries() - self.before), [], when)

    def test_a_running_app_has_no_clone(self):
        self.launch("run")
        self.assert_no_new_clone("while running")

    def test_cmd_q_leaves_no_clone(self):
        app = self.launch("cmdq")
        try:
            app.call("test.key", {"key": "q", "modifiers": ["cmd"]})
        except (ValueError, OSError):
            pass  # the app quits before it can answer
        self.assertEqual(app.proc.wait(timeout=20), 0)
        self.assert_no_new_clone("after ⌘Q")

    def test_sigterm_leaves_no_clone(self):
        app = self.launch("term")
        os.kill(app.proc.pid, signal.SIGTERM)
        self.assertEqual(app.proc.wait(timeout=20), 0)
        self.assert_no_new_clone("after SIGTERM")

    def test_sigkill_leaves_no_clone(self):
        app = self.launch("kill")
        app.allow_exit(-signal.SIGKILL)
        os.kill(app.proc.pid, signal.SIGKILL)
        app.proc.wait(timeout=20)
        self.assert_no_new_clone("after SIGKILL")


if __name__ == "__main__":
    unittest.main()
