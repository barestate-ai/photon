"""The release zip, unzipped and run with test hooks off (VAL-SHIP-008, VAL-STABILITY-002).

Reads the zip from BARESTATE_RELEASE_ZIP, else the newest dist/Photon-*.zip (`make dist`). With
hooks off only product surfaces exist: app.status on app.sock, the bundled barestate-mcp, and menu
items pressed through System Events by pid (never keystrokes). Run it alone:
  python3 e2e/test_release.py
"""
import glob
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest

import bs
from test_engine import LIBC, command_of, process_type
from test_mcp import TOOLS, Stdio, data

LOG_DIR = os.environ.get("BS_E2E_LOGDIR") or tempfile.mkdtemp(prefix="bs-e2e-logs-")
DOCS = os.path.join(bs.ROOT, "docs", "muse-code.md")
FIXTURE_PAGE = f"{bs.FIXTURE_URL}/index.html"
PUBLIC_PAGE = "https://example.com/"
LAUNCHES = 5


def release_zip():
    zips = sorted(glob.glob(os.path.join(bs.ROOT, "dist", "Photon-*.zip")), key=os.path.getmtime)
    return os.environ.get("BARESTATE_RELEASE_ZIP") or (zips[-1] if zips else None)


def press(pid, menu, item):
    """AXPress of a real menu item, addressed by pid; moves no cursor and posts no key event."""
    script = ('tell application "System Events" to tell (first process whose unix id is '
              f'{pid}) to click menu item "{item}" of menu 1 of menu bar item "{menu}" of menu bar 1')
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=30)


def window_names(pid):
    """Window titles from the window server, which also work while the session is locked
    (System Events lists no windows then)."""
    script = ('ObjC.import("CoreGraphics");'
              'JSON.stringify(ObjC.deepUnwrap(ObjC.castRefToObject('
              '$.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0)))'
              f'.filter(w => w.kCGWindowOwnerPID == {pid}).map(w => w.kCGWindowName))')
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", script],
                         capture_output=True, text=True, timeout=30).stdout
    return json.loads(out) if out.strip() else []


def wait_tab(mcp, prefix, title):
    """The title proves the page rendered, not an error page that also stops loading."""
    def loaded():
        for tab in data(mcp.tool("tabs"))["tabs"]:
            if tab["url"].startswith(prefix) and tab["title"] == title and not tab["loading"]:
                return tab
    return bs.wait_until(loaded, 30, what=f"{prefix} loaded")


@unittest.skipUnless(release_zip(), "no zip: set BARESTATE_RELEASE_ZIP or run make dist")
class ReleaseCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp(prefix="bs-rel-")
        subprocess.run(["ditto", "-x", "-k", release_zip(), cls.root], check=True)
        cls.app_path = os.path.join(cls.root, "Photon.app")
        cls.mcp_path = os.path.join(cls.app_path, "Contents", "MacOS", "barestate-mcp")
        cls.fixtures = bs.Fixtures(LOG_DIR).start()
        cls.reports_before = bs.crash_reports()

    @classmethod
    def tearDownClass(cls):
        cls.fixtures.stop()
        shutil.rmtree(cls.root, ignore_errors=True)

    def launch(self, label):
        app = bs.App(f"/tmp/bs-rel-{os.getpid()}-{label}", LOG_DIR, label=label, test_hooks=False,
                     bundle=self.app_path, env={"BARESTATE_LOG": "debug"}).start()
        self.addCleanup(app.stop)
        mcp = Stdio(app.data_dir, ["--stdio", "--socket", f"{app.data_dir}/app.sock"],
                    command=self.mcp_path)
        self.addCleanup(mcp.stop)
        return app, mcp

    def quit_through_menu(self, app):
        press(app.proc.pid, "Photon", "Quit Photon")
        self.assertEqual(app.proc.wait(timeout=30), 0, "Quit Photon did not exit 0")

    def browse(self, app, mcp):
        since = len(self.fixtures.log())
        for page, title in ((FIXTURE_PAGE, "Barestate fixture"), (PUBLIC_PAGE, "Example Domain")):
            data(mcp.tool("open_tab", url=page))
            wait_tab(mcp, page, title)
        self.assertTrue(any("GET /index.html 200" in line for line in self.fixtures.log(since)))
        self.assertIn("Photon", bs.wait_until(lambda: window_names(app.proc.pid), 10,
                                              what="the Photon window"))

    def open_launcher(self, app):
        log = os.path.join(app.data_dir, "logs", "photon.log")

        def count():
            with open(log, errors="replace") as photon:
                return photon.read().count("launcher open")
        seen = count()
        pressed = press(app.proc.pid, "File", "New Tab")
        self.assertEqual(pressed.returncode, 0, pressed.stderr)
        bs.wait_until(lambda: count() > seen, 10, what="⌘T opening the launcher")

    def test_zip_name_matches_the_bundle_version(self):
        with open(os.path.join(self.app_path, "Contents", "Info.plist"), "rb") as info:
            version = plistlib.load(info)["CFBundleShortVersionString"]
        self.assertEqual(os.path.basename(release_zip()), f"Photon-{version}.zip")

    def test_signed_with_every_helper_and_the_mcp_server(self):
        verified = subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", "--verbose=2", self.app_path],
            capture_output=True, text=True)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        helpers = sorted(glob.glob(os.path.join(self.app_path, "Contents", "Frameworks",
                                                "Barestate Helper*.app")))
        self.assertEqual(len(helpers), 5, helpers)
        for path in [*helpers, self.mcp_path]:
            signed = subprocess.run(["codesign", "--verify", "--strict", path],
                                    capture_output=True, text=True)
            self.assertEqual(signed.returncode, 0, f"{path}: {signed.stderr}")

    def test_the_docs_snippet_points_at_the_bundled_server(self):
        with open(DOCS) as docs:
            self.assertIn("Photon.app/Contents/MacOS/barestate-mcp", docs.read())

    def test_hooks_off_launch_loads_a_page_sandboxes_helpers_and_answers_the_mcp_snippet(self):
        app, mcp = self.launch("ship")
        status = app.status()
        self.assertTrue(status["ready"])
        with self.assertRaises(bs.RpcError) as caught:
            app.call("test.ui")
        self.assertEqual(caught.exception.code, -32601)
        initialized = mcp.request("initialize", {"protocolVersion": "2025-06-18"})["result"]
        self.assertEqual(initialized["serverInfo"]["name"], "barestate-mcp")
        listed = mcp.request("tools/list")["result"]["tools"]
        self.assertEqual([tool["name"] for tool in listed], TOOLS)
        self.browse(app, mcp)
        seen = {}
        for pid in app.tree_pids():
            seen.setdefault(process_type(command_of(pid)), []).append(LIBC.sandbox_check(pid, None, 0))
        self.assertEqual(seen.pop("browser"), [0])
        self.assertIn("renderer", seen)
        self.assertIn("gpu-process", seen)
        for kind, results in seen.items():
            self.assertEqual(set(results), {1}, f"{kind} process is not sandboxed")
        self.quit_through_menu(app)

    def test_five_launches_open_pages_and_the_launcher_and_quit_through_the_menu(self):
        for launch in range(1, LAUNCHES + 1):
            with self.subTest(launch=launch):
                app, mcp = self.launch(f"stable{launch}")
                self.assertTrue(app.status()["ready"])
                self.browse(app, mcp)
                # No menu item dismisses the launcher and key or pointer events are off limits,
                # so it stays open through the quit; Esc and outside click have hooks-on tests.
                self.open_launcher(app)
                self.quit_through_menu(app)
        self.assertEqual(bs.crash_reports() - self.reports_before, set())


if __name__ == "__main__":
    unittest.main()
