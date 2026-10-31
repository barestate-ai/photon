"""photon.log / cef.log: lifecycle events, crash capture, and no private data (VAL-STABILITY-003)."""
import os
import re
import shutil
import signal
import sys
import tempfile
import unittest

import bs

LOG_DIR = os.environ.get("BS_E2E_LOGDIR") or tempfile.mkdtemp(prefix="bs-e2e-logs-")
SECRET_QUERY = "secret-query-7731"
TYPED = "zq-typed-text-4420"
# Assembled at runtime so no key-shaped literal sits in the source.
KEY = "fake" + "-model-" + "value-" + os.urandom(6).hex()
CONSOLE_SECRET = "console-secret-5521"
DEAD_PAGE = "http://127.0.0.1:47899/dead-page"


def url(page):
    return f"{bs.FIXTURE_URL}/{page}"


def read(data_dir, name="photon.log"):
    with open(os.path.join(data_dir, "logs", name), errors="replace") as log:
        return log.read()


class LoggingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = bs.Fixtures(LOG_DIR).start()

    def launch(self, name, fresh=True, **kwargs):
        data_dir = f"/tmp/bs-log-{os.getpid()}-{name}"
        app = bs.App(data_dir, LOG_DIR, label=f"log-{name}", **kwargs).start(fresh=fresh)
        self.addCleanup(shutil.rmtree, data_dir, ignore_errors=True)
        return app

    def quit(self, app):
        os.kill(app.proc.pid, signal.SIGTERM)
        self.assertEqual(app.proc.wait(timeout=20), 0)
        app.stop(remove_data=False)

    def test_lifecycle_events_are_logged_without_private_data(self):
        app = self.launch("life", url=url("input.html"), env={"MODEL_API_KEY": KEY})
        data_dir = app.data_dir
        first = bs.wait_until(lambda: next(
            (t for t in app.call("tabs")["tabs"] if "input.html" in t["url"] and not t["loading"]),
            None), what="the fixture to load")
        bs.wait_until(lambda: app.call("test.ui"), what="ui")
        app.call("test.click", {"target": first["id"], "x": 60, "y": 100})
        app.call("test.type", {"text": TYPED})
        # A submit is sensitive (D50); a navigate carries the query without an approval.
        asked = app.call("request_control", {"sessionId": "log-session", "tabId": first["id"]})
        app.call("control.decide", {"requestId": asked["requestId"], "allow": True})
        seen = app.call("observe", {"tabId": first["id"]})
        row = app.call("act", {"sessionId": "log-session", "clientActionId": "log-nav",
                               "observationId": seen["id"], "kind": "navigate",
                               "url": url(f"input.html?q={SECRET_QUERY}")})
        # The fake key leaves the model verifier unavailable; the page itself did change.
        self.assertEqual(row["domVerdict"], "document-changed", row)
        second = app.call("open_tab", {"url": DEAD_PAGE})["id"]
        bs.wait_until(lambda: "load-error" in read(data_dir), what="the load error to be logged")
        app.call("test.closeTab", {"tabId": second})
        app.call("test.modelOffline", {"on": True})
        app.call("run.start", {"origin": "mac", "prompt": f"find {TYPED}"})
        client = app.rpc()
        client.call("app.status")
        client.close()
        bs.wait_until(lambda: "remote disconnect" in read(data_dir), what="the disconnect line")
        self.quit(app)

        log = read(data_dir)
        for event in (r"engine launch version=\S+ pid=\d+", r"tabs create tab=t1", r"tabs activate tab=",
                      r"tabs navigate tab=t1 origin=http://127\.0\.0\.1$", rf"tabs close tab={second}",
                      r"engine load-error tab=\S+ code=-?\d+ text=ERR_\w+ origin=http://127\.0\.0\.1$",
                      r"runs start run=\S+ origin=mac state=pending",
                      r"approvals open id=\S+ kind=control", r"approvals resolve id=\S+ decision=allow",
                      r"runs end run=\S+ state=failed",
                      r"remote connect", r"remote disconnect", r"quit request", r"quit message loop ended",
                      r"quit store closing", r"quit store closed", r"quit exit code=0"):
            self.assertRegex(log, re.compile(event, re.M), f"missing {event}")
        for private in (SECRET_QUERY, "input.html", "form.html", "dead-page", TYPED, KEY, "Bearer", "?q"):
            self.assertNotIn(private, log)
        self.assertNotRegex(log, r" debug ")
        self.assertTrue(os.path.exists(os.path.join(data_dir, "logs", "cef.log")))

    def test_cef_log_level_follows_barestate_log(self):
        default = self.launch("cefw", url=url("input.html"))
        default_dir = default.data_dir
        self.console_noise(default)
        self.quit(default)
        verbose = self.launch("cefv", env={"BARESTATE_LOG": "debug"}, url=url("input.html"))
        verbose_dir = verbose.data_dir
        self.console_noise(verbose)
        self.quit(verbose)
        for data_dir in (default_dir, verbose_dir):
            self.assertNotIn(CONSOLE_SECRET, read(data_dir, "cef.log"))
            self.assertNotIn(CONSOLE_SECRET, read(data_dir))
        self.assertNotRegex(read(default_dir, "cef.log"), r":VERBOSE\d*:")
        self.assertRegex(read(verbose_dir, "cef.log"), r":VERBOSE\d*:")
        self.assertRegex(read(verbose_dir), r" debug ")

    def console_noise(self, app):
        tab = bs.wait_until(lambda: next(
            (t for t in app.call("tabs")["tabs"] if not t["loading"]), None), what="page loaded")
        for level in ("error", "warn"):
            app.call("test.devtools", {"tabId": tab["id"], "method": "Runtime.evaluate", "params": {
                "expression": f"console.{level}('{CONSOLE_SECRET} {url('x/y')}?z=1')"}})

    def crash_with(self, name, kind, exits):
        app = self.launch(name)
        data_dir = app.data_dir
        app.call("test.raise", {"kind": kind})
        app.expect_crash(exits)
        returncode = app.proc.returncode
        app.stop(remove_data=False)
        return read(data_dir), returncode

    # test.raise kind -> the handler that logs it. An exception thrown by an event handler or
    # inside a main-actor Task reaches -[NSApplication run], whose catch calls reportException:
    # (the Task route used to fault in a Swift executor check there, SIGSEGV with no log line);
    # one thrown from a plain main-queue block unwinds to the uncaught-exception handler.
    EXCEPTION_EXITS = (-signal.SIGTRAP, -signal.SIGABRT)
    EXCEPTION_ROUTES = {"action": "reportException", "task": "reportException",
                        "exception": "handler"}

    def test_an_uncaught_exception_is_logged_with_name_reason_and_stack_from_every_route(self):
        for kind, via in self.EXCEPTION_ROUTES.items():
            with self.subTest(route=kind):
                log, returncode = self.crash_with(f"exc-{kind}", kind, self.EXCEPTION_EXITS)
                lines = [l for l in log.splitlines() if "uncaught exception" in l]
                self.assertEqual(len(lines), 1, lines)
                self.assertRegex(
                    lines[0], rf"uncaught exception via={via} name=BarestateTestException "
                    r"reason=test\.raise exception stack=\S.*\|")
                self.assertIn(returncode, self.EXCEPTION_EXITS)

    def test_a_fatal_signal_is_logged_with_its_name(self):
        log, _ = self.crash_with("sig", "signal", (-signal.SIGSEGV,))
        self.assertRegex(log, r"fatal signal SIGSEGV pid=\d+")

    def test_a_corrupt_settings_file_is_logged_without_its_contents(self):
        data_dir = f"/tmp/bs-log-{os.getpid()}-bad"
        os.makedirs(data_dir)
        self.addCleanup(shutil.rmtree, data_dir, ignore_errors=True)
        with open(os.path.join(data_dir, "settings.json"), "w") as settings:
            settings.write("corrupt-settings-9917")
        app = self.launch("bad", fresh=False)
        self.assertRegex(read(data_dir), r"error store settings\.json invalid json")
        self.assertNotIn("corrupt-settings-9917", read(data_dir))
        self.quit(app)

    def test_test_raise_does_not_exist_without_test_hooks(self):
        app = self.launch("nohooks", test_hooks=False)
        with self.assertRaises(bs.RpcError):
            app.call("test.raise", {"kind": "signal"})
        self.assertTrue(app.status()["ready"])
        self.quit(app)


if __name__ == "__main__":
    # make e2e reaps the deliberate-crash reports itself; standalone, do it here.
    result = unittest.main(exit=False).result
    bs.reap_crash_reports(timeout=45)
    for name in bs.faulted_reports:
        print(f"deliberate crash {name} was EXC_BAD_ACCESS")
    sys.exit(0 if result.wasSuccessful() and not bs.faulted_reports else 1)
