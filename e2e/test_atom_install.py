"""The Atom section in Settings (VAL-POL-007): Ready on this Mac's read-only default install, and
with scratch overrides the full Not installed -> Install -> Ready flow, a cancel, a corrupted
archive failing with a reason and no partial model, and a real act on the atom rung without a
restart."""
import io
import os
import shutil
import sqlite3
import subprocess
import tarfile
import unittest

import bs
from appcase import LOG_DIR, save
from test_settings import SettingsCase

ARCHIVE = os.path.join(bs.ROOT, "dist", "atom-tinyclick-4bit-v1.tar.gz")
DONE = {"confirmed", "failed", "cancelled", "outcome-unknown", "quoted"}


def children(pid):
    out = subprocess.run(["ps", "-axo", "pid,ppid,comm"], capture_output=True, text=True).stdout
    rows = [line.split(None, 2) for line in out.splitlines()[1:]]
    by_parent = {}
    for row in rows:
        if len(row) == 3:
            by_parent.setdefault(int(row[1]), []).append((int(row[0]), row[2]))
    found, pending = [], [pid]
    while pending:
        for child, comm in by_parent.get(pending.pop(), []):
            found.append((child, comm))
            pending.append(child)
    return found


def installer_processes(pid):
    names = ("bash", "uv", "curl", "tar", "shasum", "python", "python3")
    return [(p, c) for p, c in children(pid) if os.path.basename(c) in names]


def corrupted_archive(destination):
    """A copy of the release archive with one byte flipped in one model file."""
    altered = False
    with tarfile.open(ARCHIVE) as src, tarfile.open(destination, "w:gz") as dst:
        for member in src.getmembers():
            stream = src.extractfile(member) if member.isfile() else None
            if stream is None:
                dst.addfile(member)
                continue
            data = stream.read()
            if not altered:
                data = bytes([data[0] ^ 0xFF]) + data[1:]
                altered = True
            info = tarfile.TarInfo(member.name)
            info.size = len(data)
            info.mode = member.mode
            dst.addfile(info, io.BytesIO(data))
    assert altered, "the archive holds no file to corrupt"


class AtomReadyTests(SettingsCase):
    """The Barestate defaults on this Mac are installed and read-only: the section reads Ready."""

    def test_atom_is_ready_on_the_default_install(self):
        self.open_settings()
        settings = self.settings()
        self.assertIn("Atom", settings["sections"])
        self.assertEqual(settings["atom"]["state"], "ready", settings["atom"])
        labels = self.labels()
        self.assertIn("Atom status", labels)
        self.assertNotIn("Install Atom", labels)
        self.call("test.screenshot",
                  {"path": os.path.join(LOG_DIR, "atom-ready-default.png"), "window": "settings"})


@unittest.skipUnless(os.path.exists(ARCHIVE), "dist/atom-tinyclick-4bit-v1.tar.gz is missing; run make atom-archive")
class AtomInstallTests(SettingsCase):
    """Scratch installs through the overrides; the real Barestate Runtime and models stay read-only."""

    @classmethod
    def setUpClass(cls):
        cls.scratch = f"/tmp/bs-atom-ui-{os.getpid()}"
        cls.runtime = f"{cls.scratch}/Runtime"
        cls.model = f"{cls.scratch}/models/atom"
        cls.env = {
            "BARESTATE_RUNTIME_DIR": cls.runtime,
            "BARESTATE_ATOM_PYTHON": f"{cls.runtime}/venv/bin/python",
            "BARESTATE_ATOM_MODEL": cls.model,
            "ATOM_ARCHIVE": ARCHIVE,
        }
        cls.fixtures = bs.Fixtures(LOG_DIR).start()
        cls.data_dir = f"/tmp/bs-atom-{os.getpid()}-install"
        cls.app = bs.App(cls.data_dir, LOG_DIR, label=cls.__name__, env=cls.env).start()

    @classmethod
    def tearDownClass(cls):
        cls.app.stop()
        shutil.rmtree(cls.scratch, ignore_errors=True)

    def atom(self):
        return self.settings()["atom"]

    def shot(self, name):
        self.call("test.motion", {"settle": True})
        self.call("test.screenshot",
                  {"path": os.path.join(LOG_DIR, name), "window": "settings"})

    def act_with_instruction(self, instruction):
        """One real act resolved by the instruction ladder; returns the settled journal row."""
        self.app.call("test.releaseDispatch")
        self.app.call("test.verifier", {"mode": "agree"})
        self.app.call("test.grounding", {"reset": True})
        tab = self.open_page("ground.html")
        session = "s-atom-install"
        request = self.call("request_control", {"sessionId": session, "tabId": tab["id"]})
        if request["state"] == "pending":
            decided = self.call("control.decide",
                                {"requestId": request["requestId"], "allow": True})
            self.assertEqual(decided["state"], "granted")
        else:
            self.assertEqual(request["state"], "granted", request)
        observation = self.call("observe", {"tabId": tab["id"]})
        row = self.call("act", {"sessionId": session, "clientActionId": "a1",
                                "observationId": observation["id"], "kind": "click",
                                "instruction": instruction})
        final = bs.wait_until(
            lambda: (lambda r: r if r["state"] in DONE else None)(self.call(
                "action_status", {"sessionId": session, "clientActionId": "a1"})),
            timeout=60, what="the act to finish")
        with sqlite3.connect(f"file:{self.data_dir}/barestate.sqlite?mode=ro", uri=True) as db:
            journal = db.execute("select state, rung from actions where id = ?",
                                 (final["id"],)).fetchone()
        return final, journal

    def test_1_cancel_stops_the_install_and_its_tree(self):
        self.open_settings()
        atom = self.atom()
        self.assertEqual(atom["state"], "not-installed", atom)
        self.assertIn("Install Atom", self.labels())
        self.shot("atom-not-installed.png")
        self.call("test.click", {"target": "settings.atom.install"})
        bs.wait_until(lambda: self.atom()["state"] == "installing" and self.atom()["lines"] > 0,
                      what="the install to start with progress")
        self.shot("atom-installing.png")
        self.call("test.click", {"target": "settings.atom.install"})  # the button is now Cancel
        bs.wait_until(lambda: self.atom()["state"] == "not-installed",
                      what="not installed after the cancel")
        bs.wait_until(lambda: not installer_processes(self.app.proc.pid), timeout=10,
                      what="the installer process tree to exit")
        self.assertFalse(os.path.exists(f"{self.runtime}/venv/bin/python"),
                         "a cancelled install left a runtime behind")

    def test_2_install_shows_progress_ends_ready_and_the_next_act_uses_atom(self):
        self.open_settings()
        self.assertEqual(self.atom()["state"], "not-installed")
        self.call("test.click", {"target": "settings.atom.install"})
        bs.wait_until(lambda: self.atom()["state"] == "installing" and self.atom()["lines"] > 0,
                      what="the install to start with progress")
        seen = bs.wait_until(lambda: self.atom()["state"] == "ready" and self.atom(),
                             timeout=900, what="the install to finish")
        save("atom-install-ready.json", seen)
        self.assertTrue(os.path.exists(f"{self.runtime}/venv/bin/python"))
        self.assertTrue(os.path.isdir(self.model))
        self.shot("atom-ready-scratch.png")
        self.assertNotIn("Install Atom", self.labels())
        # Without a restart: the next act re-resolves Atom and the atom rung grounds it. The
        # window stays open: closing is covered by test_settings.py.
        final, journal = self.act_with_instruction("click Save")
        self.assertEqual(final["state"], "confirmed", final)
        self.assertEqual(journal, ("confirmed", "atom"), journal)
        self.assertEqual(self.call("test.grounding", {})["calls"], ["atom: click Save"])
        save("atom-act.json", {"row": final, "journal": journal})

    def test_3_a_corrupted_archive_fails_with_a_reason_and_leaves_no_partial_model(self):
        corrupted = f"{self.scratch}/corrupted.tar.gz"
        corrupted_archive(corrupted)
        model2 = f"{self.scratch}/models/atom2"
        self.app.stop()
        env = dict(self.env, BARESTATE_ATOM_MODEL=model2, ATOM_ARCHIVE=corrupted)
        type(self).app = bs.App(f"/tmp/bs-atom-{os.getpid()}-fail", LOG_DIR,
                                label="AtomFail", env=env).start()
        self.open_settings()
        self.assertEqual(self.atom()["state"], "not-installed", self.atom())
        self.call("test.click", {"target": "settings.atom.install"})
        failed = bs.wait_until(lambda: self.atom()["state"] == "failed" and self.atom(),
                               timeout=300, what="the install to fail")
        self.assertIn("checksum", failed["detail"], failed)
        self.shot("atom-failed.png")
        self.assertFalse(os.path.exists(model2), "a failed install left a model behind")
        leftovers = [name for name in os.listdir(os.path.dirname(model2))
                     if name.startswith(".atom-download-")] \
            if os.path.isdir(os.path.dirname(model2)) else []
        self.assertEqual(leftovers, [], "a failed install left staging dirs behind")
        # Retry runs the installer again and reports the same clear failure.
        self.assertIn("Try again", self.labels())
        self.call("test.click", {"target": "settings.atom.install"})
        again = bs.wait_until(
            lambda: self.atom()["state"] == "failed" and self.atom()["installs"] >= 2
            and self.atom(),
            timeout=300, what="the retried install to fail again")
        self.assertIn("checksum", again["detail"], again)
        save("atom-failed.json", {"first": failed, "retry": again})
