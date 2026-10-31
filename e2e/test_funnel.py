"""The Funnel mount (architecture §8, VAL-REMOTE-013) against a stand-in `tailscale`.

The stand-in records its arguments and answers `status --json` with a made-up host, so the exact
commands Remote runs are checked without touching this Mac's real Funnel. The real mount is
checked by hand against `tailscale funnel status --json` (see DECISIONS.md).
"""
import os
import shutil
import signal
import socket
import stat
import tempfile
import unittest

import bs
from appcase import LOG_DIR

MOUNT = "funnel --bg --https=10000 --set-path=/barestate http://127.0.0.1:47820"
UNMOUNT = "funnel --https=10000 --set-path=/barestate off"
STATUS = "status --json"


def listening():
    try:
        socket.create_connection(("127.0.0.1", 47820), timeout=1).close()
        return True
    except OSError:
        return False


class FunnelTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bs-fun-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.calls = os.path.join(self.root, "calls")
        self.app = None
        self.addCleanup(self.stop_app)

    def tailscale(self, mount_status=0):
        path = os.path.join(self.root, "tailscale")
        with open(path, "w") as script:
            script.write(f"""#!/bin/sh
echo "$@" >> {self.calls}
case "$1" in
  status) echo '{{"Self":{{"DNSName":"fake.example.test."}}}}' ;;
  funnel) case "$*" in *--bg*) exit {mount_status} ;; esac ;;
esac
""")
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        return path

    def launch(self, funnel="on", mount_status=0):
        env = {"BARESTATE_TAILSCALE": self.tailscale(mount_status)}
        if funnel is not None:
            env["BARESTATE_FUNNEL"] = funnel
        self.app = bs.App(os.path.join(self.root, "d"), LOG_DIR, label="funnel", env=env).start()
        self.app.call("test.key", {"key": ",", "modifiers": ["cmd"]})
        bs.wait_until(lambda: self.app.call("test.ui")["settings"]["open"], what="Settings")

    def stop_app(self):
        if self.app:
            self.app.stop()
            self.app = None

    def toggle(self):
        self.app.call("test.click", {"target": "settings.remote.enable"})

    def seen(self):
        try:
            with open(self.calls) as log:
                return log.read().splitlines()
        except OSError:
            return []

    def remote(self):
        return self.app.call("test.ui")["settings"]["remote"]

    def test_enabling_mounts_and_disabling_unmounts_with_exactly_these_commands(self):
        self.launch()
        self.assertEqual(self.seen(), [], "Remote is off at launch and runs nothing")
        self.toggle()
        bs.wait_until(lambda: self.remote()["on"] and listening(), what="Remote on")
        self.assertEqual(self.seen(), [STATUS, MOUNT])
        self.toggle()
        bs.wait_until(lambda: len(self.seen()) == 3 and not listening(), what="the unmount")
        self.assertEqual(self.seen(), [STATUS, MOUNT, UNMOUNT])
        self.assertFalse(self.remote()["on"])

    def test_quitting_with_remote_on_unmounts_before_the_app_exits(self):
        self.launch()
        self.toggle()
        bs.wait_until(lambda: self.remote()["on"], what="Remote on")
        self.stop_app()
        self.assertEqual(self.seen(), [STATUS, MOUNT, UNMOUNT])
        bs.wait_until(lambda: not listening(), what="the gateway to exit")
        self.assertEqual(self.seen(), [STATUS, MOUNT, UNMOUNT], "the gateway unmounts nothing")

    def kill_app_with_remote_on(self, funnel="on"):
        self.launch(funnel=funnel)
        self.toggle()
        bs.wait_until(lambda: self.remote()["on"] and listening(), what="Remote on")
        self.app.allow_exit(-signal.SIGKILL)
        os.kill(self.app.proc.pid, signal.SIGKILL)
        self.app.proc.wait(timeout=20)
        bs.wait_until(lambda: not listening(), what="the orphaned gateway to exit")

    def test_a_killed_app_has_its_mount_removed_once_by_the_gateway(self):
        self.kill_app_with_remote_on()
        self.assertEqual(self.seen(), [STATUS, MOUNT, UNMOUNT])

    def test_a_killed_app_whose_run_never_mounted_runs_no_unmount(self):
        self.kill_app_with_remote_on(funnel="off")
        self.assertEqual(self.seen(), [STATUS])

    def test_a_killed_app_with_remote_off_runs_nothing(self):
        self.launch()
        self.app.allow_exit(-signal.SIGKILL)
        os.kill(self.app.proc.pid, signal.SIGKILL)
        self.app.proc.wait(timeout=20)
        self.assertEqual(self.seen(), [])

    def test_quitting_with_remote_off_runs_nothing(self):
        self.launch()
        self.stop_app()
        self.assertEqual(self.seen(), [])

    def test_a_failed_mount_leaves_remote_off_and_removes_what_it_may_have_added(self):
        self.launch(mount_status=1)
        self.toggle()
        bs.wait_until(lambda: self.seen() == [STATUS, MOUNT, UNMOUNT], what="the cleanup")
        self.assertFalse(self.remote()["on"])
        self.assertIn("Funnel", self.remote()["status"])
        self.assertFalse(listening())

    def test_a_test_run_does_not_change_funnel_unless_it_asks_to(self):
        self.launch(funnel=None)
        self.toggle()
        bs.wait_until(lambda: self.remote()["on"] and listening(), what="Remote on")
        self.toggle()
        bs.wait_until(lambda: not listening(), what="Remote off")
        self.assertEqual(self.seen(), [STATUS])

    def test_disabling_and_quitting_at_once_still_unmounts(self):
        self.launch()
        self.toggle()
        bs.wait_until(lambda: self.remote()["on"], what="Remote on")
        self.toggle()
        self.stop_app()
        self.assertEqual(self.seen(), [STATUS, MOUNT, UNMOUNT])


if __name__ == "__main__":
    unittest.main()
