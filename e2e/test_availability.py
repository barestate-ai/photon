"""Muse availability from real causes, with `test.modelOffline` off throughout (VAL-TASK-011,
VAL-CROSS-006 with no key): no key anywhere, a provider nobody answers for, and a lost network
path. Nothing here reaches the real provider: the key is absent or a placeholder, and the Muse
provider is a local server that records what reaches it (`bs.DeadHost`)."""
import os
import unittest

import bs
from test_launcher import KYOTO, LauncherCase
from test_run import ENDED

ANNOUNCEMENT = "Unable to connect to Muse"
MESSAGE = "Muse is unavailable. Web search still works."


class AvailabilityCase(LauncherCase):
    def spend(self):
        path = os.path.join(self.data_dir, "spend.json")
        return open(path).read() if os.path.exists(path) else None

    def log_text(self):
        with open(os.path.join(self.data_dir, "logs", "photon.log")) as log:
            return log.read()

    def announcements(self):
        return self.call("test.announcements")["announcements"].count(ANNOUNCEMENT)

    def settings_model(self):
        self.close_launcher()
        self.key(",", "cmd")
        shown = bs.wait_until(lambda: (lambda s: s if s["open"] and s["key"] else None)(
            self.ui()["settings"]), what="Settings open")
        self.key("w", "cmd")
        bs.wait_until(lambda: not self.ui()["settings"]["open"], what="Settings closed")
        return shown["model"]

    def start_with_text(self):
        """Types the request and activates Start task, the row that is active first."""
        self.open_launcher()
        state = self.type_text(KYOTO)
        task = next(r for r in state["rows"] if r["kind"] == "startTask")
        self.assertEqual((task["enabled"], state["active"]), (True, task["id"]))
        self.key("Return")

    def assert_recovery(self, runs):
        """The recovery state of VAL-TASK-008 over the request the person typed."""
        state = bs.wait_until(lambda: (lambda s: s if s["error"] else None)(self.launcher()),
                              what="the recovery state")
        task = next(r for r in state["rows"] if r["kind"] == "startTask")
        search = next(r for r in state["rows"] if r["kind"] == "search")
        self.assertTrue(state["open"])
        self.assertEqual((state["fieldText"], state["query"]), (KYOTO, KYOTO))
        self.assertEqual((task["enabled"], task["subtitle"]), (False, MESSAGE))
        self.assertEqual((state["active"], search["hint"]), (search["id"], True))
        self.assertTrue(any(r["kind"] == "retry" for r in state["rows"]))
        self.assertEqual(self.runs(), runs)

    def retry(self, cause):
        """Activates Retry and waits for the app to report what it found."""
        seen = self.log_text().count(f"muse retry cause={cause}")
        row = next(r for r in self.launcher()["rows"] if r["kind"] == "retry")
        self.call("test.click", {"target": f"launcherRow:{row['id']}"})
        bs.wait_until(lambda: self.log_text().count(f"muse retry cause={cause}") == seen + 1,
                      what=f"Retry to find cause={cause}")

    def assert_cleared(self):
        state = bs.wait_until(lambda: (lambda s: s if not s["error"] and s["current"] else None)(
            self.launcher()), what="the state to clear")
        task = next(r for r in state["rows"] if r["kind"] == "startTask")
        self.assertEqual((task["enabled"], state["query"]), (True, KYOTO))


class NoKeyTests(AvailabilityCase):
    @classmethod
    def app_env(cls):
        # The provider URL shows that nothing is sent anyway.
        return bs.no_key_env(cls.provider.url)

    def test_start_task_shows_the_recovery_state_and_retry_keeps_it_while_there_is_no_key(self):
        """VAL-TASK-011 (a), VAL-CROSS-006"""
        self.open_page("launcher.html")
        before, runs = self.spend(), self.runs()
        self.call("test.announcements", {"reset": True})
        self.assertEqual(self.settings_model(), "Unavailable")
        self.start_with_text()
        self.assert_recovery(runs)
        self.retry("noKey")
        self.retry("noKey")
        self.assert_recovery(runs)
        self.assertEqual(self.announcements(), 1)
        self.assertEqual((self.provider.requests, self.spend()), ([], before))


class UnreachableTests(AvailabilityCase):
    @classmethod
    def app_env(cls):
        # A port nothing listens on until `late.start()`.
        cls.late = bs.DeadHost()
        return bs.provider_env(cls.late.url)

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        cls.late.stop()

    def test_a_run_that_fails_to_connect_latches_the_state_until_a_retry_reaches_the_provider(self):
        """VAL-TASK-011 (b), VAL-CROSS-006"""
        page = self.open_page("launcher.html")
        before = self.spend()
        self.assertEqual(self.settings_model(), "Available")
        self.start_with_text()
        run, = bs.wait_until(lambda: self.new_runs() or None, what="the run")
        failed = bs.wait_until(lambda: (lambda r: r if r["state"] in ENDED else None)(
            self.run_of(run["runId"])), what="the run to end")
        self.assertEqual((failed["state"], failed["reason"]), ("failed", "model unreachable"))
        self.assertEqual(failed["tabId"], page["id"])
        self.assertNotIn(bs.PLACEHOLDER_KEY, self.log_text())
        self.assertEqual(self.settings_model(), "Unavailable")

        runs = self.runs()
        self.call("test.announcements", {"reset": True})
        self.start_with_text()
        self.assert_recovery(runs)
        self.assertEqual(self.announcements(), 1)
        self.retry("unreachable")
        self.assert_recovery(runs)

        self.late.start()
        self.retry("none")
        self.assert_cleared()
        self.assertEqual(self.late.requests, [("HEAD", "/v1")])
        self.assertEqual((self.runs(), self.spend()), (runs, before))
        self.assertEqual(self.settings_model(), "Available")

    def run_of(self, run_id):
        return next(r for r in self.runs() if r["runId"] == run_id)


class NetworkPathTests(AvailabilityCase):
    def test_a_lost_network_path_shows_the_recovery_state_until_it_is_back(self):
        """VAL-TASK-011: the unsatisfied path (the system network itself is not toggled)"""
        self.open_page("launcher.html")
        runs = self.runs()
        self.call("test.networkPath", {"satisfied": False})
        self.addCleanup(self.call, "test.networkPath", {"satisfied": True})
        self.assertEqual(self.settings_model(), "Unavailable")
        self.start_with_text()
        self.assert_recovery(runs)
        self.retry("offline")
        self.assert_recovery(runs)
        self.assertEqual(self.provider.requests, [])
        self.call("test.networkPath", {"satisfied": True})
        self.retry("none")
        self.assert_cleared()
        self.assertEqual(self.provider.requests, [("HEAD", "/v1")])
        self.assertEqual(self.runs(), runs)


if __name__ == "__main__":
    unittest.main()
