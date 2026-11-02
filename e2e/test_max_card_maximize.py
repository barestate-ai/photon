"""Maximize a page straight from its card: the ⤢ control on a hovered, selected or neighbour card,
the morph out of the card and back, the right-click menu, and the labels (VAL-MAX-001..006).

Values come from `test.ui` (`maximize`, `cardMenu`, `fullWindow`, `overview`, `focus`), `test.motion`,
`test.canvas`, `test.ax` and the fixture log."""
import time

import bs
from appcase import save
from test_view_full_window import FullWindowCase

EMPTY = {"x": 720, "y": 760}
MENU_TITLES = ["Open", "Maximize", "Close Page"]
SESSION = "menu-dismiss"
PAGE_POINT = {"x": 400, "y": 400}


def rect_distance(a, b):
    return max(abs(a[k] - b[k]) for k in "xywh")


def intersects(a, b):
    return not (a["x"] + a["w"] <= b["x"] or b["x"] + b["w"] <= a["x"]
                or a["y"] + a["h"] <= b["y"] or b["y"] + b["h"] <= a["y"])


class MaxCase(FullWindowCase):
    def five(self, count=5):
        tabs = self.pages(count)
        self.row(tabs)
        self.focus(tabs[0])
        self.show_overview()
        self.key("0", "cmd")
        self.settle()
        return tabs

    def card(self, tab):
        node = self.node_of(tab)["id"]
        frame = next(n["frame"] for n in self.ui()["overview"]["nodes"] if n["id"] == node)
        return node, frame

    def positions(self):
        return {n["id"]: (n["x"], n["y"]) for n in self.nodes()}

    def controls(self):
        return self.ui()["maximize"]

    def park(self):
        self.call("test.move", EMPTY)
        bs.wait_until(lambda: not self.controls(), what="every ⤢ gone")

    def hover(self, node):
        self.call("test.move", {"target": f"node:{node}"})
        return bs.wait_until(
            lambda: next((c for c in self.controls() if c["node"] == node), None),
            what=f"the ⤢ on {node}")

    def labels(self):
        found = []

        def walk(nodes):
            for item in nodes:
                found.append(item)
                walk(item.get("children", []))
        walk(self.call("test.ax"))
        return found

    def baseline(self, tab):
        return self.document(tab), self.requests(), self.ui()["cefBrowserCount"], len(self.tabs())

    def assert_unchanged(self, tab, before):
        document, requests, browsers, tabs = before
        self.assertEqual(self.document(tab), document)
        self.assertEqual(self.requests(), requests)
        self.assertEqual(self.ui()["cefBrowserCount"], browsers)
        self.assertEqual(len(self.tabs()), tabs)

    def rects_of_flight(self, action, limit=3.0):
        """The flying page's rect and the canvas viewport at every sample, until all rests."""
        action()
        flight, moved, end = [], False, time.time() + limit
        while time.time() < end:
            motion = self.motion()
            flight.append((motion, self.canvas()["viewport"], self.ui()["zoomPill"]))
            moved = moved or bool(motion["inFlight"]) or motion["camera"]["phase"] != "idle"
            if moved and motion["camera"]["phase"] == "idle" and not motion["inFlight"]:
                break
        return flight


class ControlTests(MaxCase):
    def test_a_hovered_card_shows_the_control_beside_open_and_the_click_goes_to_full_window(self):
        """VAL-MAX-001"""
        tabs = self.five()
        page = tabs[1]
        node, card = self.card(page)
        self.seed_page(page)
        before = self.baseline(page)
        positions = self.positions()
        viewport = self.canvas()["viewport"]

        self.park()
        self.assertEqual(self.controls(), [])
        self.assertNotIn(f"Maximize Page 2", [i.get("label") for i in self.labels()])
        control = self.hover(node)
        self.assertEqual(control["label"], "Maximize Page 2")
        self.assertGreater(control["area"], 0)
        chip = self.full()["chip"]
        self.assertTrue(chip["visible"])
        self.assertFalse(intersects(control["frame"], chip["frame"]), (control, chip))
        inside = (control["frame"]["x"] >= card["x"]
                  and control["frame"]["y"] >= card["y"]
                  and control["frame"]["x"] + control["frame"]["w"] <= card["x"] + card["w"]
                  and control["frame"]["y"] + control["frame"]["h"] <= card["y"] + card["h"])
        self.assertTrue(inside, "the control stays on the card, clear of the title below it")
        ax = next(i for i in self.labels() if i.get("label") == "Maximize Page 2")
        self.assertIn("AXPress", ax["actions"])
        self.assertEqual([c["node"] for c in self.controls()], [node])

        self.call("test.click", {"target": f"maximize:{node}"})
        levels = set()
        end = time.time() + 1.0
        while time.time() < end:
            levels.add(self.level())
            self.assertEqual(self.active_id(), page)
            time.sleep(0.016)
        self.assertEqual(levels - {"overview"}, {"full-window"}, levels)
        self.wait_level("full-window")
        self.assert_fills(page)
        self.assert_unchanged(page, before)
        self.assertEqual(self.positions(), positions)
        self.assertEqual(self.canvas()["viewport"], viewport)

    def test_a_click_elsewhere_on_the_card_still_only_focuses(self):
        """VAL-MAX-001"""
        tabs = self.five(3)
        node, _ = self.card(tabs[1])
        self.hover(node)
        self.call("test.click", {"target": f"node:{node}"})
        self.wait_level("focused")
        self.assertEqual(self.active_id(), tabs[1])

    def test_a_neighbour_card_in_the_focused_view_has_the_control_too(self):
        """VAL-MAX-001"""
        opener = self.open_page("Opener", "popups.html")
        self.popups(opener, 2)
        self.show_page()
        neighbour = (self.focus_state()["left"] + self.focus_state()["right"])[0]
        tab = self.nodes_tab(neighbour["id"])
        self.seed_page(tab)
        before = self.baseline(tab)
        self.call("test.move", EMPTY)
        self.assertEqual(self.controls(), [])
        self.call("test.move", {"target": f"node:{neighbour['id']}"})
        control = bs.wait_until(lambda: next(iter(self.controls()), None), what="the ⤢")
        self.assertEqual(control["node"], neighbour["id"])
        self.assertEqual(control["where"], "focus")
        self.call("test.click", {"target": f"maximize:{neighbour['id']}"})
        self.wait_level("full-window")
        self.assertEqual(self.active_id(), tab)
        self.assert_unchanged(tab, before)
        self.assert_fills(tab)


class KeyboardTests(MaxCase):
    def test_the_selected_card_shows_the_control_without_the_pointer_and_return_presses_it(self):
        """VAL-MAX-005"""
        tabs = self.five()
        self.park()
        self.key("ArrowRight")
        self.key("ArrowRight")
        node = self.ui()["overview"]["selection"]
        self.assertIn(node, [n["id"] for n in self.nodes()])
        bs.wait_until(lambda: [c["node"] for c in self.controls()] == [node], what="the selected ⤢")
        page = self.nodes_tab(node)
        control = self.controls()[0]
        self.assertGreater(control["area"], 0)
        self.assertEqual(control["label"], f"Maximize {self.node_title(node)}")
        before = self.baseline(page)

        for _ in range(12):
            if self.ui()["firstResponder"].get("chromeId") == f"maximize:{node}":
                break
            self.key("Tab")
        self.wait_responder(chromeId=f"maximize:{node}")
        self.key("Space")
        self.wait_level("full-window")
        self.assertEqual(self.active_id(), page)
        self.assert_unchanged(page, before)

        self.key("Return", "cmd")
        self.wait_level("overview")
        self.settle()
        self.call("test.move", EMPTY)
        self.key("ArrowLeft")
        node = self.ui()["overview"]["selection"]
        page = self.nodes_tab(node)
        self.key("Return", "cmd")
        self.wait_level("full-window")
        self.assertEqual(self.active_id(), page)

    def node_title(self, node):
        return next(n["title"] for n in self.ui()["overview"]["nodes"] if n["id"] == node)

    def test_ax_press_maximizes_that_card(self):
        """VAL-MAX-005"""
        tabs = self.five()
        page = tabs[2]
        node, _ = self.card(page)
        before = self.baseline(page)
        self.hover(node)
        press = next(i for i in self.labels() if i.get("label") == "Maximize Page 3")
        self.assertIn("AXPress", press["actions"])
        self.call("test.ax", {"press": "Maximize Page 3"})
        self.wait_level("full-window")
        self.assertEqual(self.active_id(), page)
        self.assert_unchanged(page, before)


class MorphTests(MaxCase):
    def prepare(self):
        tabs = self.five()
        self.call("test.canvas", {"viewport": {"cx": 150, "cy": 30, "zoom": 0.8}})
        self.settle()
        node, card = self.card(tabs[1])
        self.hover(node)
        return tabs, node, card

    def test_maximize_grows_the_page_out_of_its_card_and_the_canvas_never_moves(self):
        """VAL-MAX-002"""
        tabs, node, card = self.prepare()
        self.call("test.reduceMotion", {"on": False})
        viewport = self.canvas()["viewport"]
        started = time.time()
        flight = self.rects_of_flight(lambda: self.call("test.click", {"target": f"maximize:{node}"}))
        self.wait_level("full-window")
        final = self.assert_fills(tabs[1])
        rects = [m["camera"]["rect"] for m, _, _ in flight if m["camera"]["rect"]]
        self.assertGreaterEqual(len(rects), 3, "the flying page was sampled")
        total = max(rect_distance(card, final), 1)
        self.assertLess(rect_distance(rects[0], card), total * 0.6, "it starts at the card")
        distances = [rect_distance(r, final) for r in rects]
        for before, after in zip(distances, distances[1:]):
            self.assertLessEqual(after, before + 1, "never back toward the card")
        steps = [rect_distance(a, b) for a, b in zip(rects, rects[1:])]
        self.assertLess(max(steps), total * 0.4, steps)
        items = {i["id"]: i for m, _, _ in flight for i in m["inFlight"] + m["recent"]
                 if i["startedAtMs"] >= started * 1000 - 50}
        cameras = [i for i in items.values() if i["purpose"] == "camera" and not i["interrupted"]]
        self.assertEqual(len(cameras), 1, cameras)
        self.assertLessEqual(cameras[0]["durationMs"], 450)
        for _, view, pill in flight:
            for axis in ("cx", "cy"):
                self.assertAlmostEqual(view[axis], viewport[axis], delta=1e-6)
            self.assertAlmostEqual(view["zoom"], viewport["zoom"], delta=0.001)
            self.assertIsNone(pill, "the zoom pill is gone from the first sample")
        self.assertEqual(self.motion()["inFlight"], [])
        time.sleep(1.0)
        self.assertEqual(self.motion()["inFlight"], [])
        save("max-002.json", {"card": card, "final": final, "samples": len(rects)})

    def test_reduce_motion_maximizes_with_opacity_only_or_at_once(self):
        """VAL-MAX-002"""
        tabs, node, card = self.prepare()
        self.call("test.reduceMotion", {"on": True})
        started = time.time()
        flight = self.rects_of_flight(
            lambda: self.call("test.click", {"target": f"maximize:{node}"}), limit=1.0)
        self.wait_level("full-window")
        self.assertLess(time.time() - started, 1.0)
        items = {i["id"]: i for m, _, _ in flight for i in m["inFlight"] + m["recent"]
                 if i["startedAtMs"] >= started * 1000 - 50}
        self.assertNotIn("camera", [i["purpose"] for i in items.values()])
        for item in items.values():
            self.assertLessEqual(item["durationMs"], 120)
            self.assertFalse(item["transformChanged"], item)
        final = self.assert_fills(tabs[1])
        for motion, _, _ in flight:
            rect = motion["camera"]["rect"]
            self.assertTrue(rect is None or rect_distance(rect, final) <= 1, rect)
        self.call("test.reduceMotion", {"on": False})


class RestoreTests(MaxCase):
    def test_every_restore_route_returns_to_the_overview_with_the_same_view(self):
        """VAL-MAX-003"""
        tabs = self.five()
        self.call("test.drag", {"target": "canvas", "x": 700, "y": 700, "dx": -60, "dy": -25,
                                "steps": 4})
        self.call("test.canvas", {"viewport": {"zoom": 0.8}})
        self.settle()
        page = tabs[1]
        node, card = self.card(page)
        self.seed_page(page)
        before = self.baseline(page)
        viewport = self.canvas()["viewport"]
        self.call("test.reduceMotion", {"on": False})
        report = {}
        for route in ("control", "key", "menu"):
            self.hover(node)
            self.call("test.click", {"target": f"maximize:{node}"})
            self.wait_level("full-window")
            self.settle()
            if route == "control":
                self.call("test.move", {"x": 1400, "y": 50})
                bs.wait_until(lambda: self.full()["exitControl"]["visible"], what="the ⤡")
                self.assertEqual(self.full()["exitControl"]["label"], "Exit Full Window")
                act = lambda: self.call("test.click", {"target": "exitFullWindow"})
            elif route == "key":
                act = lambda: self.key("Return", "cmd")
            else:
                act = lambda: self.call("test.menu", {"invoke": "Exit Full Window"})
            flight = self.rects_of_flight(act)
            self.wait_level("overview")
            self.settle()
            now = self.canvas()["viewport"]
            for axis in ("cx", "cy"):
                self.assertAlmostEqual(now[axis], viewport[axis], delta=1)
            self.assertAlmostEqual(now["zoom"], viewport["zoom"], delta=0.001)
            self.assertEqual(self.card(page)[1], card)
            rects = [m["camera"]["rect"] for m, _, _ in flight if m["camera"]["rect"]]
            self.assertGreaterEqual(len(rects), 2, route)
            distances = [rect_distance(r, card) for r in rects]
            self.assertLess(distances[-1], rect_distance(rects[0], card) * 0.25, (route, distances))
            self.assertLess(rects[-1]["w"], 1440 / 2, "it shrank onto the card, not the window")
            self.assert_unchanged(page, before)
            report[route] = {"samples": len(rects), "last": rects[-1]}
        save("max-003.json", report)

    def test_maximized_from_the_focused_view_restores_to_the_focused_view(self):
        """VAL-MAX-003"""
        opener = self.open_page("Opener", "popups.html")
        self.popups(opener, 2)
        self.show_page()
        neighbour = (self.focus_state()["left"] + self.focus_state()["right"])[0]
        tab = self.nodes_tab(neighbour["id"])
        for route in ("key", "control", "menu"):
            self.call("test.move", {"target": f"node:{neighbour['id']}"})
            bs.wait_until(lambda: self.controls(), what="the ⤢")
            self.call("test.click", {"target": f"maximize:{neighbour['id']}"})
            self.wait_level("full-window")
            if route == "key":
                self.key("Return", "cmd")
            elif route == "control":
                self.call("test.move", {"x": 1400, "y": 50})
                bs.wait_until(lambda: self.full()["exitControl"]["visible"], what="the ⤡")
                self.call("test.click", {"target": "exitFullWindow"})
            else:
                self.call("test.menu", {"invoke": "Exit Full Window"})
            self.wait_level("focused")
            self.assertEqual(self.active_id(), tab)
            self.assert_card_is_page()
            neighbour = (self.focus_state()["left"] + self.focus_state()["right"])[0]
            if self.nodes_tab(neighbour["id"]) == tab:
                neighbour = (self.focus_state()["left"] + self.focus_state()["right"])[0]
            tab = self.nodes_tab(neighbour["id"])

    def test_pinch_and_the_overview_key_keep_their_meaning_after_a_card_maximize(self):
        """VAL-MAX-003"""
        tabs = self.five(3)
        page = tabs[1]
        node, _ = self.card(page)
        seeded = self.seed_page(page)
        before = self.baseline(page)
        self.hover(node)
        self.call("test.click", {"target": f"maximize:{node}"})
        self.wait_level("full-window")
        self.call("test.magnify", {"by": -0.5})
        self.wait_level("focused")
        self.assertEqual(self.active_id(), page)
        self.show_overview()
        self.hover(node)
        self.call("test.click", {"target": f"maximize:{node}"})
        self.wait_level("full-window")
        self.key("\\", "cmd", "shift")
        self.wait_level("overview")
        self.assert_unchanged(page, before)


class MenuTests(MaxCase):
    def card_menu(self):
        return self.ui()["cardMenu"]

    def open_menu(self, node):
        self.call("test.click", {"target": f"node:{node}", "button": "right"})
        return bs.wait_until(lambda: self.card_menu() if self.card_menu()["open"] else None, what="the menu")

    def test_a_right_click_offers_open_maximize_and_close_page_inside_the_window(self):
        """VAL-MAX-004"""
        tabs = self.five()
        for size in ((1440, 900), (720, 600)):
            self.call("test.windowSize", {"w": size[0], "h": size[1]})
            time.sleep(0.3)
            self.settle()
            self.key("0", "cmd")
            self.settle()
            for tab in (tabs[0], tabs[-1]):
                node, _ = self.card(tab)
                menu = self.open_menu(node)
                self.assertEqual(menu["node"], node)
                self.assertEqual([i["title"] for i in menu["items"]], MENU_TITLES)
                frame = menu["frame"]
                self.assertGreaterEqual(frame["x"], 0)
                self.assertGreaterEqual(frame["y"], 0)
                self.assertLessEqual(frame["x"] + frame["w"], size[0])
                self.assertLessEqual(frame["y"] + frame["h"], size[1])
                labels = {i.get("label"): i for i in self.labels()}
                for title in MENU_TITLES:
                    self.assertIn("AXPress", labels[title]["actions"])
                self.key("Escape")
                bs.wait_until(lambda: not self.card_menu()["open"], what="the menu closed")
        self.call("test.windowSize", {"w": 1440, "h": 900})

    def test_empty_canvas_opens_no_menu_and_a_menu_never_acts_on_another_card(self):
        """VAL-MAX-004"""
        tabs = self.five(3)
        first, _ = self.card(tabs[0])
        self.open_menu(first)
        self.call("test.click", {"target": "root", "x": EMPTY["x"], "y": EMPTY["y"],
                                 "button": "right"})
        time.sleep(0.3)
        self.assertFalse(self.card_menu()["open"])
        second, _ = self.card(tabs[1])
        self.open_menu(first)
        self.call("test.click", {"target": f"node:{second}", "button": "right"})
        bs.wait_until(lambda: self.card_menu()["node"] == second, what="the second card's menu")
        self.call("test.click", {"target": "cardMenu:Maximize"})
        self.wait_level("full-window")
        self.assertEqual(self.active_id(), tabs[1])

    def test_each_choice_does_what_its_button_and_click_equivalent_does(self):
        """VAL-MAX-004"""
        tabs = self.five()
        page = tabs[2]
        node, _ = self.card(page)
        before = self.baseline(page)
        self.open_menu(node)
        self.call("test.click", {"target": "cardMenu:Maximize"})
        self.wait_level("full-window")
        self.assertEqual(self.active_id(), page)
        self.assert_unchanged(page, before)
        self.key("Return", "cmd")
        self.wait_level("overview")
        self.settle()

        self.open_menu(node)
        self.call("test.click", {"target": "cardMenu:Open"})
        self.wait_level("focused")
        self.assertEqual(self.active_id(), page)
        self.assert_unchanged(page, before)
        self.show_overview()
        self.settle()

        victim = tabs[4]
        victim_node, _ = self.card(victim)
        others = {t: self.document(t) for t in tabs if t != victim}
        requests = self.requests()
        browsers = self.ui()["cefBrowserCount"]
        self.open_menu(victim_node)
        self.call("test.click", {"target": "cardMenu:Close Page"})
        bs.wait_until(lambda: victim not in self.tab_ids(), what="the page closed")
        self.assertEqual(len(self.tabs()), 4)
        self.assertEqual(self.requests(), requests)
        bs.wait_until(lambda: self.ui()["cefBrowserCount"] == browsers - 1, what="the browser gone")
        subtitle = next(n["subtitle"] for n in self.ui()["overview"]["nodes"]
                        if n["id"] == victim_node)
        self.assertTrue(subtitle.startswith("Closed page"), subtitle)
        for tab, document in others.items():
            self.assertEqual(self.document(tab), document)
        self.assertEqual(self.level(), "overview")

    def test_maximize_on_a_closed_card_reopens_it_into_full_window(self):
        """VAL-MAX-004"""
        tabs = self.five(3)
        victim_node, _ = self.card(tabs[2])
        self.open_menu(victim_node)
        self.call("test.click", {"target": "cardMenu:Close Page"})
        bs.wait_until(lambda: tabs[2] not in self.tab_ids(), what="the page closed")
        self.settle()
        self.hover(victim_node)
        self.call("test.click", {"target": f"maximize:{victim_node}"})
        self.wait_level("full-window")
        self.assert_fills(self.active_id())
        self.key("Return", "cmd")
        self.wait_level("overview")

    def test_a_menu_left_open_closes_when_the_view_changes(self):
        """VAL-MAX-004"""
        tabs = self.five(3)
        node, _ = self.card(tabs[1])
        self.open_menu(node)
        self.key("Return", "cmd")
        self.wait_level("full-window")
        bs.wait_until(lambda: not self.card_menu()["open"], what="the menu closed")

    def test_the_neighbour_card_menu_opens_that_card(self):
        """VAL-MAX-004"""
        opener = self.open_page("Opener", "popups.html")
        self.popups(opener, 2)
        self.show_page()
        neighbour = (self.focus_state()["left"] + self.focus_state()["right"])[0]
        tab = self.nodes_tab(neighbour["id"])
        before = self.baseline(tab)
        self.open_menu(neighbour["id"])
        self.call("test.click", {"target": "cardMenu:Maximize"})
        self.wait_level("full-window")
        self.assertEqual(self.active_id(), tab)
        self.assert_unchanged(tab, before)

    def control(self, tab):
        state = next(t for t in self.ui()["tabs"] if t["id"] == tab)
        return state["epoch"], state["controller"]

    def release(self, tab):
        try:
            self.call("handoff", {"sessionId": SESSION, "tabId": tab})
        except bs.RpcError:
            pass  # the human click already took over

    def downs(self, tab):
        return self.evaluate("window.__downs", tab)

    def test_a_click_that_closes_the_menu_over_a_live_page_never_reaches_it(self):
        """The takeover boundary: a dismissal is consumed like a native menu's, an ordinary
        click still takes over."""
        opener = self.open_page("Opener", "popups.html")
        self.popups(opener, 2)
        self.show_page()
        neighbour = (self.focus_state()["left"] + self.focus_state()["right"])[0]
        granted = self.call("request_control", {"sessionId": SESSION, "tabId": opener})
        if granted["state"] != "granted":
            self.call("control.decide", {"requestId": granted["requestId"], "allow": True})
        self.addCleanup(self.release, opener)
        self.evaluate("window.__downs = 0; addEventListener('mousedown', "
                      "() => { window.__downs += 1 }, true)", opener)
        epoch, controller = self.control(opener)
        self.assertEqual(controller, "agent")
        for button in ("right", "left"):
            self.open_menu(neighbour["id"])
            self.call("test.click", {"target": opener, "button": button, **PAGE_POINT})
            bs.wait_until(lambda: not self.card_menu()["open"], what=f"the menu closed by a {button} click")
            self.assertEqual(self.downs(opener), 0, button)
            self.assertEqual(self.control(opener), (epoch, "agent"), button)
        self.call("test.click", {"target": opener, **PAGE_POINT})
        bs.wait_until(lambda: self.downs(opener) == 1, what="the ordinary click to reach the page")
        self.assertEqual(self.control(opener), (epoch + 1, "human"))


class WordingTests(MaxCase):
    def test_the_hint_names_the_maximize_control(self):
        """VAL-MAX-001"""
        self.assertIn("⤢", self.full()["hint"]["text"])
