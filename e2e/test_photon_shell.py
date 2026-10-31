"""Photon identity and the borderless shell: names, window, command button, security caption,
shortcuts through the matcher, bookmarks and native editing."""
import json
import os
import sqlite3
import subprocess
import unittest
import urllib.request

import bs
from appcase import LOG_DIR, AppCase, save, url

BARESTATE_BUNDLE = "Barestate" + ".app"


def flatten(nodes):
    for node in nodes:
        yield node
        yield from flatten(node.get("children", []))


def menu_items(menu):
    for entry in menu:
        yield entry
        yield from menu_items(entry.get("items", []))


class IdentityTests(unittest.TestCase):
    """VAL-SHELL-001 (static half): the bundle, its plist and the names that must not change."""

    def plist(self, key):
        return subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c", f"Print {key}",
             os.path.join(bs.APP_BUNDLE, "Contents", "Info.plist")],
            check=True, capture_output=True, text=True).stdout.strip()

    def test_the_bundle_is_photon_and_the_old_bundle_is_gone(self):
        self.assertTrue(os.path.isdir(bs.APP_BUNDLE))
        self.assertEqual(os.path.basename(bs.APP_BUNDLE), "Photon.app")
        self.assertFalse(os.path.exists(os.path.join(bs.ROOT, ".build", BARESTATE_BUNDLE)))
        self.assertEqual(self.plist("CFBundleName"), "Photon")
        self.assertEqual(self.plist("CFBundleDisplayName"), "Photon")
        self.assertEqual(self.plist("CFBundleExecutable"), bs.APP_EXECUTABLE)
        self.assertEqual(self.plist("CFBundleShortVersionString"), "0.1.0")
        self.assertEqual(self.plist("CFBundleIdentifier"), "dev.barestate.browser")

    def test_cef_helpers_still_derive_from_the_executable(self):
        frameworks = os.path.join(bs.APP_BUNDLE, "Contents", "Frameworks")
        helpers = sorted(name for name in os.listdir(frameworks) if "Helper" in name)
        self.assertEqual(len(helpers), 5)
        self.assertTrue(all(name.startswith(bs.APP_EXECUTABLE + " Helper") for name in helpers))

    def test_no_kyoto_art_ships_and_no_script_names_the_old_bundle(self):
        self.assertFalse(os.path.exists(
            os.path.join(bs.APP_BUNDLE, "Contents", "Resources", "Art", "kyoto-background.png")))
        found = subprocess.run(
            ["grep", "-rIl", BARESTATE_BUNDLE, "Makefile", "scripts", "e2e"],
            cwd=bs.ROOT, capture_output=True, text=True).stdout.split()
        self.assertEqual(found, [])

    def test_technical_names_are_unchanged(self):
        with open(os.path.join(bs.ROOT, "Package.swift")) as source:
            package = source.read()
        for name in ("Barestate", "barestate-mcp", "barestate-gateway"):
            self.assertIn(f'"{name}"', package)


class ShellCase(AppCase):
    start_url = url("article.html")

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        bs.wait_until(lambda: [t for t in cls.app.call("tabs")["tabs"] if not t["loading"]],
                      what="the start page")

    def setUp(self):
        self.call("test.windowSize", {"w": 1440, "h": 900})
        self.tab = self.reset_to_one_blank_tab()
        self.navigate(self.tab, url("article.html"))

    def menu(self):
        return self.call("test.menu")

    def caption(self):
        return self.ui()["caption"]

    def wait_caption(self, **expected):
        def match():
            caption = self.caption()
            if all(caption.get(key) == value for key, value in expected.items()):
                return caption
        return bs.wait_until(match, timeout=5, what=f"caption {expected}")


class WindowAndMenuTests(ShellCase):
    def test_menus_the_about_panel_and_the_window_say_photon(self):
        """VAL-SHELL-001"""
        menu = self.menu()
        save("menu.json", menu)
        self.assertEqual([entry["title"] for entry in menu],
                         ["Photon", "File", "Edit", "View", "Muse", "History", "Tab"])
        titles = [entry["title"] for entry in menu_items(menu) if "title" in entry]
        for expected in ("About Photon", "Settings…", "Hide Photon", "Quit Photon"):
            self.assertIn(expected, titles)
        self.assertNotIn("Barestate", json.dumps(menu))
        self.assertEqual(self.ui()["window"]["title"], "Photon")

        self.call("test.menu", {"invoke": "About Photon"})
        about = bs.wait_until(lambda: self.ui()["about"]["open"] and self.ui()["about"],
                              what="the About panel")
        self.call("test.screenshot", {"path": os.path.join(LOG_DIR, "about-photon.png"),
                                      "window": "about"})
        tabs = self.tab_ids()
        self.key("w", "cmd")
        bs.wait_until(lambda: not self.ui()["about"]["open"], what="⌘W to close the About panel")
        self.assertEqual(self.tab_ids(), tabs)
        save("about.json", about)
        texts = " | ".join(about["texts"])
        self.assertIn("Photon", about["texts"], texts)
        self.assertIn("by Barestate", texts)
        self.assertIn("0.1.0", texts)
        self.assertGreaterEqual(about["images"], 1)
        self.assertNotIn("Barestate", " | ".join(t for t in about["texts"] if t != "by Barestate"
                                                   and "by Barestate" not in t))

    def test_the_window_is_borderless_with_full_size_content(self):
        """VAL-SHELL-002"""
        window = self.ui()["window"]
        self.assertTrue(window["titlebarTransparent"])
        self.assertTrue(window["fullSizeContent"])
        self.assertTrue(window["titleHidden"])
        self.assertFalse(window["toolbar"])
        self.assertEqual(window["titlebarAccessories"], 0)
        for name in ("close", "miniaturize", "zoom"):
            self.assertGreater(window["trafficLights"][name]["w"], 0, name)
        for size in ((1440, 900), (720, 600)):
            self.call("test.windowSize", {"w": size[0], "h": size[1]})
            ui = self.ui()
            self.assertEqual(ui["contentFrame"],
                             {"x": 0, "y": 0, "w": size[0], "h": size[1]})
            self.assertEqual(ui["windowFrame"]["w"], size[0])

    def test_no_old_chrome_remains_in_the_tree_the_menus_or_the_hooks(self):
        """VAL-SHELL-002"""
        labels = {node.get("label") for node in flatten(self.call("test.ax"))}
        for gone in ("Go back", "Go forward", "Reload page", "New tab", "Browser menu",
                     "Show sidebar", "Personal", "Current address"):
            self.assertNotIn(gone, labels)
        ui = self.ui()
        self.assertNotIn("sidebar", ui)
        for key in ("tabStrip", "toolbar", "emptyArea", "layout"):
            self.assertNotIn(key, ui["chrome"])
        titles = [entry["title"] for entry in menu_items(self.menu()) if "title" in entry]
        for gone in ("Show Sidebar", "Hide Sidebar", "Horizontal Tabs", "Vertical Tabs"):
            self.assertNotIn(gone, titles)
        with self.assertRaises(bs.RpcError) as raised:
            self.call("test.pointerEdge", {"inside": True})
        self.assertEqual(raised.exception.code, -32601)

    def test_ctrl_cmd_s_does_nothing(self):
        """VAL-SHELL-002, VAL-TABS-008"""
        before = (self.ui()["contentFrame"], self.tab_ids(), self.active_id(),
                  self.launcher_open())
        self.key("s", "ctrl", "cmd")
        self.assertEqual((self.ui()["contentFrame"], self.tab_ids(), self.active_id(),
                          self.launcher_open()), before)


class CommandButtonTests(ShellCase):
    def button(self):
        return self.ui()["commandButton"]

    def test_one_button_bottom_centre_with_its_name_and_hint(self):
        """VAL-SHELL-003"""
        for size in ((1440, 900), (720, 600)):
            self.call("test.windowSize", {"w": size[0], "h": size[1]})
            button = self.button()
            frame = button["frame"]
            self.assertEqual((frame["w"], frame["h"]), (288, 48))
            self.assertAlmostEqual(frame["x"] + frame["w"] / 2, size[0] / 2, delta=2)
            self.assertAlmostEqual(frame["y"] + frame["h"], size[1] - 16, delta=2)
            self.assertEqual(button["label"], "Search or do anything")
            self.assertEqual(button["hint"], "⌘T")
            self.assertTrue(button["visible"])
        matches = [node for node in flatten(self.call("test.ax"))
                   if node.get("label") == "Search or do anything"]
        self.assertEqual(len(matches), 1, matches)

    def test_click_and_cmd_t_open_the_same_launcher_and_make_no_tab(self):
        """VAL-SHELL-003"""
        tabs = self.tab_ids()
        states = []
        for act in (lambda: self.call("test.click", {"target": "commandButton"}),
                    lambda: self.key("t", "cmd")):
            act()
            self.wait_launcher(True)
            ui = self.ui()
            launcher = ui["launcher"]
            states.append({k: launcher[k] for k in ("query", "frame", "placeholder", "hints")}
                          | {"rows": [(r["kind"], r["title"]) for r in launcher["rows"]],
                             "responder": ui["firstResponder"]["chromeId"]})
            self.assertFalse(ui["commandButton"]["visible"])
            self.assertTrue(ui["commandButton"]["compactChip"])
            self.assertEqual(self.tab_ids(), tabs)
            self.key("Escape")
            self.wait_launcher(False)
            self.assertTrue(self.button()["visible"])
            self.assertFalse(self.button()["compactChip"])
        save("command-button-launchers.json", states)
        self.assertEqual(states[0], states[1])

    def test_the_keyboard_reaches_the_button_and_space_or_return_open_the_launcher(self):
        """VAL-SHELL-003"""
        for key in ("Space", "Return"):
            self.call("test.click", {"target": "root", "x": 8, "y": 300})
            self.assertEqual(self.ui()["firstResponder"]["chromeId"], "root")
            self.key("Tab")
            bs.wait_until(lambda: self.button()["focused"], what="the button to take focus")
            self.key(key)
            self.wait_launcher(True)
            self.key("Escape")
            self.wait_launcher(False)
        self.assertEqual(self.tab_ids(), [self.tab])


class SecurityTests(ShellCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.tls = bs.SelfSignedFixtures().start()

    @classmethod
    def tearDownClass(cls):
        cls.tls.stop()
        super().tearDownClass()

    def footer(self):
        self.key("t", "cmd")
        self.wait_launcher(True)
        footer = self.ui()["launcher"]["footer"]
        self.call("test.screenshot", {"path": os.path.join(LOG_DIR, "footer.png")})
        self.key("Escape")
        self.wait_launcher(False)
        return footer

    def check(self, label, caption, security, host):
        found = self.wait_caption(security=security, host=host)
        self.assertTrue(found["visible"] and found["title"], found)
        self.assertEqual(found["text"], f"{host} · {security}")
        self.assertTrue(found["fits"], found)
        footer = self.footer()
        self.assertEqual((footer["origin"], footer["security"]), (host, security), label)
        save(f"security-{label}.json", {"caption": found, "footer": footer})
        return found

    def test_http_is_not_secure_and_a_file_is_a_local_file(self):
        """VAL-SHELL-004"""
        self.check("http", None, "Not secure", "127.0.0.1:47810")
        fixture = os.path.join(bs.ROOT, "fixtures", "article.html")
        self.navigate(self.tab, "file://" + fixture)
        found = self.check("file", None, "Local file", "article.html")
        self.assertEqual(found["title"], "Article fixture")

    def test_a_self_signed_certificate_is_a_certificate_error_and_never_secure(self):
        """VAL-SHELL-004"""
        host = f"127.0.0.1:{self.tls.port}"
        self.call("test.devtools", {"tabId": self.tab, "method": "Page.navigate",
                                    "params": {"url": self.tls.url + "/article.html"}})
        found = self.check("certificate-error", None, "Certificate error", host)
        self.assertNotIn("Secure", found["text"].replace("Not secure", ""))
        # Reloading the refused page is refused again, so the failure stays.
        self.key("r", "cmd")
        bs.wait_until(lambda: not self.tabs()[0]["loading"], what="the reload to settle")
        self.wait_caption(security="Certificate error", host=host)
        # Leaving the refused page clears the failure.
        self.navigate(self.tab, url("input.html"))
        self.wait_caption(security="Not secure", host="127.0.0.1:47810")

    def test_a_valid_https_site_is_secure(self):
        """VAL-SHELL-004 (needs the network)"""
        try:
            urllib.request.urlopen("https://example.com", timeout=5).close()
        except OSError:
            self.skipTest("no network")
        self.call("test.devtools", {"tabId": self.tab, "method": "Page.navigate",
                                    "params": {"url": "https://example.com/"}})
        self.check("https", None, "Secure", "example.com")

    def test_the_caption_follows_navigation_and_never_truncates_the_host(self):
        """VAL-SHELL-004"""
        self.wait_caption(host="127.0.0.1:47810")
        fixture = os.path.join(bs.ROOT, "fixtures", "input.html")
        for width in (1440, 720):
            self.call("test.windowSize", {"w": width, "h": 900 if width > 1000 else 600})
            self.navigate(self.tab, url("input.html"))
            found = self.wait_caption(title="Input fixture")
            self.assertTrue(found["fits"], (width, found))
            self.assertGreater(found["frame"]["w"], 600)
            self.navigate(self.tab, "file://" + fixture)
            self.wait_caption(security="Local file", host="input.html")
        self.call("test.windowSize", {"w": 1440, "h": 900})

    def test_a_blank_page_has_no_caption_and_no_footer_origin(self):
        """VAL-SHELL-004"""
        blank = self.call("open_tab", {"url": "about:blank"})["id"]
        self.assertEqual(self.active_id(), blank)
        bs.wait_until(lambda: not self.caption()["visible"], what="the caption to hide")
        self.assertEqual(self.footer(), {**self.footer(), "origin": "", "security": ""})
        self.call("test.closeTab", {"tabId": blank})


class ShortcutTests(ShellCase):
    """VAL-TABS-008 and VAL-SHELL-007 against the real menu."""

    def test_every_shortcut_has_a_menu_item_with_the_same_key_equivalent(self):
        """VAL-TABS-008"""
        wanted = {"t": ["cmd"], "l": ["cmd"], "w": ["cmd"], "T": ["cmd", "shift"], "d": ["cmd"],
                  "r": ["cmd"], "[": ["cmd"], "]": ["cmd"], "f": ["cmd"], ",": ["cmd"],
                  "\t": ["ctrl"], "\u0019": ["ctrl", "shift"], "1": ["cmd"], "8": ["cmd"],
                  "9": ["cmd"], "q": ["cmd"], "h": ["cmd"]}
        have = {(item["key"], tuple(sorted(item["modifiers"]))) for item in menu_items(self.menu())
                if item.get("key")}
        for key, modifiers in wanted.items():
            self.assertIn((key, tuple(sorted(modifiers))), have, (key, modifiers))
        self.assertFalse([item for item in menu_items(self.menu())
                          if item.get("key") == "s" and "ctrl" in item["modifiers"]])

    def test_near_miss_modifiers_trigger_nothing(self):
        """VAL-TABS-008"""
        before = (self.tab_ids(), self.active_id(), self.launcher_open(),
                  self.chrome()["find"]["open"], self.ui()["settings"].get("open"))
        for key, modifiers in (("l", ["cmd", "shift"]), ("t", ["cmd", "alt"]),
                               ("w", ["ctrl", "cmd"]), ("d", ["cmd", "shift"]),
                               ("f", ["cmd", "alt"]), (",", ["cmd", "shift"])):
            self.call("test.key", {"key": key, "modifiers": modifiers})
            self.assertEqual(self.tab_ids(), before[0], (key, modifiers))
        self.assertEqual((self.tab_ids(), self.active_id(), self.launcher_open(),
                          self.chrome()["find"]["open"], self.ui()["settings"].get("open")), before)

    def test_cmd_comma_opens_one_settings_window_even_with_a_page_input_focused(self):
        """VAL-TABS-008"""
        keys = self.open_page("keys.html")["id"]
        self.call("test.click", {"target": keys, "x": 100, "y": 35})
        bs.wait_until(lambda: self.ui()["firstResponder"]["tabId"] == keys, what="page focus")
        start = len(self.fixtures.log())
        self.key(",", "cmd")
        bs.wait_until(lambda: self.ui()["settings"]["open"] and self.ui()["settings"]["key"],
                      what="Settings")
        self.assertEqual(self.ui()["settings"]["windows"], 1)
        self.assertEqual([b for b in self.beacons(start) if b.get("ev")], [])
        closes = self.ui()["settings"]["closes"]
        self.key("w", "cmd")
        bs.wait_until(lambda: self.ui()["settings"]["closes"] == closes + 1, what="Settings closed")
        self.call("test.closeTab", {"tabId": keys})


class EditingTests(ShellCase):
    """VAL-SHELL-007: editing keys stay native in the launcher field and reach the page."""

    def setUp(self):
        super().setUp()
        self.saved_clipboard = subprocess.run(["pbpaste"], capture_output=True).stdout
        subprocess.run(["pbcopy"], input=b"")

    def tearDown(self):
        subprocess.run(["pbcopy"], input=self.saved_clipboard)

    def field(self):
        return self.ui()["launcher"]["fieldText"]

    def test_the_launcher_field_edits_natively(self):
        self.key("t", "cmd")
        self.wait_launcher(True)
        self.call("test.type", {"text": "alpha"})
        bs.wait_until(lambda: self.field() == "alpha", what="typed text")
        self.key("a", "cmd")
        self.key("x", "cmd")
        bs.wait_until(lambda: self.field() == "", what="cut")
        self.key("v", "cmd")
        bs.wait_until(lambda: self.field() == "alpha", what="paste restores alpha")
        self.key("z", "cmd")
        bs.wait_until(lambda: self.field() != "alpha", what="undo")
        self.key("z", "cmd", "shift")
        bs.wait_until(lambda: self.field() == "alpha", what="redo")
        edit = next(entry for entry in self.menu() if entry["title"] == "Edit")
        enabled = {item["title"]: item["enabled"] for item in edit["items"] if "title" in item}
        for name in ("Undo", "Redo", "Cut", "Copy", "Paste", "Select All"):
            self.assertTrue(enabled[name], name)
        self.key("Escape")
        self.wait_launcher(False)

    def test_the_page_input_edits_and_hears_the_keys(self):
        start = len(self.fixtures.log())
        keys = self.open_page("keys.html")["id"]
        bs.wait_until(lambda: any(b.get("ready") == ["1"] for b in self.beacons(start)),
                      what="the page to be ready")
        self.call("test.click", {"target": keys, "x": 100, "y": 35})
        bs.wait_until(lambda: self.ui()["firstResponder"]["tabId"] == keys, what="page focus")

        def box(value):
            bs.wait_until(lambda: self.evaluate("document.getElementById('box').value", keys)
                          == value, what=f"the input to hold {value!r}")

        self.call("test.type", {"text": "alpha"})
        box("alpha")
        self.key("a", "cmd")
        self.key("x", "cmd")
        box("")
        self.key("v", "cmd")
        box("alpha")
        self.key("z", "cmd")
        bs.wait_until(lambda: self.evaluate("document.getElementById('box').value", keys)
                      != "alpha", what="undo")
        self.key("z", "cmd", "shift")
        box("alpha")
        self.call("test.closeTab", {"tabId": keys})

    def test_edit_items_are_disabled_without_a_text_responder_or_page(self):
        self.call("test.click", {"target": "root", "x": 8, "y": 300})
        edit = next(entry for entry in self.menu() if entry["title"] == "Edit")
        enabled = {item["title"]: item["enabled"] for item in edit["items"] if "title" in item}
        for name in ("Undo", "Cut", "Copy", "Paste", "Select All"):
            self.assertFalse(enabled[name], name)

    def test_the_app_menu_has_the_standard_items(self):
        photon = next(entry for entry in self.menu() if entry["title"] == "Photon")
        items = {item["title"]: item for item in photon["items"] if "title" in item}
        self.assertEqual(items["Hide Photon"]["shortcut"], "⌘H")
        self.assertEqual(items["Quit Photon"]["shortcut"], "⌘Q")
        self.assertEqual(items["Settings…"]["shortcut"], "⌘,")
        self.assertIn("About Photon", items)


class BookmarkTests(ShellCase):
    """VAL-TABS-019: ⌘D adds the page once; the launcher finds it; it survives a relaunch."""

    def rows(self, sql):
        connection = sqlite3.connect(f"file:{self.data_dir}/barestate.sqlite?mode=ro", uri=True)
        try:
            return connection.execute(sql).fetchall()
        finally:
            connection.close()

    def bookmark_item(self):
        return next(item for item in menu_items(self.menu()) if item.get("title") == "Bookmark This Page")

    def test_without_a_page_the_command_is_disabled_with_a_reason_and_adds_nothing(self):
        blank = self.call("open_tab", {"url": "about:blank"})["id"]
        item = self.bookmark_item()
        self.assertFalse(item["enabled"])
        self.assertTrue(item["toolTip"])
        before = self.rows("SELECT count(*) FROM bookmarks")
        self.key("d", "cmd")
        self.assertEqual(self.rows("SELECT count(*) FROM bookmarks"), before)
        self.call("test.closeTab", {"tabId": blank})

    def test_cmd_d_adds_once_the_launcher_returns_it_and_a_relaunch_keeps_it(self):
        self.navigate(self.tab, url("launcher.html?t=Bookmark%20Probe"))
        bs.wait_until(lambda: self.tabs()[0]["title"] == "Bookmark Probe", what="the title")
        self.assertTrue(self.bookmark_item()["enabled"])
        self.key("d", "cmd")
        marks = bs.wait_until(lambda: self.rows("SELECT url, title FROM bookmarks"), what="bookmark")
        self.assertEqual(marks, [(url("launcher.html?t=Bookmark%20Probe"), "Bookmark Probe")])
        self.key("d", "cmd")
        self.navigate(self.tab, url("input.html"))
        bs.wait_until(lambda: self.rows("SELECT 1 FROM history WHERE url LIKE '%input.html'"),
                      what="a later visit, which the store handles after the second press")
        self.assertEqual(self.rows("SELECT count(*) FROM bookmarks")[0][0], 1)

        self.key("t", "cmd")
        self.wait_launcher(True)
        self.call("test.type", {"text": "Bookmark Probe"})
        row = bs.wait_until(lambda: next((r for r in self.ui()["launcher"]["rows"]
                                          if r["kind"] == "bookmark"), None), what="a bookmark row")
        self.assertEqual(row["title"], "Bookmark Probe")
        self.key("Escape")
        self.wait_launcher(False)

        self.app.stop(remove_data=False)
        type(self).app = bs.App(self.data_dir, LOG_DIR, label="BookmarkTests-again").start(fresh=False)
        self.assertEqual(self.rows("SELECT count(*) FROM bookmarks")[0][0], 1)
        self.key("t", "cmd")
        self.wait_launcher(True)
        self.call("test.type", {"text": "Bookmark Probe"})
        bs.wait_until(lambda: any(r["kind"] == "bookmark" for r in self.ui()["launcher"]["rows"]),
                      what="the bookmark row after relaunch")


if __name__ == "__main__":
    unittest.main()
