"""The crash guard in bs.py: a new crash report, a crash signal or an exception in stderr fails."""
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from datetime import datetime, timedelta, timezone
from unittest import mock

import bs


class Exited:
    """A child that already ended with `returncode`. A harness self-test must not make a real
    process die of a crash signal: macOS writes a report to ~/Library/Logs/DiagnosticReports for it."""
    pid = 4242

    def __init__(self, returncode):
        self.returncode = returncode

    def poll(self):
        return self.returncode

    def wait(self, timeout=None):
        return self.returncode

    def kill(self):
        pass


class CrashGuardTests(unittest.TestCase):
    def setUp(self):
        self.reports = tempfile.mkdtemp(prefix="bs-reports-")
        self.stderr = os.path.join(self.reports, "stderr.log")
        self.addCleanup(shutil.rmtree, self.reports, ignore_errors=True)

    def touch(self, name, content="", pid=None):
        with open(os.path.join(self.reports, name), "w") as out:
            out.write(content if pid is None else f'{{"bug_type": "309"}}\n{{"pid": {pid}}}\n')

    def problems(self, before, pids=(4242,)):
        return bs.crash_problems(before, self.stderr, set(pids), self.reports)

    def test_a_clean_run_has_no_problems(self):
        self.touch("Barestate-old.ips")
        self.touch("stderr.log", "barestate: ready\n")
        before = bs.crash_reports(self.reports)
        self.touch("clang-2026.ips")
        self.assertEqual(self.problems(before), [])

    def test_a_new_barestate_or_photon_report_fails(self):
        before = bs.crash_reports(self.reports)
        self.touch("Barestate-2026-10-30-000000.ips", pid=4242)
        self.touch("Photon-2026-10-30-000001.ips", pid=4242)
        found = self.problems(before)
        self.assertEqual(len(found), 2)
        self.assertTrue(all("crash report" in problem for problem in found), found)

    def test_a_report_of_a_process_we_did_not_launch_is_ignored(self):
        before = bs.crash_reports(self.reports)
        self.touch("Barestate-2026-10-30-000000.ips", pid=999)
        self.assertEqual(self.problems(before), [])

    def stamped(self, name, when, pid=4242):
        header = json.dumps({"bug_type": "309", "timestamp": when.strftime("%Y-%m-%d %H:%M:%S.00 %z")})
        with open(os.path.join(self.reports, name), "w") as out:
            out.write(f'{header}\n{{"pid": {pid}}}\n')

    def test_a_stale_report_that_reappears_in_the_listing_is_not_new(self):
        # Seen in a full make e2e: a deliberate crash's report landed after this check's snapshot,
        # and its pid had been handed to a later process.
        long_ago = datetime.now(timezone.utc) - timedelta(hours=2)
        self.stamped("Barestate-2026-10-31-040125.ips", long_ago)
        began = time.time()
        found = bs.crash_problems(set(), self.stderr, {4242}, self.reports, since=began)
        self.assertEqual(found, [])

    def test_a_fresh_pid_correlated_report_still_fails_with_a_start_time(self):
        began = time.time() - 5
        self.stamped("Barestate-2026-10-31-050000.ips", datetime.now(timezone.utc))
        found = bs.crash_problems(set(), self.stderr, {4242}, self.reports, since=began)
        self.assertEqual(len(found), 1, found)
        self.touch("Barestate-no-timestamp.ips", pid=4242)  # file time stands in for the header
        self.assertEqual(len(bs.crash_problems(set(), self.stderr, {4242}, self.reports, since=began)), 2)

    def test_stop_ignores_a_stale_report_of_a_reused_pid(self):
        app = bs.App(os.path.join(self.reports, "data"), self.reports, label="fake")
        app.stderr_path = self.stderr
        app.reports_before = set()
        app.proc = Exited(0)
        self.stamped("Barestate-old.ips", datetime.now(timezone.utc) - timedelta(hours=2), pid=4242)
        with mock.patch.object(bs, "CRASH_REPORT_DIR", self.reports):
            app.stop()

    def test_stop_fails_when_the_app_dies_on_a_crash_signal_during_shutdown(self):
        app = bs.App(os.path.join(self.reports, "data"), self.reports, label="fake")
        app.stderr_path = self.stderr
        app.reports_before = set()
        app.proc = Exited(-signal.SIGTRAP)
        with self.assertRaises(AssertionError) as raised:
            app.stop()
        self.assertIn("SIGTRAP", str(raised.exception))

    def test_an_exception_in_stderr_fails(self):
        for marker in ("uncaught exception", "Terminating app"):
            self.touch("stderr.log", f"*** {marker} due to NSInvalidArgumentException\n")
            self.assertEqual(len(self.problems(set())), 1, marker)



class ExitGuardTests(unittest.TestCase):
    """stop() accepts the exit status a test declared and nothing else."""

    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="bs-exit-")
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        patch = mock.patch.object(bs, "QUIT_TIMEOUT", 1)
        patch.start()
        self.addCleanup(patch.stop)

    def app(self, script):
        """A stand-in app that stop-app.sh finds through app.pid and ends with SIGTERM."""
        app = bs.App(os.path.join(self.directory, "data"), self.directory, label="fake")
        app.stderr_path = os.path.join(self.directory, "stderr.log")
        app.reports_before = set()
        os.makedirs(os.path.join(app.data_dir, "logs"))
        with open(os.path.join(app.data_dir, "logs", "photon.log"), "w") as log:
            log.write("quit request\nquit message loop ended\n")
        ready = os.path.join(self.directory, "ready")
        if os.path.exists(ready):
            os.remove(ready)
        app.proc = subprocess.Popen(["sh", "-c", f"{script}; touch {ready}; while :; do sleep 0.1; done"])
        self.addCleanup(app.proc.kill)
        with open(os.path.join(app.data_dir, "app.pid"), "w") as pid:
            pid.write(str(app.proc.pid))
        bs.wait_until(lambda: os.path.exists(ready), what="the stand-in to install its trap")
        return app

    def stop_error(self, app):
        with self.assertRaises(AssertionError) as raised:
            app.stop()
        return str(raised.exception)

    def test_exit_problems_accept_zero_and_nothing_else_by_default(self):
        self.assertEqual(bs.exit_problems(0), [])
        self.assertEqual(bs.exit_problems(2), ["app exited with status 2"])
        self.assertEqual(bs.exit_problems(-signal.SIGTERM), ["app exited by signal SIGTERM"])
        self.assertEqual(bs.exit_problems(-signal.SIGKILL), ["app exited by signal SIGKILL"])
        self.assertEqual(bs.exit_problems(-signal.SIGTRAP, (-signal.SIGTRAP, -signal.SIGABRT)), [])
        self.assertEqual(len(bs.exit_problems(0, (-signal.SIGSEGV,))), 1)

    def test_a_quit_that_exits_zero_passes(self):
        self.app("trap 'exit 0' TERM").stop()

    def test_a_quit_that_exits_with_a_failure_status_fails(self):
        # Chromium's teardown watchdog ends a slow quit this way.
        self.assertIn("status 2", self.stop_error(self.app("trap 'exit 2' TERM")))

    def test_an_app_that_never_handles_sigterm_fails(self):
        self.assertIn("signal SIGTERM", self.stop_error(self.app(":")))

    def test_a_failure_status_before_stop_fails(self):
        app = self.app("trap 'exit 0' TERM")
        app.proc.kill()
        app.proc.wait()
        self.assertIn("signal SIGKILL", self.stop_error(app))

    def test_a_hung_quit_is_killed_and_fails_with_the_log_tail(self):
        message = self.stop_error(self.app("trap '' TERM"))
        self.assertIn("quit hung", message)
        self.assertIn("quit message loop ended", message)

    def test_a_declared_signal_exit_passes_and_another_one_fails(self):
        app = self.app(":")
        app.allow_exit(-signal.SIGTERM)
        app.stop()
        app = self.app("trap 'exit 0' TERM")
        app.proc = Exited(-signal.SIGSEGV)
        app.allow_exit(-signal.SIGTRAP, -signal.SIGABRT)
        self.assertIn("signal SIGSEGV", self.stop_error(app))

    def test_a_declared_exit_does_not_excuse_a_hung_quit(self):
        app = self.app("trap '' TERM")
        app.allow_exit(-signal.SIGKILL)
        self.assertIn("quit hung", self.stop_error(app))

    def test_a_crash_that_never_happens_fails(self):
        app = self.app("trap 'exit 0' TERM")
        app.allow_exit(-signal.SIGTRAP)
        self.assertIn("status 0", self.stop_error(app))


class CodeSignCloneGuardTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="bs-clones-")
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        patch = mock.patch.object(bs, "CLONE_DIR", self.directory)
        patch.start()
        self.addCleanup(patch.stop)

    def clone(self, name):
        entry = os.path.join(self.directory, name)
        binary = os.path.join(entry, "Photon.app.bundle", "Contents", "MacOS", "Barestate")
        os.makedirs(os.path.dirname(binary))
        with open(binary, "w") as out:
            out.write("binary")
        return entry

    def test_only_entries_created_since_the_snapshot_without_a_live_owner_are_abandoned(self):
        old = self.clone("code_sign_clone.old")
        before = bs.clone_entries()
        new = self.clone("code_sign_clone.new")
        self.assertEqual(before, {old})
        self.assertEqual(bs.abandoned_clones(before, timeout=0), [new])

    def test_an_entry_whose_binary_a_live_process_has_open_is_not_abandoned(self):
        entry = self.clone("code_sign_clone.live")
        with open(os.path.join(entry, "Photon.app.bundle", "Contents", "MacOS", "Barestate")):
            self.assertEqual(bs.abandoned_clones(set(), timeout=0), [])
        self.assertEqual(bs.abandoned_clones(set(), timeout=0), [entry])

    def test_an_entry_chromium_is_still_deleting_is_waited_for(self):
        entry = self.clone("code_sign_clone.going")
        threading.Timer(0.3, shutil.rmtree, [entry]).start()
        self.assertEqual(bs.abandoned_clones(set(), timeout=5), [])

    def test_a_symlinked_clone_directory_is_ignored_and_never_followed(self):
        target = tempfile.mkdtemp(prefix="bs-clones-target-")
        self.addCleanup(shutil.rmtree, target, ignore_errors=True)
        os.mkdir(os.path.join(target, "code_sign_clone.x"))
        link = self.directory + "-link"
        os.symlink(target, link)
        self.addCleanup(os.remove, link)
        with mock.patch.object(bs, "CLONE_DIR", link):
            self.assertEqual(bs.clone_entries(), set())
            bs.reap_clones([os.path.join(link, "code_sign_clone.x")])
        self.assertEqual(os.listdir(target), ["code_sign_clone.x"])

    def test_reaping_removes_the_entries(self):
        entry = self.clone("code_sign_clone.gone")
        bs.reap_clones([entry])
        self.assertEqual(os.listdir(self.directory), [])

    def stopped_app(self, command):
        app = bs.App(os.path.join(self.directory, "data"), self.directory, label="fake")
        app.stderr_path = os.path.join(self.directory, "stderr.log")
        app.reports_before = set()
        app.clones_before = bs.clone_entries()
        app.proc = subprocess.Popen(["sh", "-c", command])
        return app

    def test_a_clean_exit_that_leaves_a_clone_fails_and_removes_it(self):
        app = self.stopped_app("exit 0")
        entry = self.clone("code_sign_clone.leak")
        with mock.patch.object(bs, "CLONE_WAIT_SECONDS", 0):
            with self.assertRaises(AssertionError) as raised:
                app.stop()
        self.assertIn("code_sign_clone.leak", str(raised.exception))
        self.assertFalse(os.path.exists(entry))

    def test_a_clone_left_by_a_killed_app_is_removed_without_failing(self):
        app = self.stopped_app("kill -KILL $$")
        app.allow_exit(-signal.SIGKILL)
        entry = self.clone("code_sign_clone.killed")
        with mock.patch.object(bs, "CLONE_WAIT_SECONDS", 0):
            app.stop()
        self.assertFalse(os.path.exists(entry))

    def test_an_app_that_removed_its_clone_passes(self):
        app = self.stopped_app("exit 0")
        with mock.patch.object(bs, "CLONE_WAIT_SECONDS", 0):
            app.stop()


IPS_BODY = {
    "pid": 4242, "exception": {"type": "EXC_BREAKPOINT", "signal": "SIGTRAP"},
    "termination": {"indicator": "Trace/BPT trap: 5"}, "faultingThread": 1,
    "usedImages": [{"name": "dyld"}, {"name": "AppKit"}],
    "threads": [{"frames": []}, {"frames": [
        {"symbol": "+[NSApplication _crashOnException:]", "imageIndex": 1},
        {"imageOffset": 16, "imageIndex": 0}]}],
    "asiBacktraces": ["0   CoreFoundation  0x1 __exceptionPreprocess + 176\n1   libobjc  0x2 objc_exception_throw + 88"],
}


class LogCopyTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bs-logcopy-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.addCleanup(setattr, bs, "test_log_dir", bs.test_log_dir)

    def app(self, label, photon="launch\n", cef=None):
        data = os.path.join(self.root, label)
        os.makedirs(os.path.join(data, "logs"))
        with open(os.path.join(data, "logs", "photon.log"), "w") as out:
            out.write(photon)
        if cef is not None:
            with open(os.path.join(data, "logs", "cef.log"), "w") as out:
                out.write(cef)
        return bs.App(data, self.root, label=label)

    def test_logs_are_copied_into_the_current_test_directory(self):
        bs.test_log_dir = os.path.join(self.root, "out", "test_x")
        self.app("one", cef="warn\n").copy_logs()
        self.assertEqual(sorted(os.listdir(bs.test_log_dir)), ["cef.log", "photon.log"])

    def test_a_second_app_in_the_same_test_gets_its_own_file_names(self):
        bs.test_log_dir = os.path.join(self.root, "out", "test_y")
        self.app("one").copy_logs()
        self.app("two").copy_logs()
        self.assertEqual(sorted(os.listdir(bs.test_log_dir)), ["photon.log", "photon.two.log"])

    def test_nothing_is_copied_outside_a_run(self):
        bs.test_log_dir = None
        self.app("one").copy_logs()
        self.assertEqual(os.listdir(self.root), ["one"])

    def test_the_tail_keeps_the_last_lines(self):
        path = os.path.join(self.root, "photon.log")
        with open(path, "w") as out:
            out.write("".join(f"line {n}\n" for n in range(80)))
        self.assertEqual(bs.tail(path, 50)[0], "line 30")
        self.assertEqual(bs.tail(os.path.join(self.root, "missing"), 50), [])

    def test_the_summary_names_the_exception_and_the_faulting_frames(self):
        path = os.path.join(self.root, "Barestate-x.ips")
        with open(path, "w") as out:
            out.write('{"bug_type": "309"}\n' + json.dumps(IPS_BODY))
        text = "\n".join(bs.crash_summary(path))
        for expected in ("EXC_BREAKPOINT", "SIGTRAP", "_crashOnException", "AppKit", "objc_exception_throw"):
            self.assertIn(expected, text)

    def test_the_newest_report_of_a_launched_app_is_found(self):
        for name, pid, age in (("Barestate-a.ips", 4242, 30), ("Photon-b.ips", 4242, 10),
                               ("Barestate-c.ips", 999, 0)):
            path = os.path.join(self.root, name)
            with open(path, "w") as out:
                out.write(f'{{"bug_type": "309"}}\n{{"pid": {pid}}}\n')
            os.utime(path, (time.time() - age,) * 2)
        self.assertEqual(os.path.basename(bs.newest_crash_report({4242}, self.root)), "Photon-b.ips")
        self.assertIsNone(bs.newest_crash_report({1}, self.root))

    def test_reaping_removes_only_reports_of_deliberate_crashes(self):
        for name, pid in (("Barestate-a.ips", 4242), ("Barestate-b.ips", 999)):
            with open(os.path.join(self.root, name), "w") as out:
                out.write(f'{{"bug_type": "309"}}\n{{"pid": {pid}}}\n')
        self.addCleanup(bs.expected_crash_pids.clear)
        bs.expected_crash_pids[4242] = set()
        self.assertEqual(bs.reap_crash_reports(timeout=0, directory=self.root), set())
        self.assertEqual(os.listdir(self.root), ["Barestate-b.ips"])

    def test_reaping_records_a_deliberate_crash_that_was_a_bad_access(self):
        self.addCleanup(bs.expected_crash_pids.clear)
        self.addCleanup(bs.faulted_reports.clear)
        for name, pid, kind in (("Barestate-a.ips", 4242, "EXC_BAD_ACCESS"),
                                ("Barestate-b.ips", 4343, "EXC_CRASH")):
            with open(os.path.join(self.root, name), "w") as out:
                out.write(f'{{"bug_type": "309"}}\n{{"pid": {pid}, "exception": {{"type": "{kind}"}}}}\n')
            bs.expected_crash_pids[pid] = set()
        bs.reap_crash_reports(timeout=0, directory=self.root)
        self.assertEqual(bs.faulted_reports, ["Barestate-a.ips"])
        self.assertEqual(os.listdir(self.root), [])

    def test_reaping_keeps_a_report_that_existed_before_the_launch(self):
        with open(os.path.join(self.root, "Barestate-old.ips"), "w") as out:
            out.write('{"bug_type": "309"}\n{"pid": 4242}\n')
        bs.expected_crash_pids.clear()  # an app another test module stopped may have left a pid
        self.addCleanup(bs.expected_crash_pids.clear)
        bs.expected_crash_pids[4242] = {"Barestate-old.ips"}
        self.assertEqual(bs.reap_crash_reports(timeout=0, directory=self.root), {4242})
        self.assertEqual(os.listdir(self.root), ["Barestate-old.ips"])

    def test_failure_context_shows_the_tail_and_the_crash_summary(self):
        dest = os.path.join(self.root, "out")
        os.makedirs(dest)
        with open(os.path.join(dest, "photon.log"), "w") as out:
            out.write("".join(f"event {n}\n" for n in range(60)))
        with open(os.path.join(self.root, "Barestate-z.ips"), "w") as out:
            out.write('{"bug_type": "309"}\n' + json.dumps(IPS_BODY))
        text = bs.failure_context(dest, {4242}, self.root)
        self.assertIn("event 59", text)
        self.assertNotIn("event 9\n", text)
        self.assertIn("EXC_BREAKPOINT", text)


class FixtureVersionTests(unittest.TestCase):
    """`Fixtures` reuses a server only when it runs the current fixtures/server.py, replaces a stale
    one of this repo and never touches anyone else's listener. Scratch ports 47881 and 47882."""

    def setUp(self):
        self.scratch = tempfile.mkdtemp(prefix="bs-fixture-version-")
        self.procs = []
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)
        self.addCleanup(self.reap)

    def reap(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.terminate()
                proc.wait()

    def spawn(self, argv, cwd):
        proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.procs.append(proc)
        return proc

    def serve(self, source, port, cwd):
        self.spawn([sys.executable, source, "--port", str(port)], cwd)
        fixtures = bs.Fixtures(port=port)
        bs.wait_until(lambda: fixtures.version() is not None, 10, what="the scratch server")
        return fixtures

    def test_health_reports_a_version_derived_from_the_server_file(self):
        fixtures = self.serve(os.path.join(bs.ROOT, "fixtures", "server.py"), 47881, bs.ROOT)
        self.assertEqual(fixtures.version(), bs.fixture_version())
        stale = os.path.join(self.scratch, "server.py")
        with open(os.path.join(bs.ROOT, "fixtures", "server.py")) as source, open(stale, "w") as out:
            out.write(source.read() + "\n# older\n")
        other = self.serve(stale, 47882, bs.ROOT)
        self.assertNotEqual(other.version(), bs.fixture_version())

    def test_a_stale_server_of_this_repo_is_replaced(self):
        # Launched as services.yaml does, by a path relative to the repo; reported as older than
        # the file on disk by the first version check only.
        self.spawn([sys.executable, "fixtures/server.py", "--port", "47881"], bs.ROOT)
        old = self.procs[-1]
        bs.wait_until(lambda: bs.listener_pid(47881) == old.pid, 10, what="the repo's server")
        fixtures = bs.Fixtures(port=47881)
        current, checks = bs.fixture_version, []

        def older_once():
            checks.append(1)
            return "older" if len(checks) == 1 else current()
        with mock.patch.object(bs, "fixture_version", older_once):
            fixtures.start()
        self.addCleanup(fixtures.stop)
        self.assertIsNotNone(old.poll(), "the stale server is still running")
        self.assertEqual(fixtures.version(), current())
        with urllib.request.urlopen("http://127.0.0.1:47881/settle.html", timeout=5) as reply:
            self.assertEqual(reply.status, 200)

    def refuses_foreign_server(self, *interpreter_args):
        foreign = os.path.join(self.scratch, "server.py")
        with open(foreign, "w") as out:
            out.write("import http.server\nhttp.server.test(HandlerClass="
                      "http.server.SimpleHTTPRequestHandler, port=47881, bind='127.0.0.1')\n")
        proc = self.spawn([sys.executable, *interpreter_args, foreign], bs.ROOT)
        bs.wait_until(lambda: bs.listener_pid(47881) == proc.pid, 10, what="the foreign server")
        with self.assertRaises(RuntimeError):
            bs.Fixtures(port=47881).start()
        self.assertIsNone(proc.poll())

    def test_a_same_named_server_at_another_path_is_refused_and_survives(self):
        self.refuses_foreign_server()

    def test_an_interpreter_option_cannot_pass_this_repos_script_as_its_operand(self):
        self.refuses_foreign_server("-X", "fixtures/server.py")

    def test_an_unknown_listener_is_never_killed(self):
        stranger = self.spawn([sys.executable, "-m", "http.server", "47881", "--bind", "127.0.0.1"],
                              self.scratch)
        bs.wait_until(lambda: bs.listener_pid(47881) == stranger.pid, 10, what="the stranger")
        with self.assertRaises(RuntimeError) as raised:
            bs.Fixtures(port=47881).start()
        self.assertIn("47881", str(raised.exception))
        self.assertIn("not a fixture server of this repo", str(raised.exception))
        self.assertIsNone(stranger.poll())

    def test_another_script_run_from_this_repo_is_not_a_fixture_server(self):
        other = os.path.join(self.scratch, "other_server.py")
        with open(other, "w") as out:
            out.write("import http.server\nhttp.server.test(HandlerClass=http.server.SimpleHTTPRequestHandler,"
                      " port=47881, bind='127.0.0.1')\n")
        proc = self.spawn([sys.executable, other], bs.ROOT)
        bs.wait_until(lambda: bs.listener_pid(47881) == proc.pid, 10, what="the other server")
        with self.assertRaises(RuntimeError):
            bs.Fixtures(port=47881).start()
        self.assertIsNone(proc.poll())

    def test_a_current_server_is_reused(self):
        fixtures = self.serve(os.path.join(bs.ROOT, "fixtures", "server.py"), 47881, bs.ROOT)
        pid = bs.listener_pid(47881)
        fixtures.start()
        self.assertEqual(bs.listener_pid(47881), pid)
        self.assertIsNone(fixtures.proc)


if __name__ == "__main__":
    unittest.main()
