"""Window shortcuts, find in page, fonts, browsing data and quit on the borderless Photon shell."""
import json
import os
import sqlite3
import time
import unittest

import bs
from appcase import LOG_DIR, AppCase, save, url


PAGES = ["input.html", "article.html", "many.html", "observe.html", "act.html", "edge.html",
         "index.html", "fp.html", "isolated.html"]


class TabShortcutTests(AppCase):
    def test_tab_shortcuts_with_ten_tabs(self):
        first = self.reset_to_one_blank_tab()
        ids = [first] + [self.open_page(page)["id"] for page in PAGES]
        self.assertEqual(self.tab_ids(), ids)
        self.assertEqual(self.active_id(), ids[9])
        log = []

        def step(label, expected_active):
            actual = (self.active_id(), self.tab_ids())
            log.append({"step": label, "active": actual[0], "tabs": actual[1]})
            self.assertEqual(actual[0], expected_active, label)

        self.key("Tab", "ctrl")
        step("ctrl-tab wraps last to first", ids[0])
        self.key("Tab", "ctrl", "shift")
        step("ctrl-shift-tab wraps first to last", ids[9])
        self.key("Tab", "ctrl", "shift")
        step("ctrl-shift-tab goes back one", ids[8])
        self.key("Tab", "ctrl")
        step("ctrl-tab goes forward one", ids[9])
        for number in range(1, 9):
            self.key(str(number), "cmd")
            step(f"cmd-{number}", ids[number - 1])
        self.key("9", "cmd")
        step("cmd-9 selects the last tab", ids[9])

        self.call("test.activateTab", {"tabId": ids[3]})
        self.key("w", "cmd")
        bs.wait_until(lambda: self.tab_ids() == ids[:3] + ids[4:], what="cmd-w to close only the active tab")
        step("cmd-w selects the right neighbour", ids[4])
        self.key("w", "cmd")
        bs.wait_until(lambda: self.tab_ids() == ids[:3] + ids[5:], what="a second cmd-w")

        closed_pages = [url(PAGES[2]), url(PAGES[3])]
        for expected in reversed(closed_pages):
            count = len(self.tab_ids())
            self.key("t", "cmd", "shift")
            bs.wait_until(lambda: len(self.tab_ids()) == count + 1, what="cmd-shift-t to reopen once")
            time.sleep(0.2)
            self.assertEqual(len(self.tab_ids()), count + 1)
            self.assertEqual(self.tab_ids().index(self.active_id()), 3)
            bs.wait_until(lambda: self.tabs()[3]["url"] == expected, what=f"{expected} to come back")
        save("tab-shortcuts.json", log)
        for tab_id in self.tab_ids()[1:]:
            self.call("test.closeTab", {"tabId": tab_id})

    def test_closing_the_last_tab_leaves_a_blank_tab(self):
        only = self.reset_to_one_blank_tab()
        self.navigate(only, url("input.html"))
        self.key("w", "cmd")
        blank = bs.wait_until(lambda: [t for t in self.tabs() if t["id"] != only], what="a new tab")
        self.assertEqual(len(blank), 1)
        self.assertIn(blank[0]["url"], ("", "about:blank"))
        self.assertEqual(self.active_id(), blank[0]["id"])


class NavigationShortcutTests(AppCase):
    def test_history_and_reload_shortcuts_step_once(self):
        tab = self.reset_to_one_blank_tab()
        self.navigate(tab, url("keys.html"))
        self.navigate(tab, url("article.html"))
        self.key("[", "cmd")
        self.wait_loaded(url("keys.html"), tab)
        self.key("]", "cmd")
        self.wait_loaded(url("article.html"), tab)
        self.key("[", "cmd")
        self.wait_loaded(url("keys.html"), tab)
        entries = self.call("test.devtools", {"tabId": tab, "method": "Page.getNavigationHistory"})
        self.assertEqual(entries["currentIndex"], entries["entries"].__len__() - 2)

        nonce = self.evaluate("window.nonce", tab)
        start = len(self.fixtures.log())
        self.key("r", "cmd")
        bs.wait_until(lambda: self.evaluate("window.nonce", tab) not in (None, nonce),
                      what="a new page nonce after reload")
        requests = [line for line in self.fixtures.log(start) if "GET /keys.html" in line]
        save("reload-requests.json", requests)
        self.assertEqual(len(requests), 1)


class FindTests(AppCase):
    def test_find_in_page_highlights_and_escape_closes(self):
        tab = self.reset_to_one_blank_tab()
        self.navigate(tab, url("article.html"))
        self.call("test.activateTab", {"tabId": tab})
        self.key("f", "cmd")
        find = bs.wait_until(lambda: (f := self.chrome()["find"])["open"] and f, what="find bar")
        self.assertTrue(find["focused"])
        word = self.evaluate("document.body.innerText.trim().split(/\\s+/)[2]", tab)
        self.call("test.type", {"text": word})
        found = bs.wait_until(lambda: (f := self.chrome()["find"])["matches"] > 0 and f,
                              what="a find match")
        self.assertEqual(found["text"], word)
        shot = os.path.join(LOG_DIR, "find-bar.png")
        self.call("test.screenshot", {"path": shot})
        self.assertTrue(os.path.getsize(shot) > 10000)
        self.key("Escape")
        bs.wait_until(lambda: not self.chrome()["find"]["open"], what="the find bar to close")
        self.assertEqual(self.ui()["firstResponder"]["tabId"], tab)


class ShortcutsReachOnlyTheAppTests(AppCase):
    """With a web <input> focused and listeners installed, each shortcut acts once and the page
    sees no key."""

    def focus_input(self, tab):
        self.call("test.activateTab", {"tabId": tab})
        self.call("test.click", {"target": tab, "x": 100, "y": 35})
        bs.wait_until(lambda: self.ui()["firstResponder"]["tabId"] == tab, what="the page to focus")

    def test_each_shortcut_has_its_effect_once_and_the_page_hears_nothing(self):
        first = self.reset_to_one_blank_tab()
        keys = self.open_page("keys.html")["id"]
        others = [self.open_page(page)["id"] for page in PAGES[:8]]
        ids = [first, keys] + others
        self.assertEqual(self.tab_ids(), ids)
        table = []

        def press(label, key, modifiers, took_effect):
            if keys in self.tab_ids():
                self.focus_input(keys)
            start = len(self.fixtures.log())
            before = {"tabs": self.tab_ids(), "active": self.active_id(),
                      "requests": self.keys_requests()}
            self.key(key, *modifiers)
            bs.wait_until(lambda: took_effect(before), what=f"{label} to take effect")
            time.sleep(0.3)
            heard = [b for b in self.beacons(start) if b.get("ev")]
            table.append({"shortcut": label, "tabsAfter": len(self.tab_ids()), "pageEvents": len(heard)})
            self.assertEqual(heard, [], f"the page saw {label}")
            self.assertTrue(took_effect(before), f"{label} fired more than once")

        def moved_by(step):
            return lambda b: self.tab_ids().index(self.active_id()) == \
                (b["tabs"].index(b["active"]) + step) % len(self.tab_ids())

        press("cmd-t", "t", ["cmd"], lambda b: self.ui()["launcher"]["open"])
        self.assertEqual(len(self.tab_ids()), len(ids))
        self.key("Escape")
        bs.wait_until(lambda: not self.ui()["launcher"]["open"], what="the launcher to close")
        press("cmd-l", "l", ["cmd"], lambda b: self.ui()["launcher"]["open"])
        self.key("Escape")
        bs.wait_until(lambda: not self.ui()["launcher"]["open"], what="the launcher to close")
        press("ctrl-tab", "Tab", ["ctrl"], moved_by(1))
        press("ctrl-shift-tab", "Tab", ["ctrl", "shift"], moved_by(-1))
        press("cmd-1", "1", ["cmd"], lambda b: self.active_id() == first)
        press("cmd-8", "8", ["cmd"], lambda b: self.active_id() == ids[7])
        press("cmd-9", "9", ["cmd"], lambda b: self.active_id() == ids[9])
        press("cmd-r", "r", ["cmd"], lambda b: self.keys_requests() == b["requests"] + 1)
        press("cmd-f", "f", ["cmd"], lambda b: self.chrome()["find"]["open"])
        self.key("Escape")
        press("cmd-w", "w", ["cmd"], lambda b: self.tab_ids() == [i for i in b["tabs"] if i != keys])
        press("cmd-shift-t", "t", ["cmd", "shift"], lambda b: len(self.tab_ids()) == len(b["tabs"]) + 1)
        save("shortcut-table.json", table)
        for tab_id in self.tab_ids()[1:]:
            self.call("test.closeTab", {"tabId": tab_id})

    def keys_requests(self):
        return len([line for line in self.fixtures.log() if "GET /keys.html" in line])

    def test_history_shortcuts_act_once_with_a_focused_input(self):
        tab = self.reset_to_one_blank_tab()
        self.navigate(tab, url("article.html"))
        self.navigate(tab, url("keys.html"))
        self.focus_input(tab)
        start = len(self.fixtures.log())
        self.key("[", "cmd")
        self.wait_loaded(url("article.html"), tab)
        self.key("]", "cmd")
        self.wait_loaded(url("keys.html"), tab)
        heard = [b for b in self.beacons(start) if b.get("ev")]
        self.assertEqual(heard, [])
        entries = self.call("test.devtools", {"tabId": tab, "method": "Page.getNavigationHistory"})
        self.assertEqual(entries["currentIndex"], len(entries["entries"]) - 1)

    def test_holding_a_key_fires_a_command_once_but_keeps_switching_tabs(self):
        first = self.reset_to_one_blank_tab()
        for _ in range(3):
            self.call("open_tab", {"url": "about:blank"})
        ids = self.tab_ids()
        self.key_with("t", ["cmd"], repeats=4)
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the launcher")
        time.sleep(0.3)
        self.assertEqual(self.tab_ids(), ids)
        self.key("Escape")
        bs.wait_until(lambda: not self.ui()["launcher"]["open"], what="the launcher to close")
        self.call("test.activateTab", {"tabId": ids[0]})
        self.key_with("Tab", ["ctrl"], repeats=2)
        bs.wait_until(lambda: self.active_id() == ids[3], what="three steps for a held Ctrl-Tab")
        for tab_id in self.tab_ids():
            if tab_id != first:
                self.call("test.closeTab", {"tabId": tab_id})

    def test_releasing_the_modifier_first_does_not_leak_the_key_up(self):
        tab = self.reset_to_one_blank_tab()
        keys = self.open_page("keys.html")["id"]
        self.focus_input(keys)
        start = len(self.fixtures.log())
        self.key_with("t", ["cmd"], release_modifiers_first=True)
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="Cmd-T to open the launcher")
        time.sleep(0.3)
        self.assertEqual([b for b in self.beacons(start) if b.get("ev")], [])
        self.key("Escape")
        for tab_id in self.tab_ids():
            if tab_id != tab:
                self.call("test.closeTab", {"tabId": tab_id})

    def key_with(self, key, modifiers, repeats=0, release_modifiers_first=False):
        self.call("test.key", {"key": key, "modifiers": modifiers, "repeats": repeats,
                               "releaseModifiersFirst": release_modifiers_first})

    def test_editing_shortcuts_still_reach_the_web_input(self):
        tab = self.reset_to_one_blank_tab()
        start = len(self.fixtures.log())
        self.navigate(tab, url("keys.html"))
        bs.wait_until(lambda: any(b.get("ready") == ["1"] for b in self.beacons(start)),
                      what="the page to be ready for input")
        self.focus_input(tab)

        def box_is(value):
            bs.wait_until(lambda: self.evaluate("document.getElementById('box').value", tab) == value,
                          what=f"the input to hold {value!r}")

        self.call("test.type", {"text": "abc"})
        box_is("abc")
        self.key("a", "cmd")
        self.key("x", "cmd")
        box_is("")
        self.key("v", "cmd")
        box_is("abc")


class FontTests(AppCase):
    def test_manrope_is_registered_from_the_bundle(self):
        fonts = self.chrome()["fonts"]
        save("fonts.json", fonts)
        resources = os.path.join(bs.APP_BUNDLE, "Contents", "Resources", "Fonts")
        self.assertEqual(os.path.realpath(fonts["manrope"]["url"]),
                         os.path.realpath(os.path.join(resources, "Manrope-Variable.ttf")))
        self.assertTrue(fonts["manrope"]["registered"])
        self.assertTrue(fonts["manrope"]["inUse"].startswith("Manrope"), fonts)
        self.assertTrue(fonts["instrumentSerif"]["registered"])
        for name in ("Manrope-Variable.ttf", "Manrope-OFL.txt", "InstrumentSerif-Regular.ttf",
                     "InstrumentSerif-OFL.txt"):
            self.assertTrue(os.path.isfile(os.path.join(resources, name)), name)
        self.assertNotIn("Library/Fonts", fonts["manrope"]["url"])

    def test_controls_use_manrope_and_key_hints_use_the_system_font(self):
        text = self.chrome()["text"]
        save("text-fonts.json", text)
        for name in ("commandLabel", "findField", "launcherField"):
            self.assertTrue(text[name].startswith("Manrope"), (name, text))
        for name in ("commandKey", "launcherHint"):
            self.assertFalse(text[name].startswith("Manrope"), (name, text))
            self.assertFalse(text[name].startswith("InstrumentSerif"), (name, text))
        self.assertFalse(text["commandLabel"].startswith("InstrumentSerif"))


class BrowsingDataTests(AppCase):
    def rows(self, sql):
        connection = sqlite3.connect(f"file:{self.data_dir}/barestate.sqlite?mode=ro", uri=True)
        try:
            return connection.execute(sql).fetchall()
        finally:
            connection.close()

    def test_visits_are_recorded_in_history_and_cmd_d_bookmarks_once(self):
        tab = self.reset_to_one_blank_tab()
        self.navigate(tab, url("article.html"))
        history = bs.wait_until(
            lambda: self.rows("SELECT url, title, visits FROM history WHERE url LIKE '%article.html'"),
            what="a history row")
        save("history-row.json", history)
        self.assertEqual(history[0][0], url("article.html"))
        self.assertEqual(history[0][1], "Article fixture")
        self.assertGreaterEqual(history[0][2], 1)
        self.assertEqual(self.rows("SELECT count(*) FROM history WHERE url LIKE 'about:%'")[0][0], 0)
        self.key("d", "cmd")
        marks = bs.wait_until(lambda: self.rows("SELECT url, title FROM bookmarks"), what="bookmark")
        self.assertEqual(marks, [(url("article.html"), "Article fixture")])
        self.key("d", "cmd")
        # The store handles writes in order: once a later visit is recorded, a duplicate
        # bookmark from the second press would already be in the table.
        self.navigate(tab, url("input.html"))
        bs.wait_until(lambda: self.rows("SELECT 1 FROM history WHERE url LIKE '%input.html'"),
                      what="the later visit to be recorded")
        self.assertEqual(self.rows("SELECT count(*) FROM bookmarks")[0][0], 1)

    def test_settings_json_exists_with_the_default_search_engine(self):
        with open(os.path.join(self.data_dir, "settings.json")) as source:
            self.assertEqual(json.load(source)["searchEngine"], "https://duckduckgo.com/?q=%s")


class QuitTests(unittest.TestCase):
    def test_cmd_q_through_the_menu_quits_cleanly(self):
        data_dir = f"/tmp/bs-win-{os.getpid()}-quit"
        app = bs.App(data_dir, LOG_DIR, label="cmdq", url=url("article.html")).start()
        try:
            app.call("open_tab", {"url": url("keys.html")})
            try:
                app.call("test.key", {"key": "q", "modifiers": ["cmd"]})
            except (ValueError, OSError):
                pass  # the app quits before it can answer
            self.assertEqual(app.proc.wait(timeout=20), 0)
            leftovers = sorted(name for name in os.listdir(data_dir)
                               if name.startswith("barestate.sqlite-") or name in ("app.sock", "app.pid"))
            save("quit-leftovers.json", leftovers)
            self.assertEqual(leftovers, [])
        finally:
            app.stop()


if __name__ == "__main__":
    unittest.main()
