"""Mouse and trackpad on the overview: ⌘-scroll zoom, dragging empty canvas, the zoom pill, the card
drag, and the first-use flow across all of it (VAL-VIEW-010..013, VAL-VIEW-015).

Input is synthesized through the documented hooks (`test.scroll`, `test.drag`, `test.click`,
`test.key`); the values come from `test.ui`, `test.motion`, the fixture log and the SQLite file."""
import math
import os
import sqlite3
import time
import unittest

import bs
from appcase import save
from test_graph import titled
from test_view_full_window import FullWindowCase

EMPTY = {"x": 720, "y": 760}
AXES = ("cx", "cy", "zoom")


def centre(frame):
    return frame["x"] + frame["w"] / 2, frame["y"] + frame["h"] / 2


def percent_of(zoom):
    return math.floor(zoom * 100 + 0.5)


class MouseCase(FullWindowCase):
    def overview_of(self, count):
        tabs = self.pages(count)
        self.row(tabs)
        self.focus(tabs[0])
        self.show_overview()
        self.key("0", "cmd")
        self.settle()
        return tabs

    def zoom(self):
        return self.canvas()["viewport"]["zoom"]

    def viewport(self):
        return self.canvas()["viewport"]

    def set_view(self, cx=0, cy=0, zoom=1):
        self.call("test.canvas", {"viewport": {"cx": cx, "cy": cy, "zoom": zoom}})

    def drawn(self):
        return {n["id"]: n["frame"] for n in self.ui()["overview"]["nodes"]}

    def cursor(self):
        return self.ui()["overview"]["cursor"]

    def positions(self):
        return {n["id"]: (n["x"], n["y"]) for n in self.nodes()}

    def pill(self):
        return self.ui()["zoomPill"]

    def assert_view(self, wanted, msg=None):
        for axis in AXES:
            self.assertAlmostEqual(self.viewport()[axis], wanted[axis], delta=1e-6, msg=f"{msg} {axis}")

    def ax_nodes(self):
        found = []

        def walk(nodes):
            for node in nodes:
                found.append(node)
                walk(node.get("children", []))
        walk(self.call("test.ax"))
        return found

    def data_version(self):
        # data_version counts commits by other connections, so one connection must watch throughout.
        if not getattr(self, "watcher", None):
            path = os.path.join(self.data_dir, "barestate.sqlite")
            self.watcher = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            self.addCleanup(self.watcher.close)
        return self.watcher.execute("PRAGMA data_version").fetchone()[0]


class WheelZoomTests(MouseCase):
    def test_cmd_scroll_zooms_around_the_pointer_and_plain_scroll_pans(self):
        """VAL-VIEW-010"""
        tabs = self.overview_of(5)
        requests, browsers = self.requests(), self.ui()["cefBrowserCount"]
        node = self.node_of(tabs[1])["id"]
        self.set_view(zoom=0.5)
        self.settle()
        report = []
        for dy in (120, 120, -120, -120, -120, 120):
            x, y = centre(self.drawn()[node])
            before = self.zoom()
            self.call("test.scroll", {"dx": 0, "dy": dy, "modifier": "cmd", "at": {"x": x, "y": y}})
            after = self.zoom()
            report.append({"dy": dy, "before": before, "after": after})
            self.assertAlmostEqual(after / before, 1.25 ** (dy / 120), places=6)
            nx, ny = centre(self.drawn()[node])
            self.assertAlmostEqual(nx, x, delta=1)
            self.assertAlmostEqual(ny, y, delta=1)
        for dy, wanted in ((-240, 0.2), (240, 1.5)):
            for _ in range(40):
                self.call("test.scroll", {"dx": 0, "dy": dy, "modifier": "cmd"})
                zoom = self.zoom()
                self.assertTrue(0.2 <= zoom <= 1.5, zoom)
            self.assertEqual(self.zoom(), wanted)
        for dy in (1e12, -1e12):
            self.call("test.scroll", {"dx": 0, "dy": dy, "modifier": "cmd"})
            self.assertTrue(0.2 <= self.zoom() <= 1.5)

        self.set_view(zoom=0.8)
        start = self.viewport()
        self.call("test.scroll", {"dx": 30, "dy": -20})
        moved = self.viewport()
        self.assertEqual(moved["zoom"], 0.8)
        self.assertAlmostEqual(moved["cx"], start["cx"] - 30 / 0.8, places=6)
        self.assertAlmostEqual(moved["cy"], start["cy"] + 20 / 0.8, places=6)
        self.assertEqual(self.requests(), requests)
        self.assertEqual(self.ui()["cefBrowserCount"], browsers)
        save("view-010.json", report)

    def test_cmd_scroll_reaches_no_page_and_the_pill_follows_it(self):
        """VAL-VIEW-010, VAL-VIEW-012"""
        tabs = self.overview_of(2)
        self.evaluate("window.__wheels = 0; addEventListener('wheel', () => window.__wheels++, true)",
                      tabs[0])
        requests = self.requests()
        for dy in (120, -120, 40, 7):
            self.call("test.scroll", {"dx": 0, "dy": dy, "modifier": "cmd"})
            self.assertEqual(self.pill()["value"], f"{percent_of(self.zoom())}%")
        self.call("test.scroll", {"dx": 5, "dy": 5})
        self.assertEqual(self.evaluate("window.__wheels", tabs[0]), 0)
        self.assertEqual(self.requests(), requests)


class EmptyCanvasDragTests(MouseCase):
    def test_dragging_empty_canvas_pans_and_a_click_does_nothing(self):
        """VAL-VIEW-011"""
        self.overview_of(8)
        before = {"frames": self.drawn(), "view": self.viewport(), "pos": self.positions()}
        browsers, nodes = self.ui()["cefBrowserCount"], len(self.nodes())
        selection = self.ui()["overview"]["selection"]
        requests = self.requests()

        self.call("test.move", EMPTY)
        bs.wait_until(lambda: self.cursor() == "open-hand", what="the open hand over empty canvas")
        self.call("test.drag", {"target": "canvas", "x": EMPTY["x"], "y": EMPTY["y"],
                                "dx": 300, "dy": 150, "steps": 10, "release": False})
        self.assertEqual(self.cursor(), "closed-hand")
        self.assertEqual(self.level(), "overview")
        self.call("test.mouseUp")
        bs.wait_until(lambda: self.cursor() == "open-hand", what="the open hand after release")
        after = self.drawn()
        for node, frame in before["frames"].items():
            self.assertAlmostEqual(after[node]["x"] - frame["x"], 300, delta=1)
            self.assertAlmostEqual(after[node]["y"] - frame["y"], 150, delta=1)
        self.assertEqual(self.zoom(), before["view"]["zoom"])
        self.assertEqual(self.positions(), before["pos"])
        self.assertEqual((self.ui()["cefBrowserCount"], len(self.nodes())), (browsers, nodes))
        self.assertEqual(self.ui()["overview"]["selection"], selection)
        self.assertEqual(self.level(), "overview")
        self.assertEqual(self.requests(), requests)

        steady = self.viewport()
        self.call("test.click", {"target": "canvas", "x": EMPTY["x"], "y": EMPTY["y"]})
        self.assert_view(steady, "click")
        self.call("test.drag", {"target": "canvas", "x": EMPTY["x"], "y": EMPTY["y"], "dx": 3, "dy": 0})
        self.assert_view(steady, "3 pt")
        self.assertEqual(self.level(), "overview")
        self.assertEqual(self.ui()["overview"]["selection"], selection)

    def test_a_pan_survives_a_relaunch(self):
        """VAL-VIEW-011"""
        self.overview_of(3)
        self.call("test.drag", {"target": "canvas", "x": EMPTY["x"], "y": EMPTY["y"], "dx": -120, "dy": 60})
        panned = self.viewport()
        meta = "SELECT value FROM canvas_meta WHERE key='viewport.cx'"
        bs.wait_until(lambda: (lambda rows: rows and abs(float(rows[0][0]) - panned["cx"]) < 1e-6)(
            self.db(meta)), what="the panned camera saved")
        self.launch(fresh=False)
        bs.wait_until(lambda: self.ui()["overview"]["nodes"], what="the restored cards")
        self.assertAlmostEqual(self.viewport()["cx"], panned["cx"], places=6)
        self.assertAlmostEqual(self.viewport()["cy"], panned["cy"], places=6)


class ZoomPillTests(MouseCase):
    def test_the_pill_shows_the_percentage_and_its_buttons_match_the_shortcuts(self):
        """VAL-VIEW-012"""
        self.overview_of(3)
        self.set_view(zoom=1)
        self.key("-", "cmd")
        self.settle()
        pill = self.pill()
        self.assertEqual((pill["value"], pill["label"]), ("80%", "Zoom 80 percent"))
        for button, label in (("out", "Zoom out"), ("in", "Zoom in")):
            self.assertEqual(pill[button]["label"], label)

        def clear_of_the_button():
            frame, command = self.pill()["frame"], self.ui()["commandButton"]["frame"]
            inside = (0 <= frame["x"] and frame["x"] + frame["w"] <= size[0]
                      and 0 <= frame["y"] and frame["y"] + frame["h"] <= size[1])
            apart = (frame["x"] + frame["w"] <= command["x"] or frame["x"] >= command["x"] + command["w"]
                     or frame["y"] + frame["h"] <= command["y"] or frame["y"] >= command["y"] + command["h"])
            return inside and apart

        for size, scale in (((1440, 900), 1), ((720, 600), 1), ((720, 600), 2)):
            self.call("test.windowSize", {"w": size[0], "h": size[1]})
            self.call("test.textScale", {"scale": scale})
            bs.wait_until(clear_of_the_button, timeout=3,
                          what=f"the pill clear of the command button at {size} x{scale}")
        self.call("test.textScale", {"scale": 1})
        self.call("test.windowSize", {"w": 1440, "h": 900})
        self.settle()

        for name, key, button in (("out", "-", "zoomOut"), ("in", "=", "zoomIn")):
            self.set_view(100, -50, 0.8)
            self.key(key, "cmd")
            self.settle()
            reference = self.viewport()
            self.set_view(100, -50, 0.8)
            self.call("test.click", {"target": button})
            self.settle()
            self.assert_view(reference, name)
        self.set_view(900, -300, 0.4)
        self.key("0", "cmd")
        self.settle()
        fit = self.viewport()
        self.set_view(900, -300, 0.4)
        self.call("test.click", {"target": "zoomPercent"})
        self.settle()
        self.assert_view(fit, "percent")

        frame, steady = self.pill()["frame"], self.viewport()
        self.call("test.drag", {"target": "canvas", "x": frame["x"] + 1, "y": frame["y"] + 1,
                                "dx": 100, "dy": 40, "steps": 4})
        self.assert_view(steady, "a drag that starts on the pill")

        self.set_view(zoom=1.5)
        self.call("test.click", {"target": "zoomIn"})
        self.assertEqual((self.zoom(), self.pill()["value"]), (1.5, "150%"))
        self.set_view(zoom=0.2)
        self.call("test.click", {"target": "zoomOut"})
        self.assertEqual((self.zoom(), self.pill()["value"]), (0.2, "20%"))

    def test_the_percentage_never_lags_a_pinch_or_a_command_scroll(self):
        """VAL-VIEW-012"""
        self.overview_of(3)
        self.set_view(zoom=1)
        for step in (0.1, 0.07, -0.1, -0.3, 0.5, 3, -3):
            self.call("test.magnify", {"by": step})
            self.assertEqual(self.pill()["value"], f"{percent_of(self.zoom())}%", step)
        for dy in (120, 7, -33, -240, 500):
            self.call("test.scroll", {"dx": 0, "dy": dy, "modifier": "cmd"})
            self.assertEqual(self.pill()["value"], f"{percent_of(self.zoom())}%", dy)

    def test_the_pill_is_only_in_the_overview(self):
        """VAL-VIEW-012"""
        tabs = self.overview_of(3)
        self.assertIsNotNone(self.pill())
        self.focus(tabs[0])
        self.show_page()
        self.assertIsNone(self.pill())
        self.assertNotIn("Zoom out", self.ax_labels())
        self.key("Return", "cmd")
        self.wait_level("full-window")
        self.assertIsNone(self.pill())
        self.assertNotIn("Zoom out", self.ax_labels())
        self.key("Return", "cmd")
        self.wait_level("focused")
        self.show_overview()
        self.settle()
        self.assertIsNotNone(self.pill())

    def test_the_controls_have_labels_press_actions_and_are_reachable_by_tab(self):
        """VAL-VIEW-012"""
        self.overview_of(3)
        label = self.pill()["label"]
        controls = {n["label"]: n for n in self.ax_nodes() if n.get("label") in ("Zoom out", "Zoom in", label)}
        self.assertEqual(set(controls), {"Zoom out", "Zoom in", label})
        for name, node in controls.items():
            self.assertIn("AXPress", node["actions"], name)
        reached = set()
        for _ in range(12):
            self.key("Tab")
            reached.add(self.ui()["firstResponder"].get("chromeId"))
        self.assertTrue({"zoomOut", "zoomPercent", "zoomIn"} <= reached, reached)
        self.call("test.click", {"target": "zoomPercent"})
        self.assertEqual(self.pill()["value"], f"{percent_of(self.zoom())}%")


class CardDragTests(MouseCase):
    @staticmethod
    def on_edge_of(point, frame, tol):
        x, y = point["x"], point["y"]
        inside_x = frame["x"] - tol <= x <= frame["x"] + frame["w"] + tol
        inside_y = frame["y"] - tol <= y <= frame["y"] + frame["h"] + tol
        side = min(abs(x - frame["x"]), abs(x - frame["x"] - frame["w"])) <= tol
        top = min(abs(y - frame["y"]), abs(y - frame["y"] - frame["h"])) <= tol
        return (inside_y and side) or (inside_x and top)

    def lift(self, node):
        return next(n for n in self.ui()["overview"]["nodes"] if n["id"] == node)["lift"]

    def trails_of(self, node):
        return [e for e in self.ui()["overview"]["edges"] if node in (e["from"], e["to"])]

    def test_a_dragged_card_is_lifted_held_by_a_closed_hand_followed_by_its_trails_and_saved(self):
        """VAL-VIEW-013"""
        opener = self.open_page("Opener", "popups.html")
        popups = self.popups(opener, 2)
        self.show_overview()
        self.key("0", "cmd")
        self.settle()
        tab = popups[0]
        node = self.node_of(tab)["id"]
        others = {n: p for n, p in self.positions().items() if n != node}
        viewport = self.viewport()
        browsers, tabs, requests = self.ui()["cefBrowserCount"], self.tab_ids(), self.requests()
        before = self.document(tab)
        start = self.positions()[node]
        self.assertTrue(self.trails_of(node))
        time.sleep(1.2)
        seen = self.data_version()
        resting = self.drawn()[node]
        self.assertEqual(self.lift(node), {"scale": 1.0, "shadow": 0.0})

        self.call("test.drag", {"target": f"node:{node}", "dx": 200, "dy": 0, "steps": 6,
                                "release": False})
        self.assertEqual(self.cursor(), "closed-hand")
        lifted = bs.wait_until(
            lambda: (lambda m: m if 1.0 < m["scale"] <= 1.03 and m["shadow"] > 0 else None)(
                self.lift(node)), timeout=1, what="the lift")
        pickups = self.recent("nodePickup")
        self.assertTrue(pickups)
        self.assertLessEqual(pickups[0]["durationMs"], 150)
        report = []
        for _ in range(3):
            frame = self.drawn()[node]
            self.assertGreater(frame["x"], resting["x"] + 100)
            self.assertEqual(self.viewport(), viewport)
            self.assertEqual({n: p for n, p in self.positions().items() if n != node}, others)
            for edge in self.trails_of(node):
                end = edge["end"] if edge["to"] == node else edge["start"]
                self.assertTrue(self.on_edge_of(end, frame, 4), (edge, frame))
            report.append({"frame": frame, "lift": self.lift(node)})
        self.assertEqual(self.data_version(), seen, "wrote during the drag")
        self.call("test.mouseUp")
        self.settle()
        self.assertEqual(self.lift(node), {"scale": 1.0, "shadow": 0.0})
        self.assertEqual(self.cursor(), "pointing-hand")
        dropped = self.drawn()[node]
        for edge in self.trails_of(node):
            end = edge["end"] if edge["to"] == node else edge["start"]
            self.assertTrue(self.on_edge_of(end, dropped, 1), ("a trail kept the lifted edge", edge, dropped))

        released = self.positions()[node]
        self.assertAlmostEqual(released[0], start[0] + 200 / viewport["zoom"], delta=1)
        self.assertAlmostEqual(released[1], start[1], delta=1)
        sql = f"SELECT x, y FROM canvas_nodes WHERE id='{node}'"
        bs.wait_until(lambda: (lambda r: r and abs(r[0][0] - released[0]) < 1 and abs(r[0][1] - released[1]) < 1)(
            self.db(sql)), what="the dropped position saved")
        time.sleep(1.5)
        row = self.db(sql)[0]
        self.assertAlmostEqual(row[0], released[0], delta=1)
        self.assertAlmostEqual(row[1], released[1], delta=1)
        self.assertEqual((self.level(), self.ui()["cefBrowserCount"], self.tab_ids()),
                         ("overview", browsers, tabs))
        self.assertEqual(self.requests(), requests)
        self.assertEqual(self.document(tab), before)
        save("view-013.json", {"lifted": lifted, "samples": report, "released": released})

        self.launch(fresh=False)
        bs.wait_until(lambda: self.positions().get(node), what="the restored card")
        restored = self.positions()[node]
        self.assertAlmostEqual(restored[0], released[0], delta=1)
        self.assertAlmostEqual(restored[1], released[1], delta=1)

    def test_with_reduce_motion_the_lift_is_opacity_only(self):
        """VAL-VIEW-013"""
        tabs = self.overview_of(3)
        node = self.node_of(tabs[1])["id"]
        self.call("test.reduceMotion", {"on": True})
        self.settle()
        before = {i["id"] for i in self.motion()["recent"] + self.motion()["inFlight"]}
        self.call("test.drag", {"target": f"node:{node}", "dx": 150, "dy": 0, "steps": 6,
                                "release": False})
        self.assertEqual(self.cursor(), "closed-hand")
        end = time.time() + 0.4
        while time.time() < end:
            self.assertEqual(self.lift(node)["scale"], 1.0)
            time.sleep(0.016)
        self.call("test.mouseUp")
        self.settle()
        fresh = [i for i in self.motion()["recent"] if i["id"] not in before and i["kind"].startswith("node")]
        self.assertTrue(fresh)
        for item in fresh:
            self.assertNotIn("transform", item["keyPaths"], item)
            self.assertFalse(item["transformChanged"], item)
        self.assertEqual(self.lift(node)["scale"], 1.0)

    def test_a_press_without_movement_opens_the_page_but_a_drag_does_not(self):
        """VAL-VIEW-013"""
        tabs = self.overview_of(3)
        node = self.node_of(tabs[2])["id"]
        self.call("test.drag", {"target": f"node:{node}", "dx": 120, "dy": 0, "steps": 4})
        self.settle()
        self.assertEqual(self.level(), "overview")
        self.call("test.drag", {"target": f"node:{node}", "dx": 2, "dy": 1})
        self.assertEqual(self.level(), "focused")
        self.assertEqual(self.active_id(), tabs[2])


class FirstUseFlowTests(MouseCase):
    PAGES = (("Flow 1", "popups.html"), ("Flow 2", "launcher.html"), ("Flow 3", "launcher.html"))

    def open_with_launcher(self, title, page):
        known = set(self.tab_ids())
        mark = len(self.fixtures.log())
        self.commit_launcher(titled(title, page).removeprefix("http://"))
        tab = self.new_tab_after(known, title)["id"]
        if page == "popups.html":
            ready = f"/__beacon?ready={title.replace(' ', '%20')}"
            bs.wait_until(lambda: any(line.split()[1] == ready for line in self.fixtures.log(mark)),
                          what=f"{title} to paint")
        return tab

    def empty_point(self):
        ui = self.ui()
        focus = ui["focus"]
        rects = [focus["card"], focus["caption"], ui["commandButton"]["frame"]]
        rects += [n["frame"] for n in focus["left"] + focus["right"]]
        for fx, oy in ((0.9, 25), (0.1, 25), (0.9, 70), (0.1, 70), (0.9, 150)):
            x, y = focus["size"]["w"] * fx, focus["size"]["h"] - oy
            if all(x < r["x"] - 40 or x > r["x"] + r["w"] + 40 or y < r["y"] - 40
                   or y > r["y"] + r["h"] + 40 for r in rects):
                return x, y
        self.fail(f"no empty point beside {rects}")

    def test_three_pages_dragged_zoomed_opened_in_full_window_and_back_survive_a_relaunch(self):
        """VAL-VIEW-015"""
        self.assertTrue(self.full()["hint"]["visible"])
        tabs = [self.open_with_launcher(title, page) for title, page in self.PAGES]
        self.assertEqual(len(self.nodes()), 3)
        self.show_overview()
        self.settle()
        browsers = self.ui()["cefBrowserCount"]
        docs = {t: self.document(t) for t in tabs}
        nodes = [self.node_of(t)["id"] for t in tabs]
        requests = self.requests()
        order = [self.level()]

        start = self.positions()
        self.call("test.drag", {"target": f"node:{nodes[2]}", "dx": 0, "dy": -150})
        self.call("test.drag", {"target": f"node:{nodes[1]}", "dx": 200, "dy": 0})
        self.settle()
        moved = self.positions()
        self.assertGreater(moved[nodes[1]][0], start[nodes[1]][0] + 100)
        self.assertLess(moved[nodes[2]][1], start[nodes[2]][1] - 100)
        self.assertEqual(moved[nodes[0]], start[nodes[0]])
        self.key("-", "cmd")
        self.key("-", "cmd")
        self.call("test.scroll", {"dx": 0, "dy": -120, "modifier": "cmd"})
        self.settle()
        self.assertLess(self.zoom(), 1)
        self.assertEqual(self.pill()["value"], f"{percent_of(self.zoom())}%")
        self.call("test.click", {"target": "zoomPercent"})
        self.settle()
        fit = self.viewport()
        self.key("0", "cmd")
        self.settle()
        self.assert_view(fit, "pill percent equals ⌘0")

        self.call("test.click", {"target": f"node:{nodes[0]}", "count": 2})
        self.wait_level("full-window")
        order.append(self.level())
        self.assertEqual(self.active_id(), tabs[0])
        self.assertIsNone(self.pill())
        before_link = len(self.fixtures.log())
        self.click(tabs[0], "plain")
        bs.wait_until(lambda: self.evaluate("document.title", tabs[0]) == "in-tab", what="the link")
        landed = [line for line in self.fixtures.log(before_link) if "t=in-tab" in line.split()[1]]
        self.assertEqual(len(landed), 1, landed)

        self.key("Return", "cmd")
        self.wait_level("focused")
        order.append(self.level())
        self.assertIsNone(self.pill())
        x, y = self.empty_point()
        self.call("test.click", {"target": "root", "x": x, "y": y})
        self.wait_level("overview")
        order.append(self.level())
        self.assertIsNotNone(self.pill())
        self.assertEqual(order, ["overview", "full-window", "focused", "overview"])

        for tab in tabs[1:]:
            self.assertEqual(self.document(tab), docs[tab])
        self.assertEqual(self.ui()["cefBrowserCount"], browsers)
        self.assertEqual(before_link, requests, "a drag, zoom or click reloaded a page")
        others = [line for line in self.fixtures.log(before_link)
                  if "t=in-tab" not in line.split()[1] and line.split()[1] != "/favicon.ico"]
        self.assertEqual(others, [])

        positions = self.positions()
        edges = self.db("SELECT from_id, to_id, kind, run_id FROM canvas_edges ORDER BY rowid")
        self.assertEqual(len(edges), len(self.edges()))
        self.assertEqual(len(self.ui()["overview"]["edges"]), len(edges))
        for node, (px, py) in positions.items():
            sql = f"SELECT x, y FROM canvas_nodes WHERE id='{node}'"
            bs.wait_until(lambda: (lambda r: r and abs(r[0][0] - px) < 1 and abs(r[0][1] - py) < 1)(
                self.db(sql)), what="the position saved")

        self.launch(fresh=False)
        bs.wait_until(lambda: len(self.ui()["overview"]["nodes"]) == 3, what="the restored cards")
        restored = self.positions()
        for node, (px, py) in positions.items():
            self.assertAlmostEqual(restored[node][0], px, delta=1)
            self.assertAlmostEqual(restored[node][1], py, delta=1)
        self.assertEqual(self.db("SELECT from_id, to_id, kind, run_id FROM canvas_edges ORDER BY rowid"), edges)
        self.assertEqual(len(self.ui()["overview"]["edges"]), len(edges))
        self.assertFalse(self.full()["hint"]["visible"])
        self.assertIsNotNone(self.pill())
        save("view-015.json", {"order": order, "positions": positions})


if __name__ == "__main__":
    unittest.main()
