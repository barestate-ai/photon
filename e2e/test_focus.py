"""The focused page in context and the moves between presentations: the same live page, never
reloaded (VAL-SPATIAL-007, 011, VAL-LAUNCH-001, 002, 010, VAL-TABS-005, 007, VAL-CROSS-001, 003)."""
import json
import os
import re
import subprocess
import unittest

import bs
import png
from appcase import LOG_DIR, save
from test_graph import CLICKS, GraphCase, titled
from test_run import ENDED

RENDERER = re.compile(r"--type=renderer")
PROFILE = re.compile(r"--(?:user-data-dir|root-cache-path)=(\S+)")


class FocusCase(GraphCase):
    def presentation(self):
        return self.ui()["presentation"]

    def wait_presentation(self, wanted):
        bs.wait_until(lambda: self.presentation() == wanted, what=f"presentation {wanted}")

    def show_overview(self):
        if self.presentation() != "overview":
            self.key("\\", "cmd", "shift")
            self.wait_presentation("overview")

    def show_page(self):
        if self.presentation() == "full-window":
            self.key("Return", "cmd")
        elif self.presentation() != "focused":
            self.key("\\", "cmd", "shift")
        self.wait_presentation("focused")

    def pages(self, count):
        """Live pages with a node each; the blank tab the app starts with has none, so it goes."""
        blank = self.tab_ids()[0]
        tabs = [self.open_page(f"Page {i + 1}") for i in range(count)]
        self.call("test.closeTab", {"tabId": blank})
        bs.wait_until(lambda: self.tab_ids() == tabs, what="only the pages open")
        return tabs

    def row(self, tabs):
        """Lays the pages out in one line, so the arrow keys walk them in order."""
        for i, tab in enumerate(tabs):
            self.call("test.canvas", {"move": {"node": self.node_of(tab)["id"], "x": i * 300, "y": 0}})

    def seed_page(self, tab):
        """The state a reload or a new document would lose."""
        self.evaluate("document.getElementById('box').value = 'keep-me'; window.scrollTo(0, 400)", tab)
        bs.wait_until(lambda: self.evaluate("window.scrollY", tab) == 400, what="scrolled")

    def document(self, tab):
        identity = json.loads(self.evaluate(
            "JSON.stringify([window.__nonce, performance.timeOrigin, history.length, "
            "(document.getElementById('box') || {}).value, window.scrollY, location.href])", tab))
        frame = self.call("test.devtools", {"tabId": tab, "method": "Page.getFrameTree"})
        return {"nonce": identity[0], "origin": identity[1], "history": identity[2],
                "value": identity[3], "scrollY": identity[4], "url": identity[5],
                "loader": frame["frameTree"]["frame"]["loaderId"]}

    def renderers(self):
        count = 0
        profiles = set()
        for pid in self.app.tree_pids():
            command = subprocess.run(["ps", "-o", "command=", "-p", str(pid)],
                                     capture_output=True, text=True).stdout
            count += bool(RENDERER.search(command))
            profiles.update(PROFILE.findall(command))
        return count, profiles

    def requests(self):
        return len(self.fixtures.log())

    def focus_state(self):
        return self.ui()["focus"]

    def activate(self, tab, presentation):
        """Makes `tab` active and leaves the window in `presentation` (activating shows the page)."""
        self.call("test.activateTab", {"tabId": tab})
        (self.show_page if presentation == "focused" else self.show_overview)()
        bs.wait_until(lambda: self.active_id() == tab, what=f"{tab} active")

    def fill_launcher(self, text):
        """Replaces whatever an earlier visit left in the launcher field."""
        self.key("a", "cmd")
        self.key("Backspace")
        bs.wait_until(lambda: self.ui()["launcher"]["query"] == "", what="an empty query")
        self.call("test.type", {"text": text})
        bs.wait_until(lambda: self.ui()["launcher"]["query"] == text
                      and self.ui()["launcher"]["current"], what=f"rows for {text!r}")

    def tab_to(self, chrome_id):
        for _ in range(5):
            if self.ui()["firstResponder"].get("chromeId") == chrome_id:
                return
            self.key("Tab")
        self.wait_responder(chromeId=chrome_id)

    def popups(self, opener, count):
        """Pages the opener opened, each linked to it by an edge, with the opener active again."""
        blank = self.tab_ids()[0]
        for _ in range(count):
            known = len(self.tab_ids())
            self.click(opener, "blank")
            bs.wait_until(lambda: len(self.tab_ids()) > known and
                          all(not t["loading"] for t in self.tabs()), what="a popup")
            self.focus(opener)
        popups = [t for t in self.tab_ids() if t not in (opener, blank)]
        for tab in popups:
            self.wait_node(tab)
        return popups

    def nodes_tab(self, node_id):
        return next(n["tabId"] for n in self.nodes() if n["id"] == node_id)

    def close_launcher(self):
        if self.ui()["launcher"]["open"]:
            self.key("Escape")
            self.wait_launcher(False)

    def wait_responder(self, **match):
        return bs.wait_until(
            lambda: (lambda r: r if all(r.get(k) == v for k, v in match.items()) else None)(
                self.ui()["firstResponder"]), what=f"first responder {match}")

    def assert_card_is_page(self):
        focus = self.focus_state()
        for axis in "xywh":
            self.assertAlmostEqual(focus["liveFrame"][axis], focus["card"][axis], delta=1)
        return focus


class SelectTests(FocusCase):
    def test_a_live_node_focuses_its_existing_page_by_click_and_by_keys(self):
        """VAL-SPATIAL-007"""
        tabs = self.pages(5)
        self.seed_page(tabs[2])
        self.row(tabs)
        self.focus(tabs[0])
        self.show_overview()
        self.key("0", "cmd")
        before = self.document(tabs[2])
        requests, browsers, ids = self.requests(), self.ui()["cefBrowserCount"], self.tab_ids()
        renderers = self.renderers()
        self.assertEqual(browsers, len(ids))
        log = {"before": before, "browsers": browsers}

        def unchanged(step):
            self.assertEqual(self.document(tabs[2]), before, step)
            self.assertEqual(self.requests(), requests, step)
            self.assertEqual(self.ui()["cefBrowserCount"], browsers, step)
            self.assertEqual(self.tab_ids(), ids, step)
            count, profiles = self.renderers()
            self.assertLessEqual(count, renderers[0], step)
            self.assertTrue(all(os.path.realpath(p).startswith(os.path.realpath(self.data_dir))
                                for p in profiles), (step, profiles))

        self.call("test.click", {"target": f"node:{self.node_of(tabs[2])['id']}"})
        self.wait_presentation("focused")
        self.assertEqual(self.active_id(), tabs[2])
        self.assert_card_is_page()
        unchanged("click")
        self.show_overview()
        unchanged("overview")
        self.activate(tabs[0], "overview")
        for _ in range(2):
            self.key("ArrowRight")
        self.assertEqual(self.ui()["overview"]["selection"], self.node_of(tabs[2])["id"])
        self.key("Return")
        self.wait_presentation("focused")
        self.assertEqual(self.active_id(), tabs[2])
        self.assert_card_is_page()
        unchanged("keys")
        log["after"] = self.document(tabs[2])
        save("spatial-007.json", log)

    def test_a_side_column_card_focuses_its_page_the_same_way(self):
        """VAL-SPATIAL-007"""
        opener = self.open_page("Opener", "popups.html")
        popups = self.popups(opener, 2)
        self.assertEqual(self.active_id(), opener)
        self.show_page()
        focus = self.focus_state()
        cards = focus["left"] + focus["right"]
        self.assertEqual(len(cards), 2)
        target = cards[0]
        tab = self.nodes_tab(target["id"])
        before = self.document(tab)
        browsers, requests = self.ui()["cefBrowserCount"], self.requests()
        self.call("test.click", {"target": f"node:{target['id']}"})
        bs.wait_until(lambda: self.active_id() == tab, what="the neighbour to be focused")
        self.assertEqual(self.presentation(), "focused")
        self.assert_card_is_page()
        self.assertEqual(self.document(tab), before)
        self.assertEqual(self.ui()["cefBrowserCount"], browsers)
        self.assertEqual(self.requests(), requests)
        self.assertIn(opener, [self.nodes_tab(c["id"]) for c in
                               self.focus_state()["left"] + self.focus_state()["right"]])
        self.show_overview()
        self.assertFalse(self.focus_state()["visible"])
        reply = self.call("test.click", {"target": f"node:{self.node_of(opener)['id']}"})
        self.assertNotEqual(reply["hit"], "FocusContextView")

    def test_twenty_pages_make_twenty_nodes_and_twenty_browsers(self):
        """VAL-SPATIAL-007"""
        tabs = self.pages(20)
        self.show_overview()
        self.key("0", "cmd")
        live = [n for n in self.nodes() if n["kind"] == "live"]
        self.assertEqual((len(live), len(self.overview_nodes()), self.ui()["cefBrowserCount"]),
                         (20, 20, 20))
        self.assertEqual(self.tab_ids(), tabs)
        self.show_page()
        self.assertEqual(self.ui()["cefBrowserCount"], 20)

    def overview_nodes(self):
        return self.ui()["overview"]["nodes"]


class HeldKeyTests(FocusCase):
    def test_a_held_return_opens_the_page_once_and_the_page_never_sees_it(self):
        tabs = self.pages(2)
        start = len(self.fixtures.log())
        keys = self.open_page("Keys", "keys.html")
        bs.wait_until(lambda: any(b.get("ready") == ["1"] for b in self.beacons(start)),
                      what="the page to be ready for input")
        tabs.append(keys)
        self.row(tabs)
        self.activate(tabs[0], "overview")
        for _ in range(2):
            self.key("ArrowRight")
        self.assertEqual(self.ui()["overview"]["selection"], self.node_of(keys)["id"])

        def epoch():
            return next(t for t in self.ui()["tabs"] if t["id"] == keys)["epoch"]

        before, start = epoch(), len(self.fixtures.log())
        self.call("test.key", {"key": "Return", "release": False})
        self.wait_presentation("focused")
        self.assertEqual(self.active_id(), keys)
        bs.wait_until(lambda: not self.call("test.motion")["inFlight"]
                      and self.ui()["firstResponder"]["tabId"] == keys, what="the page to land")
        # The repeats of a long press arrive after the landing, and then the release.
        self.call("test.key", {"key": "Return", "press": False, "release": False, "repeats": 5})
        self.call("test.key", {"key": "Return", "press": False})
        self.assertEqual(epoch(), before)
        self.call("test.key", {"key": "x"})
        bs.wait_until(lambda: any(b.get("ev") == ["keyup"] and b.get("key") == ["x"]
                                  for b in self.beacons(start)), what="the page to hear a canary key")
        heard = [(b["ev"][0], b.get("key", [""])[0]) for b in self.beacons(start) if b.get("ev")]
        self.assertEqual([h for h in heard if h[1] not in ("x", "")], [], heard)
        self.assertEqual(epoch(), before + 1, "only the canary key counts as human input")
        self.assertEqual((self.presentation(), self.active_id()), ("focused", keys))


class LayoutTests(FocusCase):
    def test_the_live_page_fills_the_card_and_context_stays_outside_it(self):
        """VAL-SPATIAL-011"""
        opener = self.open_page("Opener", "popups.html")
        popups = self.popups(opener, 3)
        self.show_page()
        size = self.ui()["windowFrame"]
        focus = self.assert_card_is_page()
        self.assertEqual((size["w"], size["h"]), (1440, 900))
        card = focus["card"]
        self.assertEqual((card["x"], card["y"], card["w"]), (468, 208, 632))
        self.assertTrue(focus["columns"])
        label = focus["currentLabel"]
        self.assertEqual(label["text"], "Current page")
        self.assertLessEqual(label["frame"]["y"] + label["frame"]["h"], card["y"])
        self.assertGreaterEqual(focus["caption"]["y"], card["y"] + card["h"])
        self.assertEqual(sorted(self.nodes_tab(c["id"]) for c in focus["left"] + focus["right"]),
                         sorted(popups))
        for column in focus["left"] + focus["right"]:
            frame = column["frame"]
            self.assertTrue(frame["x"] + frame["w"] <= card["x"] or frame["x"] >= card["x"] + card["w"],
                            frame)
        self.assertEqual([c["frame"]["x"] for c in focus["left"]], [])
        shot = os.path.join(LOG_DIR, "focus-1440.png")
        self.call("test.screenshot", {"path": shot})

        loner = self.open_page("No edges")
        self.show_page()
        alone = self.assert_card_is_page()
        self.assertFalse(alone["columns"])
        self.assertEqual(alone["neighbours"], [])
        self.assertAlmostEqual(alone["card"]["x"] * 2 + alone["card"]["w"], 1440, delta=1)
        self.assertEqual(self.active_id(), loner)

    def test_below_1100_the_page_fills_the_window_and_resizing_never_reloads(self):
        """VAL-SPATIAL-011"""
        opener = self.open_page("Opener", "popups.html")
        self.popups(opener, 2)
        self.show_page()
        before = self.document(opener)
        requests = self.requests()
        report = {}
        for width in (1000, 720, 1099, 1100, 1440, 1000):
            self.call("test.windowSize", {"w": width, "h": 900})
            bs.wait_until(lambda: self.ui()["windowFrame"]["w"] == width, what=f"width {width}")
            focus = bs.wait_until(
                lambda: (lambda f: f if f["size"]["w"] == width else None)(self.focus_state()),
                what="the focus layout to follow")
            self.assert_card_is_page()
            self.assertEqual(focus["columns"], width >= 1100, width)
            card = focus["card"]
            if width < 1100:
                left, right = card["x"], width - card["x"] - card["w"]
                self.assertAlmostEqual(left, right, delta=0.5)
                self.assertTrue(0 < left <= 24, (width, left))
                self.assertEqual((focus["left"], focus["right"]), ([], []))
            report[width] = {"card": card, "columns": focus["columns"]}
            self.assertEqual(self.document(opener), before, width)
        self.assertEqual(self.requests(), requests)
        save("spatial-011.json", report)


class LauncherTests(FocusCase):
    # A key makes Start task commit a run; the model is held and the run stopped before the hold
    # is released, so the closed port is never tried.
    env = bs.provider_env(f"http://127.0.0.1:{bs.provider_port()}/v1")

    def open_by(self, how):
        if how == "key":
            self.key("t", "cmd")
        else:
            self.call("test.click", {"target": "commandButton"})
        return bs.wait_until(
            lambda: (lambda s: s if s["launcher"]["open"]
                     and s["firstResponder"].get("chromeId") == "launcherField" else None)(self.ui()),
            what="the launcher open with its field focused")

    def stop_runs(self):
        for run in self.call("run.list")["runs"]:
            if run["state"] not in ENDED:
                self.call("run.stop", {"runId": run["runId"]})

    def test_the_launcher_opens_once_from_every_presentation(self):
        """VAL-LAUNCH-001"""
        report = {}

        def check(situation):
            for how in ("key", "button"):
                tabs, presentation = self.tab_ids(), self.presentation()
                state = self.open_by(how)
                self.assertEqual(self.tab_ids(), tabs, (situation, how))
                self.assertEqual(self.presentation(), presentation)
                self.assertTrue(state["commandButton"]["compactChip"], (situation, how))
                frame = state["launcher"]["frame"]
                self.key("t", "cmd")
                self.assertEqual(self.ui()["launcher"]["frame"], frame, (situation, how))
                report[f"{situation} {how}"] = {"frame": frame, "tabs": len(tabs)}
                self.close_launcher()

        self.assertEqual(self.presentation(), "overview")
        check("overview with no pages")
        tabs = self.pages(2)
        self.show_overview()
        check("overview with pages")
        self.show_page()
        self.assertTrue(self.focus_state()["visible"])
        check("focused page")
        self.key("f", "cmd")
        self.wait_responder(chromeId="findField")
        check("focused page with the find bar open")
        self.key("Escape")
        self.wait_responder(tabId=tabs[1])
        self.open_by("key")
        self.call("test.holdModel", {"on": True})
        self.addCleanup(self.call, "test.holdModel", {"on": False})
        self.addCleanup(self.stop_runs)
        self.call("test.type", {"text": "Find a quiet hotel in Kyoto"})
        self.key("Return")
        self.wait_launcher(False)
        runs = self.call("run.list")["runs"]
        self.assertEqual([r["state"] for r in runs], ["pending"])
        check("a run is active")
        self.call("test.screenshot", {"path": os.path.join(LOG_DIR, "launch-001-focused.png")})
        self.show_overview()
        save("launch-001.json", report)

    def test_escape_restores_the_previous_owner_and_keeps_the_query(self):
        """VAL-LAUNCH-002"""
        tabs = self.pages(2)
        self.show_overview()
        runs = self.call("run.list")["runs"]

        def round_trip(setup, owner, show):
            snapshot = {"tabs": self.tab_ids(), "active": self.active_id(),
                        "presentation": self.presentation(), "requests": self.requests(),
                        "url": next(t["url"] for t in self.tabs() if t["id"] == self.active_id())}
            setup()
            before = self.ui()["firstResponder"]
            self.assertEqual({k: before.get(k) for k in owner}, owner)
            self.key("t", "cmd")
            self.wait_responder(chromeId="launcherField")
            self.fill_launcher("partial que")
            self.key("Escape")
            self.wait_launcher(False)
            self.assertEqual(self.ui()["firstResponder"], before)
            now = {"tabs": self.tab_ids(), "active": self.active_id(),
                   "presentation": self.presentation(), "requests": self.requests(),
                   "url": next(t["url"] for t in self.tabs() if t["id"] == self.active_id())}
            self.assertEqual(now, snapshot)
            show()
            self.assertEqual(self.call("run.list")["runs"], runs)
            self.key("t", "cmd")
            self.wait_responder(chromeId="launcherField")
            state = self.ui()["launcher"]
            self.assertEqual((state["query"], state["fieldText"]), ("partial que", "partial que"))
            self.assertEqual(state["rows"][0]["kind"], "search")
            self.close_launcher()

        round_trip(lambda: self.tab_to("commandButton"), {"chromeId": "commandButton"}, lambda: None)
        selected = self.ui()["overview"]["selection"]
        self.assertIsNotNone(selected)
        round_trip(lambda: self.tab_to("root"), {"chromeId": "root"},
                   lambda: self.assertEqual(self.ui()["overview"]["selection"], selected))
        self.show_page()

        def find():
            self.key("f", "cmd")
            self.wait_responder(chromeId="findField")

        round_trip(find, {"chromeId": "findField"}, lambda: self.assertTrue(self.chrome()["find"]["open"]))
        self.key("Escape")
        self.key("t", "cmd")
        self.wait_responder(chromeId="launcherField")
        self.key("Return")
        self.wait_launcher(False)
        self.key("t", "cmd")
        self.wait_responder(chromeId="launcherField")
        self.assertEqual(self.ui()["launcher"]["query"], "")
        self.close_launcher()
        self.assertEqual(len(self.tab_ids()), 3)

    def test_the_background_stays_still_while_the_launcher_is_open(self):
        """VAL-LAUNCH-010"""
        tabs = self.pages(3)
        self.row(tabs)
        keys = [("w", ["cmd"]), ("t", ["cmd", "shift"]), ("Tab", ["ctrl"]),
                ("Tab", ["ctrl", "shift"]), ("r", ["cmd"]), ("[", ["cmd"]), ("]", ["cmd"]),
                ("f", ["cmd"]), ("l", ["cmd"]), ("d", ["cmd"]), ("\\", ["cmd", "shift"]),
                ("=", ["cmd"]), ("-", ["cmd"]), ("0", ["cmd"])] \
            + [(str(n), ["cmd"]) for n in range(1, 10)]

        def snapshot():
            ui = self.ui()
            return {"tabs": [(t["id"], t["url"]) for t in self.tabs()], "active": ui["activeTabId"],
                    "presentation": ui["presentation"], "viewport": ui["canvas"]["viewport"],
                    "selection": ui["overview"]["selection"], "requests": self.requests(),
                    "find": ui["chrome"]["find"]["open"], "closed": len(self.nodes())}

        for presentation in ("focused", "overview"):
            self.activate(tabs[1], presentation)
            self.key("t", "cmd")
            self.wait_responder(chromeId="launcherField")
            self.fill_launcher("abc")
            before = snapshot()
            counters = [self.evaluate("[window.__keys, window.__pointer]", t) for t in tabs]
            for title in ("Close Tab", "Reload Page", "Show Overview" if presentation == "focused"
                          else "Show Page"):
                with self.assertRaises(bs.RpcError, msg=title):
                    self.call("test.menu", {"invoke": title})
            for key, modifiers in keys:
                self.call("test.key", {"key": key, "modifiers": modifiers})
                self.assertTrue(self.launcher_open(), (presentation, key, modifiers))
                self.assertEqual(snapshot(), before, (presentation, key, modifiers))
                self.assertEqual(self.ui()["launcher"]["query"], "abc")
            if presentation == "overview":
                self.call("test.scroll", {"dx": 120, "dy": 80})
            self.call("test.magnify", {"by": -0.4})
            self.assertEqual(snapshot(), before, presentation)
            self.assertEqual([self.evaluate("[window.__keys, window.__pointer]", t) for t in tabs],
                             counters)
            if presentation == "overview":
                panel = self.ui()["launcher"]["frame"]
                node = next(n["id"] for n in self.ui()["overview"]["nodes"]
                            if not panel["x"] <= n["frame"]["x"] + n["frame"]["w"] / 2
                            <= panel["x"] + panel["w"])
                reply = self.call("test.click", {"target": f"node:{node}"})
                self.assertEqual(reply["hit"], "LauncherView")
                self.wait_launcher(False)
                self.assertEqual(snapshot() | {"x": 0}, before | {"x": 0})
            else:
                self.close_launcher()

        self.key("t", "cmd")
        self.wait_responder(chromeId="launcherField")
        self.key(",", "cmd")
        bs.wait_until(lambda: self.ui()["settings"]["open"], what="Settings")
        self.assertTrue(self.launcher_open())


class ShortcutTests(FocusCase):
    def landed(self, presentation, tab):
        self.assertEqual(self.active_id(), tab)
        self.assertEqual(self.presentation(), presentation)
        node = self.node_of(tab)["id"]
        if presentation == "focused":
            self.assert_card_is_page()
        else:
            overview = self.ui()["overview"]
            self.assertEqual(overview["selection"], node)
            self.assertEqual(overview["currentLabel"]["node"], node)

    def run_in(self, presentation):
        tabs = self.pages(10)
        self.focus(tabs[0])
        (self.show_page if presentation == "focused" else self.show_overview)()
        self.landed(presentation, tabs[0])
        for expected in tabs[1:] + [tabs[0]]:
            self.key("Tab", "ctrl")
            self.landed(presentation, expected)
        self.key("Tab", "ctrl", "shift")
        self.landed(presentation, tabs[-1])
        for number in range(1, 9):
            self.key(str(number), "cmd")
            self.landed(presentation, tabs[number - 1])
        self.key("9", "cmd")
        self.landed(presentation, tabs[-1])

        urls = {t["id"]: t["url"] for t in self.tabs()}
        self.activate(tabs[4], presentation)
        self.key("w", "cmd")
        bs.wait_until(lambda: tabs[4] not in self.tab_ids(), what="page 5 closed")
        self.assertEqual(len(self.tab_ids()), 9)
        self.assertEqual(self.presentation(), presentation)
        archived = [n for n in self.nodes() if n["kind"] == "archived"]
        self.assertEqual([n["url"] for n in archived], [urls[tabs[4]]])
        second = next(t for t in self.tabs() if t["active"])["url"]
        self.key("w", "cmd")
        bs.wait_until(lambda: len(self.tab_ids()) == 8, what="a second page closed")
        for count, wanted in ((9, second), (10, urls[tabs[4]])):
            self.key("t", "cmd", "shift")
            bs.wait_until(lambda: len(self.tab_ids()) == count, what=f"{count} pages again")
            self.assertEqual(next(t for t in self.tabs() if t["active"])["url"], wanted)
            self.assertEqual(self.presentation(), presentation)
        bs.wait_until(lambda: len([n for n in self.nodes() if n["kind"] == "live"]) == 10,
                      what="ten live nodes")

    def test_page_shortcuts_act_on_the_active_page_in_the_focused_presentation(self):
        """VAL-TABS-005"""
        self.run_in("focused")

    def test_page_shortcuts_act_on_the_active_page_in_the_overview(self):
        """VAL-TABS-005"""
        self.run_in("overview")

    def test_history_and_reload_shortcuts_step_once(self):
        """VAL-TABS-005"""
        tab = self.open_page("A")
        second = titled("B")
        self.navigate(tab, second)
        first = titled("A")
        self.show_page()
        self.key("[", "cmd")
        self.wait_loaded(first, tab)
        self.key("]", "cmd")
        self.wait_loaded(second, tab)
        self.assertEqual(self.presentation(), "focused")
        nonce, requests = self.evaluate("window.__nonce", tab), self.requests()
        self.key("r", "cmd")
        bs.wait_until(lambda: self.evaluate("window.__nonce", tab) != nonce, what="a reload")
        self.wait_loaded(second, tab)
        self.assertEqual(self.requests(), requests + 1)
        self.assertEqual(self.presentation(), "focused")
        self.assert_card_is_page()


class FindTests(FocusCase):
    def menu_item(self, menu, title):
        return next(i for m in self.call("test.menu") if m["title"] == menu for i in m["items"]
                    if i.get("title", "").startswith(title))

    def find_item(self):
        return self.menu_item("Edit", "Find")

    def test_find_opens_over_the_focused_page_and_nowhere_else(self):
        """VAL-TABS-007"""
        tab = self.open_page("Findable")
        self.show_page()
        self.wait_responder(tabId=tab)
        self.key("f", "cmd")
        self.wait_responder(chromeId="findField")
        find = self.chrome()["find"]
        card = self.focus_state()["card"]
        bar = find["frame"]
        self.assertTrue(find["open"] and find["focused"])
        self.assertTrue(card["x"] <= bar["x"] and bar["x"] + bar["w"] <= card["x"] + card["w"]
                        and card["y"] <= bar["y"] and bar["y"] + bar["h"] <= card["y"] + card["h"],
                        (bar, card))
        button = self.ui()["commandButton"]["frame"]
        caption = self.focus_state()["caption"]
        self.assertLessEqual(bar["y"] + bar["h"], button["y"])
        self.assertLessEqual(bar["y"] + bar["h"], caption["y"])
        self.call("test.type", {"text": "Launcher"})
        bs.wait_until(lambda: self.chrome()["find"]["matches"] >= 1, what="a match")
        shot = os.path.join(LOG_DIR, "find-focused.png")
        self.call("test.screenshot", {"path": shot})
        image = png.Image(shot)
        scale = image.width / self.ui()["windowFrame"]["w"]
        highlighted = any(
            r > 200 and g > 120 and b < 120
            for y in range(int(card["y"] * scale), int((card["y"] + 60) * scale), 2)
            for x in range(int(card["x"] * scale), int((card["x"] + 200) * scale), 2)
            for r, g, b in [image.pixel(x, y)[:3]])
        self.assertTrue(highlighted, "no find highlight in the page")
        self.key("Escape")
        bs.wait_until(lambda: not self.chrome()["find"]["open"], what="the bar closed")
        self.wait_responder(tabId=tab)

        self.show_overview()
        self.assertFalse(self.find_item()["enabled"])
        self.key("f", "cmd")
        self.assertFalse(self.chrome()["find"]["open"])

    def test_menus_and_shortcuts_follow_the_launchers_availability(self):
        """VAL-TABS-007"""
        blank = self.call("open_tab", {"url": "about:blank", "activate": True})["id"]
        bs.wait_until(lambda: self.active_id() == blank, what="the blank tab")
        before = self.ui()["firstResponder"]
        item = self.find_item()
        self.assertFalse(item["enabled"])
        self.key("f", "cmd")
        self.assertFalse(self.chrome()["find"]["open"])
        self.assertEqual(self.ui()["firstResponder"], before)
        self.key("t", "cmd")
        self.wait_responder(chromeId="launcherField")
        self.call("test.type", {"text": "find in page"})
        bs.wait_until(lambda: self.ui()["launcher"]["current"], what="rows")
        row = next(r for r in self.ui()["launcher"]["rows"] if r["title"] == "Find in page")
        self.assertFalse(row["enabled"])
        self.close_launcher()
        self.key("r", "cmd")
        self.assertEqual(self.tab_ids().count(blank), 1)
        page = self.open_page("Earlier")
        self.navigate(page, "about:blank")
        self.assertTrue(self.menu_item("History", "Back")["enabled"])
        self.call("test.activateTab", {"tabId": blank})
        self.key("w", "cmd")
        bs.wait_until(lambda: blank not in self.tab_ids(), what="the blank tab closed")


class AcceptanceTests(FocusCase):
    def test_the_launcher_leaves_the_focused_page_untouched(self):
        """VAL-CROSS-001"""
        tab = self.open_page("Keeper")
        self.show_page()
        self.evaluate("document.getElementById('box').focus(); window.scrollTo(0, 400)", tab)
        bs.wait_until(lambda: self.evaluate("window.scrollY", tab) == 400, what="scrolled")
        self.evaluate("window.__keys = 0", tab)
        self.wait_responder(tabId=tab)
        before = self.document(tab) | {"active": self.evaluate("document.activeElement.id", tab)}
        requests, tabs = self.requests(), self.tab_ids()
        self.key("t", "cmd")
        self.wait_responder(chromeId="launcherField")
        self.call("test.type", {"text": "kyoto hotels 12345"})
        for key in ("ArrowDown", "ArrowDown", "ArrowUp"):
            self.key(key)
        labels = {r["actionLabel"] for r in self.ui()["launcher"]["rows"]}
        self.assertTrue({"Start task", "Search the web"} <= labels, labels)
        self.assertEqual(self.document(tab), {k: v for k, v in before.items() if k != "active"})
        self.assertEqual(self.evaluate("window.__keys", tab), 0)
        self.key("Escape")
        self.wait_launcher(False)
        bs.wait_until(lambda: self.evaluate("document.activeElement.id", tab) == "box",
                      what="focus back in the page input")
        self.call("test.type", {"text": "x"})
        bs.wait_until(lambda: self.evaluate("document.getElementById('box').value", tab)
                      in ("keepx", "xkeep"), what="typing in the page")
        after = self.document(tab)
        for field in ("nonce", "loader", "url", "origin"):
            self.assertEqual(after[field], before[field], field)
        self.assertEqual((self.tab_ids(), self.requests()), (tabs, requests))

    def test_overview_and_back_returns_to_the_same_live_page(self):
        """VAL-CROSS-003"""
        tabs = self.pages(5)
        self.seed_page(tabs[2])
        self.row(tabs)
        self.focus(tabs[2])
        self.show_page()
        before = self.document(tabs[2])
        requests, browsers, ids = self.requests(), self.ui()["cefBrowserCount"], self.tab_ids()
        node = self.node_of(tabs[2])["id"]

        def check(step, presentation):
            self.wait_presentation(presentation)
            self.assertEqual(self.document(tabs[2]), before, step)
            self.assertEqual(self.requests(), requests, step)
            self.assertEqual(self.ui()["cefBrowserCount"], browsers, step)
            self.assertEqual(self.tab_ids(), ids, step)
            self.assertEqual(self.active_id(), tabs[2], step)

        self.key("\\", "cmd", "shift")
        check("overview", "overview")
        self.key("0", "cmd")
        self.call("test.click", {"target": f"node:{node}"})
        check("click", "focused")
        self.show_overview()
        self.key("ArrowLeft")
        self.key("ArrowRight")
        self.assertEqual(self.ui()["overview"]["selection"], node)
        self.key("Return")
        check("keys", "focused")
        self.call("test.magnify", {"by": -0.3})
        check("pinch out", "overview")
        self.key("\\", "cmd", "shift")
        check("toggle", "focused")
        self.key("-", "cmd")
        check("zoom out", "overview")
        bs.wait_until(lambda: self.node_of(tabs[2])["previewState"] == "fresh",
                      what="a fresh preview after leaving the page")
        self.assertTrue(next(n for n in self.ui()["overview"]["nodes"] if n["id"] == node)["hasImage"])
        self.key("\\", "cmd", "shift")
        check("focus again", "focused")


if __name__ == "__main__":
    unittest.main()
