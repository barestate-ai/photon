"""Full window: the focused page filling the window below the title bar, entered and left by
every route, the same live page throughout (VAL-VIEW-001..009, VAL-VIEW-014).

Neighbours, caption, wordmark and canvas title leave the window; the page is never reloaded. The
values come from `test.ui` (presentation, `fullWindow`, `window`), `test.motion` and the fixture
log."""
import os
import time

import bs
from appcase import save
from test_motion import MotionCase
from test_perm import PermBase
from test_tasks import TaskCase

TITLE_BAR_MIN = 20


def menu_item(items, title):
    for item in items:
        if item.get("title") == title:
            return item
        found = menu_item(item.get("items", []), title)
        if found:
            return found
    return None


class FullWindowCase(MotionCase):
    def level(self):
        return self.ui()["presentation"]

    def wait_level(self, wanted):
        bs.wait_until(lambda: self.level() == wanted, what=f"presentation {wanted}")
        self.settle()

    def full(self):
        return self.ui()["fullWindow"]

    def menu(self, title):
        return menu_item(self.call("test.menu"), title)

    def enter_with_key(self):
        self.key("Return", "cmd")
        self.wait_level("full-window")

    def three_pages(self, seed_third=True):
        tabs = self.pages(3)
        self.row(tabs)
        self.focus(tabs[2])
        if seed_third:
            self.seed_page(tabs[2])
        self.show_page()
        return tabs

    def assert_fills(self, tab, width=1440, height=900):
        ui = self.ui()
        live = next(t for t in ui["tabs"] if t["id"] == tab)["frame"]
        inset = ui["fullWindow"]["titleBarInset"]
        self.assertGreaterEqual(inset, TITLE_BAR_MIN)
        for axis, wanted in (("x", 0), ("y", inset), ("w", width), ("h", height - inset)):
            self.assertAlmostEqual(live[axis], wanted, delta=1, msg=f"{axis}: {live}")
        content = ui["fullWindow"]["windowContent"]
        self.assertAlmostEqual(live["x"] + live["w"], content["w"], delta=1)
        self.assertAlmostEqual(live["y"] + live["h"], content["h"], delta=1)
        return live

    def assert_chrome_gone(self):
        areas = self.full()["visibleArea"]
        self.assertEqual({k: v for k, v in areas.items() if v}, {}, areas)
        focus = self.focus_state()
        self.assertEqual((focus["neighbours"], focus["left"], focus["right"]), ([], [], []))
        labels = self.ax_labels()
        self.assertNotIn("Canvas title", labels)
        self.assertNotIn("Open Full Window", labels)
        return labels

    def ax_labels(self):
        labels = []

        def walk(nodes):
            for node in nodes:
                labels.append(node.get("label", ""))
                walk(node.get("children", []))
        walk(self.call("test.ax"))
        return labels

    def unchanged(self, tab, before, requests, browsers):
        self.assertEqual(self.document(tab), before)
        self.assertEqual(self.requests(), requests)
        self.assertEqual(self.ui()["cefBrowserCount"], browsers)

    def transition(self, action, limit=3.0):
        """Everything the registry ran for `action`, sampled back to back until it rests."""
        seen = {}
        before = {item["id"] for item in self.motion()["recent"]}
        samples = []
        action()
        end = time.time() + limit
        while time.time() < end:
            state = self.motion()
            samples.append(state)
            for item in state["inFlight"] + state["recent"]:
                if item["id"] not in before:
                    seen[item["id"]] = item
            if seen and not state["inFlight"] and state["camera"]["phase"] == "idle":
                break
        return list(seen.values()), samples


class EntryTests(FullWindowCase):
    def test_every_entry_route_fills_the_window_with_the_same_page(self):
        """VAL-VIEW-001"""
        tabs = self.three_pages()
        page = tabs[2]
        before = self.document(page)
        requests, browsers = self.requests(), self.ui()["cefBrowserCount"]
        report = {}
        for route in ("caption", "menu", "key"):
            self.assertEqual(self.level(), "focused", route)
            self.assertEqual(self.menu("Open Full Window")["key"], "\r")
            if route == "caption":
                caption = self.ui()["caption"]
                self.assertFalse(caption["control"]["visible"])
                self.call("test.move", {"target": "caption"})
                bs.wait_until(lambda: self.ui()["caption"]["control"]["visible"], what="the ⤢")
                control = self.ui()["caption"]["control"]
                self.assertEqual(control["label"], "Open Full Window")
                self.call("test.click", {"target": "captionExpand"})
            elif route == "menu":
                self.call("test.menu", {"invoke": "Open Full Window"})
            else:
                self.key("Return", "cmd")
            self.wait_level("full-window")
            live = self.assert_fills(page)
            report[route] = {"live": live, "full": self.full()}
            self.assert_chrome_gone()
            self.assertEqual(self.menu("Exit Full Window")["enabled"], True)
            self.assertEqual(self.active_id(), page)
            self.unchanged(page, before, requests, browsers)
            self.key("Return", "cmd")
            self.wait_level("focused")
            self.assert_card_is_page()
            self.unchanged(page, before, requests, browsers)
        save("view-001.json", report)

    def test_a_pointer_away_from_the_caption_hides_the_expand_control(self):
        """VAL-VIEW-001"""
        self.three_pages(seed_third=False)
        self.call("test.move", {"target": "caption"})
        bs.wait_until(lambda: self.ui()["caption"]["control"]["visible"], what="the ⤢")
        self.call("test.move", {"x": 20, "y": 500})
        bs.wait_until(lambda: not self.ui()["caption"]["control"]["visible"], what="the ⤢ gone")

    def test_a_double_click_opens_full_window_and_a_single_click_only_focuses(self):
        """VAL-VIEW-002"""
        tabs = self.pages(5)
        self.row(tabs)
        self.focus(tabs[0])
        self.show_overview()
        self.key("0", "cmd")
        self.settle()
        self.seed_page(tabs[1])
        before = self.document(tabs[1])
        requests, browsers = self.requests(), self.ui()["cefBrowserCount"]
        card = f"node:{self.node_of(tabs[1])['id']}"

        items, _ = self.transition(lambda: self.call("test.click", {"target": card, "count": 2}))
        self.wait_level("full-window")
        self.assertEqual(self.active_id(), tabs[1])
        self.assert_fills(tabs[1])
        self.unchanged(tabs[1], before, requests, browsers)
        # The first click of the pair starts a focus flight that the second one re-aims at the full
        # frame: it ends interrupted, and exactly one camera animation ends at the full-window frame.
        cameras = [i for i in items if i["purpose"] == "camera" and not i["interrupted"]]
        self.assertEqual([(i["target"], i["to"]) for i in cameras],
                         [(self.node_of(tabs[1])["id"], {"scale": 1, "x": 0, "y": 0})])
        self.assertEqual(self.motion()["inFlight"], [])
        save("view-002.json", {"items": items})

        self.key("\\", "cmd", "shift")
        self.wait_level("overview")
        self.call("test.click", {"target": f"node:{self.node_of(tabs[2])['id']}"})
        levels = set()
        end = time.time() + 0.6
        while time.time() < end:
            levels.add(self.level())
            time.sleep(0.016)
        self.assertEqual(levels - {"overview"}, {"focused"})
        self.assertEqual(self.active_id(), tabs[2])
        focus = self.assert_card_is_page()
        self.assertEqual((focus["card"]["w"], focus["card"]["h"]), (632, 532))

        self.show_overview()
        self.call("test.click", {"target": "root", "x": 720, "y": 860, "count": 2})
        time.sleep(0.4)
        self.assertEqual((self.level(), self.active_id()), ("overview", tabs[2]))
        self.assertEqual(self.ui()["cefBrowserCount"], browsers)

    def test_a_synthesized_double_click_event_opens_full_window(self):
        """VAL-VIEW-002"""
        tabs = self.pages(3)
        self.row(tabs)
        self.focus(tabs[0])
        self.show_overview()
        self.call("test.click", {"target": f"node:{self.node_of(tabs[1])['id']}", "count": 2})
        self.wait_level("full-window")
        self.assertEqual(self.active_id(), tabs[1])
        self.assert_fills(tabs[1])

    def test_a_double_click_opens_full_window_when_the_first_click_lands_at_once(self):
        """VAL-VIEW-002"""
        tabs = self.pages(3)
        self.row(tabs)
        self.focus(tabs[0])
        self.show_overview()
        self.call("test.reduceMotion", {"on": True})
        self.call("test.click", {"target": f"node:{self.node_of(tabs[1])['id']}", "count": 2})
        self.wait_level("full-window")
        self.assertEqual(self.active_id(), tabs[1])
        self.assert_fills(tabs[1])

    def test_the_open_pages_list_opens_in_full_window_from_both_levels(self):
        """VAL-VIEW-003"""
        titles = ["Alpha harbour", "Bravo market", "Charlie garden", "Delta bridge"]
        tabs = [self.open_page(t) for t in titles]
        self.call("test.closeTab", {"tabId": self.tab_ids()[0]})
        self.row(tabs)
        self.focus(tabs[2])
        self.seed_page(tabs[1])
        before = self.document(tabs[1])
        browsers, requests = self.ui()["cefBrowserCount"], self.requests()
        for start in ("overview", "focused"):
            self.activate(tabs[2], start)
            self.settle()
            self.choose_in_pages("Bravo", tabs[1])
            levels = set()
            self.key("Return")
            end = time.time() + 1.2
            while time.time() < end:
                levels.add(self.level())
                time.sleep(0.016)
            self.assertEqual(levels - {start}, {"full-window"}, (start, levels))
            self.assertNotIn("focused" if start == "overview" else "overview", levels)
            self.assertEqual(self.active_id(), tabs[1])
            self.assert_fills(tabs[1])
            self.assertFalse(self.ui()["launcher"]["open"])
            self.unchanged(tabs[1], before, requests, browsers)
            self.key("Return", "cmd")
            self.wait_level("focused")


    def choose_in_pages(self, query, tab):
        """Opens the Open pages list, filters it and walks to `tab`'s row, ready for Return."""
        self.key("t", "cmd")
        self.wait_launcher(True)
        self.call("test.type", {"text": "Open pages"})
        bs.wait_until(lambda: self.ui()["launcher"]["current"]
                      and self.ui()["launcher"]["query"] == "Open pages", what="rows")
        row = next(r for r in self.ui()["launcher"]["rows"] if r["id"] == "command:openPages")
        while self.ui()["launcher"]["active"] != row["id"]:
            self.key("ArrowDown")
        self.key("Return")
        bs.wait_until(lambda: self.ui()["launcher"]["scope"] == "pages"
                      and self.ui()["launcher"]["current"], what="the pages scope")
        self.call("test.type", {"text": query})
        bs.wait_until(lambda: self.ui()["launcher"]["query"] == query
                      and self.ui()["launcher"]["current"], what=query)
        target = next(r for r in self.ui()["launcher"]["rows"] if r["target"] == tab)
        while self.ui()["launcher"]["active"] != target["id"]:
            self.key("ArrowDown")

    def test_choosing_the_page_already_in_full_window_gives_the_keyboard_back_to_it(self):
        """VAL-VIEW-003, VAL-VIEW-005"""
        tabs = self.three_pages(seed_third=False)
        self.enter_with_key()
        self.choose_in_pages("Page 3", tabs[2])
        self.key("Return")
        self.wait_launcher(False)
        self.assertEqual((self.level(), self.active_id()), ("full-window", tabs[2]))
        before = self.evaluate("window.__escapes", tabs[2])
        self.key("Escape")
        bs.wait_until(lambda: self.evaluate("window.__escapes", tabs[2]) == before + 1,
                      what="Escape reaching the page without another click")


class ExitTests(FullWindowCase):
    def test_every_exit_route_leaves_one_level_and_the_page_keeps_its_state(self):
        """VAL-VIEW-004"""
        tabs = self.three_pages()
        page = tabs[2]
        before = self.document(page)
        requests, browsers = self.requests(), self.ui()["cefBrowserCount"]
        self.assertEqual(self.menu("Open Full Window")["modifiers"], ["cmd"])

        self.enter_with_key()
        self.assertEqual(self.menu("Exit Full Window")["enabled"], True)
        self.key("Return", "cmd")
        self.wait_level("focused")
        self.assert_card_is_page()
        self.assertEqual(self.menu("Open Full Window")["title"], "Open Full Window")

        self.enter_with_key()
        self.call("test.magnify", {"by": -0.5})
        self.wait_level("focused")
        self.assert_card_is_page()
        self.call("test.magnify", {"by": -0.5})
        self.wait_level("overview")

        self.activate(page, "focused")
        self.enter_with_key()
        self.key("\\", "cmd", "shift")
        self.wait_level("overview")

        self.activate(page, "focused")
        self.enter_with_key()
        self.assertFalse(self.full()["exitControl"]["visible"])
        self.call("test.move", {"x": 1400, "y": 50})
        bs.wait_until(lambda: self.full()["exitControl"]["visible"], what="the ⤡")
        control = self.full()["exitControl"]
        self.assertEqual(control["label"], "Exit Full Window")
        self.assertLessEqual(control["frame"]["x"] + control["frame"]["w"], 1440)
        self.assertIn("Exit Full Window", self.ax_labels())
        self.call("test.click", {"target": "exitFullWindow"})
        self.wait_level("focused")
        self.assert_card_is_page()
        self.call("test.move", {"x": 20, "y": 500})
        bs.wait_until(lambda: not self.full()["exitControl"]["visible"], what="the ⤡ gone")
        self.unchanged(page, before, requests, browsers)

    def test_the_exit_control_stays_away_unless_the_pointer_is_at_the_top_right(self):
        """VAL-VIEW-004"""
        self.three_pages(seed_third=False)
        self.enter_with_key()
        for point in ({"x": 700, "y": 450}, {"x": 20, "y": 20}, {"x": 1400, "y": 500}):
            self.call("test.move", point)
            time.sleep(0.25)
            self.assertFalse(self.full()["exitControl"]["visible"], point)

    def test_escape_in_full_window_reaches_the_page(self):
        """VAL-VIEW-004"""
        tabs = self.three_pages(seed_third=False)
        self.enter_with_key()
        self.assertEqual(self.evaluate("window.__escapes", tabs[2]), 0)
        self.key("Escape")
        time.sleep(0.3)
        self.assertEqual(self.level(), "full-window")
        self.assertFalse(self.ui()["launcher"]["open"])
        bs.wait_until(lambda: self.evaluate("window.__escapes", tabs[2]) == 1,
                      what="one Escape keydown in the page")

    def test_tab_switching_and_closing_keep_full_window(self):
        """VAL-VIEW-006"""
        tabs = self.pages(4)
        self.row(tabs)
        for i, tab in enumerate(tabs):
            self.seed(tab, f"v{i}", 100 * (i + 1))
        self.focus(tabs[0])
        self.show_page()
        self.enter_with_key()
        live = self.assert_fills(tabs[0])
        browsers, requests = self.ui()["cefBrowserCount"], self.requests()
        docs = {t: self.document(t) for t in tabs}
        keys = self.evaluate("window.__keys", tabs[1])
        self.key("2", "cmd")
        bs.wait_until(lambda: self.active_id() == tabs[1], what="page 2")
        self.assertEqual(self.level(), "full-window")
        self.assertEqual(self.assert_fills(tabs[1]), live)
        self.assertEqual(self.document(tabs[1]), docs[tabs[1]])
        self.key("9", "cmd")
        bs.wait_until(lambda: self.active_id() == tabs[3], what="page 4")
        self.assertEqual(self.level(), "full-window")
        order = []
        for step, mods in ((1, ["ctrl"]), (2, ["ctrl"]), (3, ["ctrl"]), (4, ["ctrl", "shift"])):
            self.call("test.key", {"key": "Tab", "modifiers": mods})
            time.sleep(0.2)
            order.append((self.active_id(), self.level()))
        self.assertEqual([t for t, _ in order[:3]], [tabs[0], tabs[1], tabs[2]])
        self.assertEqual(order[3][0], tabs[1])
        self.assertEqual({lvl for _, lvl in order}, {"full-window"})
        self.assertEqual(self.evaluate("window.__keys", tabs[1]), keys)
        self.assertEqual(self.ui()["cefBrowserCount"], browsers)
        self.assertEqual(self.requests(), requests)
        self.assertEqual({t: self.document(t) for t in tabs}, docs)

        self.call("test.activateTab", {"tabId": tabs[2]})
        bs.wait_until(lambda: self.level() == "full-window" and self.active_id() == tabs[2],
                      what="page 3 in full window")
        self.key("w", "cmd")
        bs.wait_until(lambda: len(self.tab_ids()) == 3, what="one fewer page")
        self.assertEqual(self.level(), "full-window")
        self.assertIn(self.active_id(), tabs)
        shown = self.active_id()
        self.assertEqual(self.document(shown), docs[shown])
        for _ in range(2):
            self.key("w", "cmd")
            time.sleep(0.3)
        self.assertEqual(self.level(), "full-window")
        self.key("w", "cmd")
        self.wait_level("overview")
        self.assertEqual(self.tab_ids() and [t for t in self.tab_ids() if t in tabs], [])
        self.assertEqual(self.canvas()["nodes"], [n for n in self.canvas()["nodes"]
                                                  if n["kind"] == "archived"])

    def seed(self, tab, value, y):
        self.evaluate(f"document.getElementById('box').value = {value!r}; window.scrollTo(0, {y})",
                      tab)
        bs.wait_until(lambda: self.evaluate("window.scrollY", tab) == y, what="scrolled")


class FullScreenTests(FullWindowCase):
    def full_screen(self):
        return self.ui()["window"]["fullScreen"]

    def wait_full_screen(self, wanted):
        bs.wait_until(self.screen_is(wanted), timeout=15, what=f"full screen {wanted}")
        time.sleep(1.2)

    def screen_is(self, wanted):
        return lambda: self.full_screen() == wanted and self.ui()["windowOnScreen"] is not None

    def test_native_full_screen_covers_the_display_and_relayout_never_reloads(self):
        """VAL-VIEW-007"""
        tabs = self.three_pages()
        page = tabs[2]
        self.enter_with_key()
        before = self.document(page)
        requests, browsers = self.requests(), self.ui()["cefBrowserCount"]
        frame = self.ui()["windowFrame"]
        report = {}
        for how in ("key", "menu", "button"):
            if how == "key":
                self.key("f", "cmd", "ctrl")
            elif how == "menu":
                self.call("test.menu", {"invoke": "Enter Full Screen"})
            else:
                zoom = self.ui()["window"]["trafficLights"]["zoom"]
                self.call("test.click", {"target": "root", "x": zoom["x"] + zoom["w"] / 2,
                                         "y": zoom["y"] + zoom["h"] / 2})
            self.wait_full_screen(True)
            state = self.ui()
            window = state["window"]
            self.assertTrue(window["onActiveSpace"])
            self.assertEqual(self.level(), "full-window")
            self.assertEqual(state["fullWindow"]["titleBarInset"], 0)
            live = next(t for t in state["tabs"] if t["id"] == page)["frame"]
            screen = window["screen"]
            for axis, wanted in (("x", 0), ("y", 0), ("w", screen["w"]), ("h", screen["h"])):
                self.assertAlmostEqual(live[axis], wanted, delta=1, msg=f"{how} {axis} {live}")
            self.assertEqual({k: v for k, v in state["fullWindow"]["visibleArea"].items() if v}, {})
            report[how] = {"live": live, "window": window}
            self.call("test.menu", {"invoke": "Exit Full Screen"})
            self.wait_full_screen(False)
            self.assertEqual(self.level(), "full-window")
            back = self.ui()["windowFrame"]
            for axis in frame:
                self.assertAlmostEqual(back[axis], frame[axis], delta=1, msg=how)
            self.assert_fills(page)
            self.assertEqual(self.document(page), before)
            self.assertEqual(self.requests(), requests)
            self.assertEqual(self.ui()["cefBrowserCount"], browsers)
        save("view-007.json", report)

    def test_a_resize_relayouts_the_page_without_a_reload(self):
        """VAL-VIEW-007"""
        tabs = self.three_pages()
        page = tabs[2]
        self.enter_with_key()
        before = self.document(page)
        requests = self.requests()
        self.evaluate("window.__resizes = 0; addEventListener('resize', () => window.__resizes++)",
                      page)
        self.call("test.windowSize", {"w": 1000, "h": 700})
        bs.wait_until(lambda: self.ui()["windowFrame"]["w"] == 1000, what="resized")
        time.sleep(0.5)
        self.assert_fills(page, 1000, 700)
        self.assertLessEqual(self.evaluate("window.__resizes", page), 2)
        self.assertEqual(self.document(page), before)
        self.assertEqual(self.requests(), requests)


class DiscoverabilityTests(FullWindowCase):
    def test_a_hovered_card_shows_the_pointing_hand_and_an_open_chip(self):
        """VAL-VIEW-008"""
        tabs = self.pages(3)
        self.row(tabs)
        self.focus(tabs[0])
        self.show_overview()
        card = self.node_of(tabs[1])["id"]
        self.assertFalse(self.full()["chip"]["visible"])
        self.call("test.move", {"target": f"node:{card}"})
        bs.wait_until(lambda: self.full()["chip"]["visible"], what="the Open chip")
        full = self.full()
        self.assertEqual((full["cursor"], full["chip"]["text"], full["chip"]["node"]),
                         ("pointing-hand", "Open", card))
        labels = []

        def walk(nodes):
            for node in nodes:
                labels.append(node)
                walk(node.get("children", []))
        walk(self.call("test.ax"))
        open_button = next(n for n in labels if n.get("label") == "Open")
        self.assertIn("AXPress", open_button["actions"])
        self.call("test.move", {"x": 700, "y": 850})
        bs.wait_until(lambda: not self.full()["chip"]["visible"], what="the chip gone")
        self.assertEqual(self.full()["cursor"], "open-hand")

    def test_the_first_empty_canvas_shows_one_hint_once(self):
        """VAL-VIEW-008"""
        full = self.full()
        text = "click to open · double-click for full window · pinch out or ⌘⇧\\ for the overview"
        self.assertTrue(full["hint"]["visible"])
        self.assertEqual(full["hint"]["text"], text)
        self.assertTrue(os.path.exists(os.path.join(self.data_dir, "first-run-hint")))
        hint, button = full["hint"]["frame"], self.ui()["commandButton"]["frame"]
        self.assertTrue(hint["y"] + hint["h"] <= button["y"] or hint["y"] >= button["y"] + button["h"]
                        or hint["x"] + hint["w"] <= button["x"] or hint["x"] >= button["x"] + button["w"])
        self.assertGreaterEqual(hint["x"], 0)
        self.assertLessEqual(hint["x"] + hint["w"], 1440)
        self.open_page("Hint page")
        bs.wait_until(lambda: not self.full()["hint"]["visible"], what="the hint to go")
        self.launch(fresh=False)
        self.assertFalse(self.full()["hint"]["visible"])
        self.assertEqual(self.full()["hint"]["text"], "")
        self.assertTrue(os.path.exists(os.path.join(self.data_dir, "first-run-hint")))


class EmptyClickTests(FullWindowCase):
    def test_a_click_beside_the_focused_page_returns_to_the_overview(self):
        """VAL-VIEW-014"""
        opener = self.open_page("Opener", "popups.html")
        self.popups(opener, 2)
        self.assertEqual(self.active_id(), opener)
        self.show_page()
        focus = self.focus_state()
        neighbours = focus["left"] + focus["right"]
        self.assertEqual(len(neighbours), 2)
        requests, browsers = self.requests(), self.ui()["cefBrowserCount"]
        before = self.document(opener)
        selection = self.ui()["overview"]["selection"]

        self.call("test.click", {"target": opener, "x": 300, "y": 300})
        time.sleep(0.4)
        self.assertEqual(self.level(), "focused")

        spot = self.empty_point(focus["card"], neighbours)
        self.call("test.click", {"target": "root", "x": spot[0], "y": spot[1]})
        self.wait_level("overview")
        self.assertEqual(self.ui()["overview"]["selection"], selection)
        self.assertEqual(self.document(opener), before)
        self.assertEqual(self.requests(), requests)
        self.assertEqual(self.ui()["cefBrowserCount"], browsers)

        self.activate(opener, "focused")
        neighbour = (self.focus_state()["left"] + self.focus_state()["right"])[0]
        self.call("test.click", {"target": f"node:{neighbour['id']}"})
        bs.wait_until(lambda: self.active_id() != opener, what="the neighbour focused")
        self.assertEqual(self.level(), "focused")

    def empty_point(self, card, neighbours):
        """A point on bare window: 40 pt from the card, its neighbours, the caption and the button."""
        ui = self.ui()
        size = ui["focus"]["size"]
        rects = [card, ui["focus"]["caption"], ui["commandButton"]["frame"]]
        rects += [n["frame"] for n in neighbours]
        for fraction_x, offset_y in ((0.9, 25), (0.1, 25), (0.9, 70), (0.1, 70), (0.9, 150)):
            x, y = size["w"] * fraction_x, size["h"] - offset_y
            if all(self.far(x, y, r) for r in rects):
                return x, y
        self.fail(f"no empty point beside {rects}")

    @staticmethod
    def far(x, y, rect, gap=40):
        return (x < rect["x"] - gap or x > rect["x"] + rect["w"] + gap
                or y < rect["y"] - gap or y > rect["y"] + rect["h"] + gap)

    def test_a_click_on_the_caption_stays_on_the_page(self):
        """VAL-VIEW-014"""
        self.three_pages(seed_third=False)
        caption = self.ui()["focus"]["caption"]
        self.call("test.click", {"target": "root", "x": caption["x"] + 40,
                                 "y": caption["y"] + caption["h"] / 2})
        time.sleep(0.4)
        self.assertEqual(self.level(), "focused")

    def test_the_same_click_returns_to_the_overview_in_a_narrow_window(self):
        """VAL-VIEW-014"""
        opener = self.open_page("Opener", "popups.html")
        self.popups(opener, 2)
        self.show_page()
        self.call("test.windowSize", {"w": 720, "h": 600})
        time.sleep(0.4)
        focus = self.focus_state()
        spot = self.empty_point(focus["card"], focus["left"] + focus["right"])
        self.call("test.click", {"target": "root", "x": spot[0], "y": spot[1]})
        self.wait_level("overview")


class MotionTests(FullWindowCase):
    def run_both(self):
        tabs = self.three_pages(seed_third=False)
        self.settle()
        return tabs

    def test_enter_and_leave_run_one_camera_animation_that_ends_exactly(self):
        """VAL-VIEW-009"""
        tabs = self.run_both()
        self.call("test.reduceMotion", {"on": False})
        report = {}
        for name, key, wanted in (("enter", None, "full-window"), ("leave", None, "focused")):
            items, samples = self.transition(lambda: self.key("Return", "cmd"))
            self.wait_level(wanted)
            self.assertEqual([i["purpose"] for i in items], ["camera"], (name, items))
            item = items[0]
            self.assertLessEqual(item["durationMs"], 450)
            self.assertTrue(item["curve"] == "easeOut" or item["bounce"] <= 0.2, item)
            self.assertEqual(self.motion()["inFlight"], [])
            rects = [x["camera"]["rect"] for x in samples if x["camera"]["rect"]]
            self.assertGreaterEqual(len(rects), 2, (name, "the flying page was sampled"))
            steps = [max(abs(q[k] - r[k]) for k in "xywh") for q, r in zip(rects, rects[1:])]
            total = max(max(abs(rects[0][k] - rects[-1][k]) for k in "xywh"), 1)
            self.assertLess(max(steps), total * 0.6, (name, "no jump", steps))
            report[name] = {"item": item, "samples": len(samples), "steps": steps}
            if wanted == "full-window":
                self.assert_fills(tabs[2])
            else:
                self.assert_card_is_page()
        time.sleep(1.0)
        self.assertEqual(self.motion()["inFlight"], [])
        self.assertEqual(self.motion()["infiniteLoops"], [])
        save("view-009-motion.json", report)

    def test_reduce_motion_makes_the_change_opacity_only_or_instant(self):
        """VAL-VIEW-009"""
        tabs = self.run_both()
        self.call("test.reduceMotion", {"on": True})
        for wanted in ("full-window", "focused"):
            items, samples = self.transition(lambda: self.key("Return", "cmd"), limit=1.0)
            self.wait_level(wanted)
            self.assertNotIn("camera", [i["purpose"] for i in items])
            for item in items:
                self.assertLessEqual(item["durationMs"], 120)
                self.assertFalse(item["transformChanged"], item)
            for state in samples:
                self.assertEqual(state["camera"]["layer"], None)
            if wanted == "full-window":
                self.assert_fills(tabs[2])
            else:
                self.assert_card_is_page()
        self.call("test.reduceMotion", {"on": False})


class ApprovalTests(PermBase):
    """The approval card in Full window, at two window sizes (VAL-VIEW-005)."""

    def tearDown(self):
        self.app.call("test.windowSize", {"w": 1440, "h": 900})
        if self.ui()["presentation"] == "full-window":
            self.app.call("test.key", {"key": "Return", "modifiers": ["cmd"]})

    def level(self):
        return self.ui()["presentation"]

    def reached_by_tab(self):
        """The card's buttons among the controls Tab walks to from the page's own field."""
        self.app.call("test.activateTab", {"tabId": self.tab})
        self.devtools("Runtime.evaluate", {"expression": "document.getElementById('secret').focus()"})
        bs.wait_until(lambda: self.ui()["firstResponder"].get("tabId") == self.tab,
                      what="the page focused")
        seen = []
        for _ in range(2):
            before = seen[-1:]
            self.app.call("test.key", {"key": "Tab"})
            seen.append(bs.wait_until(
                lambda: (lambda r: r if r and [r] != before else None)(
                    self.ui()["firstResponder"].get("chromeId")),
                what="the next control"))
        return set(seen)

    def test_the_card_sits_inside_the_window_and_both_buttons_work(self):
        """VAL-VIEW-005"""
        self.grant()
        self.app.call("test.key", {"key": "Return", "modifiers": ["cmd"]})
        bs.wait_until(lambda: self.level() == "full-window", what="full window")
        # Allow acts on the page once; the narrow size can only be denied again.
        for size, verdicts in (((1440, 900), ("Deny", "Allow")), ((720, 600), ("Deny", "Deny"))):
            self.app.call("test.windowSize", {"w": size[0], "h": size[1]})
            time.sleep(0.3)
            for turn, verdict in enumerate(verdicts):
                _, row = self.quote(f"fw-{size[0]}-{turn}", "Delete draft")
                card = self.wait_card()
                self.assertTrue(card["insideWindow"], (size, card["frame"]))
                for button in ("allow", "deny"):
                    frame = card[button]["frame"]
                    self.assertTrue(card[button]["hittable"], (size, button))
                    self.assertLessEqual(frame["x"] + frame["w"], size[0])
                    self.assertLessEqual(frame["y"] + frame["h"], size[1])
                self.assertEqual(self.level(), "full-window")
                if turn == 0:
                    self.assertTrue(self.ui()["approval"]["visible"])
                    self.assertEqual(self.reached_by_tab(), {"approvalAllow", "approvalDeny"})
                self.app.call("test.click", {"target": f"approval{verdict}"})
                final = self.settled(row)
                self.assertEqual(final["state"], "cancelled" if verdict == "Deny" else "confirmed", final)
                bs.wait_until(lambda: not self.ui()["approval"]["visible"], what="the card to leave")
                self.assertEqual(self.level(), "full-window")


class UsabilityTests(TaskCase):
    """The launcher, find bar, activity view and takeover keep working in Full window."""

    def level(self):
        return self.ui()["presentation"]

    def enter(self):
        page = self.open_page("launcher.html")
        self.key("Return", "cmd")
        bs.wait_until(lambda: self.level() == "full-window", what="full window")
        return page

    def inside(self, frame, bounds):
        self.assertGreaterEqual(frame["x"], -1)
        self.assertGreaterEqual(frame["y"], -1)
        self.assertLessEqual(frame["x"] + frame["w"], bounds["w"] + 1)
        self.assertLessEqual(frame["y"] + frame["h"], bounds["h"] + 1)

    def test_launcher_find_and_activity_work_in_full_window(self):
        """VAL-VIEW-005"""
        page = self.enter()
        size = self.ui()["windowFrame"]
        self.open_launcher()
        self.assertEqual(self.ui()["firstResponder"]["chromeId"], "launcherField")
        self.inside(self.ui()["launcher"]["frame"], size)
        self.close_launcher()
        self.assertEqual(self.level(), "full-window")

        before = self.requests_count()
        self.key("f", "cmd")
        bs.wait_until(lambda: self.chrome()["find"]["open"], what="the find bar")
        find = self.chrome()["find"]
        self.assertTrue(find["focused"])
        live = next(t for t in self.ui()["tabs"] if t["id"] == page["id"])["frame"]
        for edge in ("x", "y"):
            self.assertGreaterEqual(find["frame"][edge], live[edge])
        self.assertLessEqual(find["frame"]["x"] + find["frame"]["w"], live["x"] + live["w"])
        self.assertLessEqual(find["frame"]["y"] + find["frame"]["h"], live["y"] + live["h"])
        self.call("test.type", {"text": "Launcher"})
        bs.wait_until(lambda: self.chrome()["find"]["matches"] > 0, what="matches")
        self.key("Escape")
        self.assertEqual(self.level(), "full-window")
        self.assertEqual(self.requests_count(), before)

        run = self.start("Read this page", tab=page["id"])
        self.open_activity()
        view = self.activity()
        self.assertEqual(view["runId"], run["runId"])
        self.inside(view["frame"], size)
        self.close_activity()
        self.assertEqual(self.level(), "full-window")

        self.call("test.click", {"target": page["id"]})
        self.call("test.type", {"text": "x"})
        stopped = bs.wait_until(lambda: (lambda r: r if r["state"] == "stopped" else None)(
            self.run_of(run["runId"])), timeout=5, what="the takeover to stop the run")
        self.assertEqual(stopped["state"], "stopped")
        self.assertEqual(self.level(), "full-window")

    def requests_count(self):
        return len(self.fixtures.log())
