#!/usr/bin/env python3
"""make e2e: run every e2e/test_*.py unattended and log to .logs/e2e/<timestamp>/.

Starts the fixture server (port 47810) itself, each test starts its own app, and everything
started here is stopped on exit.
"""
import os
import signal
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bs  # noqa: E402


class LoggingResult(unittest.TextTestResult):
    """Also writes <log-dir>/<test id>.log with the outcome and any traceback."""

    def __init__(self, stream, descriptions, verbosity, log_dir):
        super().__init__(stream, descriptions, verbosity)
        self.log_dir = log_dir

    def startTest(self, test):
        super().startTest(test)
        bs.test_log_dir = os.path.join(self.log_dir, test.id())

    def stopTest(self, test):
        bs.snapshot_logs()
        super().stopTest(test)

    def show_context(self):
        bs.snapshot_logs()
        text = bs.failure_context(bs.test_log_dir)
        if text:
            print(text, flush=True)

    def record(self, test, outcome, detail=""):
        with open(os.path.join(self.log_dir, f"{test.id()}.log"), "a") as out:
            out.write(f"{outcome}\n{detail}")

    def addSuccess(self, test):
        super().addSuccess(test)
        self.record(test, "ok")

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.show_context()
        self.record(test, "FAIL", self._exc_info_to_string(err, test))

    def addError(self, test, err):
        super().addError(test, err)
        self.show_context()
        self.record(test, "ERROR", self._exc_info_to_string(err, test))

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.record(test, "skipped", reason)


def main():
    stamp = time.strftime("%Y%m%d-%H%M%S")
    log_dir = os.path.join(bs.ROOT, ".logs", "e2e", stamp)
    os.makedirs(log_dir)
    os.environ["BS_E2E_LOGDIR"] = log_dir
    print(f"e2e logs: {log_dir}")

    # A terminated run still has to stop its app and fixture server (atexit does the stopping).
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

    began = time.time()
    reports_before = bs.crash_reports()
    clones_before = bs.clone_entries()
    fixtures = bs.Fixtures(log_dir).start()
    try:
        suite = unittest.defaultTestLoader.discover(HERE, pattern="test_*.py")
        with open(os.path.join(log_dir, "summary.txt"), "w") as summary:
            runner = unittest.TextTestRunner(
                stream=summary, verbosity=2,
                resultclass=lambda *args: LoggingResult(*args, log_dir=log_dir))
            result = runner.run(suite)
        print(open(os.path.join(log_dir, "summary.txt")).read())
        # A report can land after the app that crashed has already been stopped.
        bs.reap_crash_reports()
        crashes = bs.crash_problems(reports_before, os.devnull, since=began)
        crashes += [f"deliberate crash {name} was EXC_BAD_ACCESS" for name in bs.faulted_reports]
        for problem in crashes:
            print(f"CRASH: {problem}")
        # Every app stops through bs.App, which reaps its own clone; this catches any other launch.
        stray = bs.abandoned_clones(clones_before)
        bs.reap_clones(stray)
        for entry in stray:
            print(f"LEAK: code_sign_clone entry {os.path.basename(entry)} outlived the run")
        ok = result.wasSuccessful() and result.testsRun > 0 and not crashes and not stray
        sys.exit(0 if ok else 1)
    finally:
        fixtures.stop()


if __name__ == "__main__":
    main()
