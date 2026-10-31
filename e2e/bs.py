#!/usr/bin/env python3
"""Harness for driving the real app: JSON-RPC client, app launcher, fixture server, deadlines.

CLI (used by services.yaml and by hand):
  python3 e2e/bs.py --data-dir /tmp/bs-app status
  python3 e2e/bs.py --data-dir /tmp/bs-app call test.ui '{}'
"""
import argparse
import atexit
import glob
import hashlib
import json
import math
import os
import shutil
import socket
import signal
import subprocess
import sys
import tempfile
import time
import threading
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The one place that names the bundle; the executable inside it keeps the SwiftPM target's name.
APP_BUNDLE = os.path.join(ROOT, ".build", "Photon.app")
APP_EXECUTABLE = "Barestate"
FIXTURE_PORT = 47810
FIXTURE_URL = f"http://127.0.0.1:{FIXTURE_PORT}"


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


class Rpc:
    """One connection to <data-dir>/app.sock."""

    def __init__(self, data_dir, timeout=10):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(os.path.join(data_dir, "app.sock"))
        self.reader = self.sock.makefile("rb")
        self.next_id = 1

    def call(self, method, params=None):
        request = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            request["params"] = params
        self.next_id += 1
        self.send_line(json.dumps(request).encode())
        reply = json.loads(self.reader.readline())
        if "error" in reply:
            raise RpcError(reply["error"]["code"], reply["error"]["message"])
        return reply["result"]

    def send_line(self, data):
        self.sock.sendall(data + b"\n")

    def read_line(self):
        return self.reader.readline()

    def close(self):
        self.reader.close()
        self.sock.close()


def nearest_rank(values, fraction):
    """Nearest-rank percentile: the value at 1-based rank ceil(fraction * n) of the sorted values."""
    ordered = sorted(values)
    return ordered[math.ceil(fraction * len(ordered)) - 1]


def wait_until(predicate, timeout=20, interval=0.05, what="condition"):
    """Polls `predicate` until it returns a truthy value; raises with `what` at the deadline."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            value = predicate()
        except (OSError, ValueError, RpcError):
            value = None
        if value:
            return value
        if time.monotonic() > deadline:
            raise TimeoutError(f"timed out after {timeout}s waiting for {what}")
        time.sleep(interval)


def descendants(pid):
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
    found = []
    for child in out:
        found.append(int(child))
        found.extend(descendants(int(child)))
    return found


BUNDLE_ID = "dev.barestate.browser"
# Chromium clones the launched bundle (~335 MB) here and removes the copy itself on a clean exit.
CLONE_DIR = os.path.normpath(os.path.join(
    subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip(),
    "..", "X", f"{BUNDLE_ID}.code_sign_clone"))
# The removal runs after the process has exited and deletes a whole bundle, so it takes a moment.
CLONE_WAIT_SECONDS = 15


def clone_entries():
    if os.path.islink(CLONE_DIR) or not os.path.isdir(CLONE_DIR):
        return set()
    return {os.path.join(CLONE_DIR, name) for name in os.listdir(CLONE_DIR)}


def clone_in_use(entry):
    """True while a process has the clone's executable open, which is how its owner shows."""
    binaries = glob.glob(os.path.join(glob.escape(entry), "*", "Contents", "MacOS", "*"))
    if not binaries:
        return False
    lsof = subprocess.run(["lsof", "-t", *binaries], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)
    # Exit 1 means "nothing found"; any other failure leaves the owner unknown, so keep the entry.
    return bool(lsof.stdout.split()) or lsof.returncode > 1


def abandoned_clones(before, timeout=None):
    """Entries created since the `before` snapshot that no process uses, once Chromium's own
    removal had `timeout` seconds. Older entries and live apps' clones (ours, or the user's own
    copy of the bundle) are never listed."""
    deadline = time.monotonic() + (CLONE_WAIT_SECONDS if timeout is None else timeout)
    while True:
        found = sorted(entry for entry in clone_entries() - before if not clone_in_use(entry))
        if not found or time.monotonic() >= deadline:
            return found
        time.sleep(0.2)


def reap_clones(entries):
    for entry in entries:
        if os.path.dirname(entry) == CLONE_DIR and not os.path.islink(CLONE_DIR):
            shutil.rmtree(entry, ignore_errors=True)


CRASH_REPORT_DIR = os.path.expanduser("~/Library/Logs/DiagnosticReports")
CRASH_REPORT_PREFIXES = ("Barestate-", "Photon-")
CRASH_STDERR_MARKERS = ("uncaught exception", "Terminating app")


def crash_reports(directory=None):
    directory = directory or CRASH_REPORT_DIR
    try:
        names = os.listdir(directory)
    except OSError:
        return set()
    return {n for n in names if n.endswith(".ips") and n.startswith(CRASH_REPORT_PREFIXES)}


def report_body(path):
    """The JSON body that follows the one-line header of an .ips report."""
    try:
        with open(path) as report:
            report.readline()
            return json.loads(report.read())
    except (OSError, ValueError):
        return {}


def report_pid(path):
    return report_body(path).get("pid")


def report_time(path):
    """When the process crashed, from the report's one-line header; the file's time if that is
    missing or unreadable."""
    try:
        with open(path) as report:
            stamp = json.loads(report.readline())["timestamp"]
        return datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S.%f %z").timestamp()
    except (OSError, ValueError, KeyError, TypeError):
        return os.path.getmtime(path)


launched_pids = set()
expected_crash_pids = {}  # pid -> report names that existed before its launch
# Reaped reports of deliberate crashes that were memory faults: the crash handlers must end the
# process by SIGTRAP or SIGABRT, so a bad access means a handler itself faulted.
faulted_reports = []

LOG_FILES = ("photon.log", "cef.log")
# Set by run.py to the current test's log directory, and passed to subprocesses (the bench) in
# BS_TEST_LOG_DIR; None outside a run.
test_log_dir = os.environ.get("BS_TEST_LOG_DIR")
_copies = {}


def tail(path, count=50):
    try:
        with open(path, errors="replace") as log:
            return log.read().splitlines()[-count:]
    except OSError:
        return []


def newest_crash_report(pids=None, directory=None):
    """The most recently written Barestate/Photon report of a process this harness launched."""
    pids = launched_pids if pids is None else pids
    directory = directory or CRASH_REPORT_DIR
    paths = [os.path.join(directory, name) for name in crash_reports(directory)]
    paths = [path for path in paths if report_pid(path) in pids]
    return max(paths, key=os.path.getmtime, default=None)


def crash_summary(path, frames=12):
    """Exception type, termination and the faulting thread's frames from an .ips report."""
    try:
        with open(path) as report:
            report.readline()
            body = json.loads(report.read())
    except (OSError, ValueError):
        return [f"{path}: unreadable"]
    exception = body.get("exception", {})
    lines = [f"exception: {exception.get('type')} {exception.get('signal')}",
             f"termination: {body.get('termination', {}).get('indicator')}"]
    images = body.get("usedImages", [])
    threads = body.get("threads", [])
    faulting = body.get("faultingThread", 0)
    for frame in (threads[faulting]["frames"] if faulting < len(threads) else [])[:frames]:
        index = frame.get("imageIndex")
        image = images[index].get("name") if index is not None and index < len(images) else "?"
        lines.append(f"  {frame.get('symbol') or hex(frame.get('imageOffset', 0))} ({image})")
    for backtrace in body.get("asiBacktraces", [])[:1]:
        lines += ["asi backtrace:"] + [f"  {line}" for line in backtrace.splitlines()[:frames]]
    return lines


def failure_context(dest, pids=None, directory=None):
    """What to print when a test fails or an app dies: the log tails and the newest crash."""
    out = []
    for name in sorted(os.listdir(dest)) if dest and os.path.isdir(dest) else []:
        if name.startswith("photon") and name.endswith(".log"):
            out += [f"--- last 50 lines of {os.path.join(dest, name)}"] + tail(os.path.join(dest, name))
    report = newest_crash_report(pids, directory)
    if report:
        out += [f"--- newest crash report {report}"] + crash_summary(report)
    return "\n".join(out)


def reap_crash_reports(timeout=90, directory=None):
    """Removes the system crash reports of deliberate crashes. ReportCrash can take over 30 s
    to write one, so this waits (bounded) for the last ones; whatever never lands is left."""
    directory = directory or CRASH_REPORT_DIR
    pending = dict(expected_crash_pids)
    deadline = time.monotonic() + timeout
    while pending:
        for name in crash_reports(directory):
            path = os.path.join(directory, name)
            pid = report_pid(path)
            if pid in pending and name not in pending[pid]:
                if report_body(path).get("exception", {}).get("type") == "EXC_BAD_ACCESS":
                    faulted_reports.append(name)
                os.remove(path)
                pending.pop(pid)
        if time.monotonic() > deadline:
            break
        time.sleep(1)
    for pid in set(expected_crash_pids) - set(pending):
        del expected_crash_pids[pid]
    return set(pending)


def snapshot_logs():
    for app in list(_running):
        app.copy_logs()


def crash_problems(reports_before, stderr_path, pids=None, directory=None, since=0):
    """Everything that shows an app we launched crashed since `reports_before` was taken.

    Only reports of processes this harness started count, so the user's own Barestate does not
    fail a run. A report older than `since` (epoch seconds, when the check began) is a leftover
    that reached the listing late or carries a reused pid, not a crash of this run."""
    directory = directory or CRASH_REPORT_DIR
    pids = launched_pids if pids is None else pids
    problems = [f"new crash report {name} in {directory}"
                for name in sorted(crash_reports(directory) - reports_before)
                if report_pid(os.path.join(directory, name)) in pids
                and report_time(os.path.join(directory, name)) >= since]
    try:
        with open(stderr_path, errors="replace") as err:
            text = err.read()
    except OSError:
        text = ""
    problems += [f"app stderr contains {marker!r}" for marker in CRASH_STDERR_MARKERS
                 if marker in text]
    return problems


def exit_problems(returncode, allowed=(0,)):
    """Why an app's exit status is not acceptable. Only a test that ends the app on purpose widens
    `allowed`; SIGTERM is not among the defaults because the app must handle it and exit 0."""
    if returncode in allowed:
        return []
    if returncode < 0:
        try:
            how = f"signal {signal.Signals(-returncode).name}"
        except ValueError:
            how = f"signal {-returncode}"
        return [f"app exited by {how}"]
    return [f"app exited with status {returncode}"]


QUIT_TIMEOUT = 10  # seconds a SIGTERM quit gets before stop-app.sh escalates to SIGKILL
_running = []


def _cleanup():
    for app in list(_running):
        app.stop()


atexit.register(_cleanup)


class App:
    """The bundled app started through scripts/run-app.sh with its own data dir."""

    def __init__(self, data_dir, log_dir=None, label="app", test_hooks=True, url=None, bundle=None,
                 env=None):
        self.data_dir = data_dir
        self.env = env
        self.crash_expected = False
        self.allowed_exits = (0,)
        self.log_dir = log_dir or os.environ.get("BS_E2E_LOGDIR") \
            or tempfile.mkdtemp(prefix="bs-e2e-logs-")
        self.label = label
        self.args = ["--data-dir", data_dir]
        if test_hooks:
            self.args.append("--test-hooks")
        if url:
            self.args += ["--url", url]
        self.bundle = bundle
        self.proc = None
        self.clones_before = None
        self.began = time.time()

    def start(self, timeout=30, fresh=True):
        if fresh:
            shutil.rmtree(self.data_dir, ignore_errors=True)
        os.makedirs(self.log_dir, exist_ok=True)
        self.stderr_path = os.path.join(self.log_dir, f"{self.label}.stderr.log")
        out = open(os.path.join(self.log_dir, f"{self.label}.stdout.log"), "wb")
        err = open(self.stderr_path, "wb")
        self.reports_before = crash_reports()
        self.clones_before = clone_entries()
        self.began = time.time()
        launcher = os.path.join(self.bundle, "Contents", "MacOS", APP_EXECUTABLE) if self.bundle \
            else os.path.join(ROOT, "scripts", "run-app.sh")
        self.proc = subprocess.Popen(
            [launcher] + self.args, env={**self.base_env(), **(self.env or {})},
            stdin=subprocess.DEVNULL, stdout=out, stderr=err)
        out.close()
        err.close()
        launched_pids.add(self.proc.pid)
        _running.append(self)
        wait_until(lambda: self.status()["ready"], timeout, what="app.status ready")
        return self

    @staticmethod
    def base_env():
        """A run started by a test must not reach the live model unless the test run is live."""
        env = dict(os.environ)
        env["BARESTATE_FUNNEL"] = "off"  # a test run never changes the Mac's Funnel
        if env.get("BARESTATE_LIVE_META") != "1":
            for key in ("MODEL_API_KEY", "BASETEN_API_KEY"):
                env.pop(key, None)
            env["BARESTATE_ENV_FILE"] = "/dev/null"
        return env

    def rpc(self):
        return Rpc(self.data_dir)

    def call(self, method, params=None):
        client = self.rpc()
        try:
            return client.call(method, params)
        finally:
            client.close()

    def status(self):
        return self.call("app.status")

    def tree_pids(self):
        return [self.proc.pid] + descendants(self.proc.pid)

    def copy_logs(self, dest=None):
        """Copies photon.log and cef.log into the current test's directory. The first app of a
        test keeps the plain names; later ones are suffixed with their label."""
        dest = dest or test_log_dir
        if not dest:
            return
        os.makedirs(dest, exist_ok=True)
        first = not any(key[0] == dest for key in _copies)
        suffix = _copies.setdefault((dest, self.data_dir), "" if first else f".{self.label}")
        for name in LOG_FILES:
            source = os.path.join(self.data_dir, "logs", name)
            if os.path.exists(source):
                stem, extension = os.path.splitext(name)
                shutil.copyfile(source, os.path.join(dest, stem + suffix + extension))

    def reap_leftover_clones(self, clean_exit):
        """Removes the clones this app left behind. After a clean exit a leftover is a defect of
        the app, so it is also reported."""
        if self.clones_before is None:
            return []
        left = abandoned_clones(self.clones_before)
        reap_clones(left)
        if not left or not clean_exit:
            return []
        return [f"app left {len(left)} code_sign_clone entries after a clean exit: "
                + ", ".join(os.path.basename(entry) for entry in left)]

    def allow_exit(self, *codes):
        """For tests that end the app on purpose: the exit statuses (negative for a signal) that
        stop() accepts instead of 0."""
        self.allowed_exits = codes

    def expect_crash(self, exits, timeout=30):
        """For tests that crash the app on purpose: waits for it to die, with one of `exits`.
        stop() and the run's final report then ignore the crash itself;
        `reap_crash_reports` removes the reports it caused."""
        self.allow_exit(*exits)
        self.proc.wait(timeout=timeout)
        self.crash_expected = True
        launched_pids.discard(self.proc.pid)
        expected_crash_pids[self.proc.pid] = self.reports_before

    def stop(self, remove_data=True):
        """Quits the app with SIGTERM and fails on anything but the expected exit: a hung quit
        that needed SIGKILL, a signal death, or an unexpected status."""
        if self in _running:
            _running.remove(self)
        problems = []
        if self.proc is not None:
            died_with = self.proc.poll()
            stopped = subprocess.run(
                [os.path.join(ROOT, "scripts", "stop-app.sh"), self.data_dir, str(QUIT_TIMEOUT)],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            forced = "sending SIGKILL" in stopped.stderr
            try:
                self.proc.wait(timeout=QUIT_TIMEOUT + 5)
            except subprocess.TimeoutExpired:
                forced = True
                self.proc.kill()
                self.proc.wait()
            if died_with is None:
                died_with = self.proc.returncode
            if forced:
                problems.append(f"quit hung: no exit within {QUIT_TIMEOUT} s of SIGTERM, killed")
            else:
                problems += exit_problems(died_with, self.allowed_exits)
            if problems:
                problems.append("photon.log tail:\n" + "\n".join(
                    tail(os.path.join(self.data_dir, "logs", "photon.log"), 30)))
            if not self.crash_expected:
                problems += crash_problems(
                    self.reports_before, self.stderr_path, {self.proc.pid}, since=self.began)
            problems += self.reap_leftover_clones(
                clean_exit=died_with == 0 and not self.crash_expected)
            self.proc = None
        self.copy_logs()
        if remove_data:
            shutil.rmtree(self.data_dir, ignore_errors=True)
        if problems:
            raise AssertionError(f"{self.label} did not exit cleanly: " + "; ".join(problems))


def fixture_version():
    """What a server running the current fixtures/server.py reports on /__health."""
    with open(os.path.join(ROOT, "fixtures", "server.py"), "rb") as source:
        return hashlib.sha256(source.read()).hexdigest()[:12]


def listener_pid(port):
    out = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"],
                         capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def owned_by_this_repo(pid):
    """A python process running this checkout's fixtures/server.py, however it was launched
    (absolute path, or relative to its working directory as services.yaml does). A same-named
    script anywhere else is someone else's."""
    argv = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                          capture_output=True, text=True).stdout.split()
    # Only argv[1]: an interpreter option such as `-X fixtures/server.py` takes an operand, so a
    # later argument could be anything.
    script = argv[1] if len(argv) > 1 and not argv[1].startswith("-") else ""
    cwd = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                         capture_output=True, text=True).stdout.split("\nn")[-1].strip()
    return (bool(argv) and os.path.basename(argv[0]).lower().startswith("python")
            and bool(script) and bool(cwd)
            and os.path.realpath(os.path.join(cwd, script))
            == os.path.realpath(os.path.join(ROOT, "fixtures", "server.py")))


class Fixtures:
    """The fixture server on 127.0.0.1:47810. Reuses one running the current fixtures/server.py,
    replaces an older one of this repo, refuses to touch any other listener, and stops only what
    it started."""

    def __init__(self, log_dir=None, port=FIXTURE_PORT):
        self.log_dir = log_dir
        self.port = port
        self.url = f"http://127.0.0.1:{port}"
        self.proc = None

    def version(self):
        """The server's reported version ("" for one that predates versions); None if no answer."""
        try:
            with urllib.request.urlopen(f"{self.url}/__health", timeout=1) as reply:
                return reply.read().decode().partition(" ")[2].strip()
        except OSError:
            return None

    def healthy(self):
        return self.version() is not None

    def start(self):
        if self.version() == fixture_version():
            return self
        if (pid := listener_pid(self.port)) is not None:
            if not owned_by_this_repo(pid):
                raise RuntimeError(
                    f"port {self.port} is held by pid {pid}, not a fixture server of this repo; "
                    "not touching it. Stop it yourself or free the port.")
            os.kill(pid, signal.SIGTERM)
            wait_until(lambda: listener_pid(self.port) is None, 10, what="the stale fixture server to exit")
        log = subprocess.DEVNULL
        if self.log_dir:
            os.makedirs(self.log_dir, exist_ok=True)
            log = open(os.path.join(self.log_dir, "fixtures.log"), "wb")
        self.proc = subprocess.Popen(
            [sys.executable, os.path.join(ROOT, "fixtures", "server.py"), "--port", str(self.port)],
            cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        atexit.register(self.stop)
        wait_until(lambda: self.version() == fixture_version(), 10, what="fixture server health")
        return self

    def log(self, since=0):
        with urllib.request.urlopen(f"{self.url}/__log?since={since}", timeout=5) as reply:
            return reply.read().decode().splitlines()

    def stop(self):
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None


class SelfSignedFixtures:
    """The fixture pages over HTTPS with a certificate nobody trusts, on one port in the test range.
    The key pair is generated into a fresh /tmp directory and removed on stop."""

    def __init__(self, port=47841):
        self.port = port
        self.url = f"https://127.0.0.1:{port}"
        self.proc = None
        self.dir = None

    def start(self):
        self.dir = tempfile.mkdtemp(prefix="bs-cert-", dir="/tmp")
        cert, key = (os.path.join(self.dir, name) for name in ("cert.pem", "key.pem"))
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key,
             "-out", cert, "-subj", "/CN=127.0.0.1", "-days", "1",
             "-addext", "subjectAltName=IP:127.0.0.1"],
            check=True, capture_output=True)
        self.proc = subprocess.Popen(
            [sys.executable, os.path.join(ROOT, "fixtures", "server.py"), "--port", str(self.port),
             "--tls-cert", cert, "--tls-key", key],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        atexit.register(self.stop)
        wait_until(lambda: self.listening(), 10, what="the self-signed fixture to listen")
        return self

    def listening(self):
        try:
            socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
            return True
        except OSError:
            return False

    def stop(self):
        if self.proc is not None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None
        if self.dir:
            shutil.rmtree(self.dir, ignore_errors=True)
            self.dir = None


PLACEHOLDER_KEY = "sk-placeholder-not-a-real-key"
PROVIDER_PORTS = range(47886, 47900)


def provider_port():
    """A free scratch port in the mission range (47880-47899)."""
    for port in PROVIDER_PORTS:
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", port))
            except OSError:
                continue
        return port
    raise RuntimeError("no free scratch port in 47886-47899")


# Overrides that keep an app off the real provider even in a live session.
HERMETIC_ENV = {"BARESTATE_LIVE_META": "", "BASETEN_API_KEY": "", "BARESTATE_ENV_FILE": "/dev/null"}


def provider_env(url):
    """A placeholder key with the Meta provider pointed at `url`: a run can start, and nothing
    reaches the real provider."""
    return {**HERMETIC_ENV, "MODEL_API_KEY": PLACEHOLDER_KEY, "BARESTATE_META_URL": url}


def no_key_env(url):
    """No key anywhere, with `url` shown to nobody: a request there would mean the app sent one."""
    return {**HERMETIC_ENV, "MODEL_API_KEY": "", "BARESTATE_META_URL": url}


class DeadHost(ThreadingHTTPServer):
    """A host standing where the model provider would be. It never serves model output: every
    GET, HEAD and POST is recorded as (method, path) and answered 404, so a run that reaches it
    fails and a test can assert what was sent. Closed until `start`, so the same port is first a
    refused connection and then a server that answers."""

    daemon_threads = True

    def __init__(self, port=None):
        self.port = port or provider_port()
        self.url = f"http://127.0.0.1:{self.port}/v1"
        self.requests = []
        self.thread = None

    def start(self):
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def handle_any(self):
                outer.requests.append((self.command, self.path))
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()

            do_GET = do_HEAD = do_POST = handle_any

            def log_message(self, *args):
                pass
        super().__init__(("127.0.0.1", self.port), Handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()
        atexit.register(self.stop)
        return self

    def stop(self):
        if self.thread is not None:
            self.shutdown()
            self.server_close()
            self.thread = None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("command", choices=["status", "call"])
    parser.add_argument("method", nargs="?")
    parser.add_argument("params", nargs="?")
    args = parser.parse_args()
    client = Rpc(args.data_dir)
    try:
        if args.command == "status":
            result = client.call("app.status")
            print(json.dumps(result))
            sys.exit(0 if result.get("ready") else 1)
        print(json.dumps(client.call(args.method, json.loads(args.params) if args.params else None)))
    except RpcError as error:
        print(error, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
