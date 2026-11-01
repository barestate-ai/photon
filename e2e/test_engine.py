"""Engine scaffold: the signed, sandboxed single-tab CEF app and its socket."""
import ctypes
import os
import re
import signal
import subprocess
import tempfile
import unittest

import bs

LOG_DIR = os.environ.get("BS_E2E_LOGDIR") or tempfile.mkdtemp(prefix="bs-e2e-logs-")
INDEX_URL = f"{bs.FIXTURE_URL}/index.html"
LIBC = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
LIBC.sandbox_check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]


def data_dir(label):
    return f"/tmp/bs-e2e-{os.getpid()}-{label}"


def command_of(pid):
    return subprocess.run(["ps", "-o", "command=", "-p", str(pid)],
                          capture_output=True, text=True).stdout.strip()


def process_type(command):
    match = re.search(r"--type=([\w-]+)", command)
    return match.group(1) if match else "browser"


def tab_loaded(app):
    tabs = app.call("test.ui")["tabs"]
    return tabs[0] if tabs and not tabs[0]["loading"] and tabs[0]["url"] == INDEX_URL else None


class RunningApp(unittest.TestCase):
    """One app per class, started with test hooks and the fixture page already loaded."""

    @classmethod
    def setUpClass(cls):
        cls.fixtures = bs.Fixtures(LOG_DIR).start()
        cls.log_start = len(cls.fixtures.log())
        cls.app = bs.App(data_dir(cls.__name__), LOG_DIR, label=cls.__name__, url=INDEX_URL).start()
        bs.wait_until(lambda: tab_loaded(cls.app), what="fixture page loaded")

    @classmethod
    def tearDownClass(cls):
        cls.app.stop()


class AlloyTabTests(RunningApp):
    def test_status_is_ready_with_one_tab(self):
        status = self.app.status()
        self.assertTrue(status["ready"])
        self.assertEqual(status["tabs"], 1)
        self.assertEqual(status["dataDir"], self.app.data_dir)

    def test_g2_tab_loads_the_fixture_and_renders_it(self):
        tab = tab_loaded(self.app)
        self.assertEqual(tab["title"], "Barestate fixture")
        self.assertGreater(tab["frame"]["w"], 0)
        self.assertGreater(tab["frame"]["h"], 0)
        self.assertIn("GET /index.html 200", self.fixtures.log(self.log_start))
        shot = os.path.join(LOG_DIR, "g2-alloy-tab.png")
        self.app.call("test.screenshot", {"path": shot})
        # A blank content area compresses to a few KB; the heading adds visible detail.
        self.assertGreater(os.path.getsize(shot), 30_000)

    def test_only_the_unix_socket_listens(self):
        pids = self.app.tree_pids()
        self.assertGreater(len(pids), 3, "expected the browser plus its helpers")
        pid_list = ",".join(map(str, pids))
        tcp = subprocess.run(["lsof", "-nP", "-p", pid_list, "-a", "-iTCP", "-sTCP:LISTEN"],
                             capture_output=True, text=True).stdout
        self.assertEqual(tcp.strip(), "")
        for pid in pids:
            command = command_of(pid)
            self.assertNotIn("remote-debugging", command)
        sockets = subprocess.run(["lsof", "-nP", "-U", "-a", "-p", str(self.app.proc.pid)],
                                 capture_output=True, text=True).stdout
        self.assertIn(os.path.join(self.app.data_dir, "app.sock"), sockets)

    def test_only_the_browser_process_is_unsandboxed(self):
        seen = {}
        for pid in self.app.tree_pids():
            kind = process_type(command_of(pid))
            seen.setdefault(kind, []).append(LIBC.sandbox_check(pid, None, 0))
        self.assertEqual(seen.pop("browser"), [0])
        self.assertIn("renderer", seen)
        self.assertIn("gpu-process", seen)
        for kind, results in seen.items():
            self.assertEqual(set(results), {1}, f"{kind} process is not sandboxed")


class HooksOffTests(unittest.TestCase):
    def test_test_methods_are_unreachable_without_the_flag(self):
        app = bs.App(data_dir("hooks-off"), LOG_DIR, label="hooks-off", test_hooks=False).start()
        try:
            self.assertTrue(app.status()["ready"])
            for method in ("test.ui", "test.screenshot"):
                with self.assertRaises(bs.RpcError) as caught:
                    app.call(method, {"path": "/tmp/never.png"})
                self.assertEqual(caught.exception.code, -32601)
        finally:
            app.stop()


class QuitTests(unittest.TestCase):
    def test_sigterm_quits_cleanly_and_leaves_only_data(self):
        fixtures = bs.Fixtures(LOG_DIR).start()
        app = bs.App(data_dir("quit"), LOG_DIR, label="quit", url=INDEX_URL).start()
        try:
            bs.wait_until(lambda: tab_loaded(app), what="fixture page loaded")
            pids = app.tree_pids()
            os.kill(app.proc.pid, signal.SIGTERM)
            self.assertEqual(app.proc.wait(timeout=15), 0)
            bs.wait_until(lambda: not any(self.alive(pid) for pid in pids),
                          10, what="all processes gone")
            self.assertEqual(sorted(os.listdir(app.data_dir)),
                             ["barestate.sqlite", "first-run-hint", "logs", "profile", "settings.json",
                              "tmp"])
        finally:
            app.stop()
            self.assertTrue(fixtures.healthy())

    @staticmethod
    def alive(pid):
        return subprocess.run(["ps", "-p", str(pid)], capture_output=True).returncode == 0


class NoStrayWritesTests(unittest.TestCase):
    def test_nothing_named_for_the_app_is_written_outside_the_data_dir(self):
        library = os.path.expanduser("~/Library")
        with tempfile.NamedTemporaryFile() as stamp:
            bs.Fixtures(LOG_DIR).start()
            app = bs.App(data_dir("writes"), LOG_DIR, label="writes", url=INDEX_URL).start()
            bs.wait_until(lambda: tab_loaded(app), what="fixture page loaded")
            app.stop()
            found = subprocess.run(["find", library, "-newer", stamp.name, "-ipath", "*arestate*"],
                                   capture_output=True, text=True).stdout.strip()
        self.assertEqual(found, "")
        defaults = subprocess.run(["defaults", "read", "dev.barestate.browser"],
                                  capture_output=True, text=True)
        self.assertNotEqual(defaults.returncode, 0)


if __name__ == "__main__":
    unittest.main()
