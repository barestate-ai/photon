"""The overview presentation: what the canvas draws, pointer and keyboard navigation, captures at
the presentation's moments and persistence (VAL-SPATIAL-004..006, 008..010, 012, VAL-PREVIEW-001,
VAL-PREVIEW-005)."""
import os
import sqlite3
import time
import unittest
from urllib.parse import quote

import bs
import png
from appcase import url
from test_graph import GraphCase

CANVAS = png.hex_rgb("fbfaf4")
COLOURS = ["e63946", "2a9d8f", "264653", "f4a261", "6a4c93", "1d3557"]


def band(title, colour):
    return url(f"band.html?c={colour}&t={quote(title)}")


class CanvasCase(GraphCase):
    def overview(self):
        return self.ui()["overview"]

    def presentation(self):
        return self.ui()["presentation"]

    def wait_presentation(self, wanted):
        bs.wait_until(lambda: self.presentation() == wanted, what=f"presentation {wanted}")

    def show_overview(self):
        if self.presentation() != "overview":
            self.key("\\", "cmd", "shift")
            self.wait_presentation("overview")

    def band(self, title, colour, activate=True):
        address = band(title, colour)
        tab = self.call("open_tab", {"url": address, "activate": activate})
        self.wait_loaded(address, tab["id"])
        self.wait_node(tab["id"])
        return tab["id"]

    def frame(self, node_id):
        return next(n for n in self.overview()["nodes"] if n["id"] == node_id)["frame"]

    def viewport(self):
        return self.canvas()["viewport"]

    def set_viewport(self, cx=0, cy=0, zoom=1):
        self.call("test.canvas", {"viewport": {"cx": cx, "cy": cy, "zoom": zoom}})

    def shot(self, name):
        bs.wait_until(lambda: not self.call("test.motion")["inFlight"], what="motion at rest")
        path = f"/tmp/bs-shot-{os.getpid()}-{name}.png"
        self.call("test.screenshot", {"path": path})
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        image = png.Image(path)
        window = self.ui()["windowFrame"]
        return image, image.width / window["w"]

    def sample(self, shot, x, y):
        image, scale = shot
        return image.pixel(int(x * scale), int(y * scale))

    def captures(self):
        return [r for r in self.call("test.previews")["log"]]

    def wait_captures(self, count):
        return bs.wait_until(lambda: len(self.captures()) >= count and self.captures(),
                             what=f"{count} captures")


class EmptyCanvasTests(CanvasCase):
    def test_first_run_is_an_empty_overview_with_only_the_chrome(self):
        ui = self.ui()
        self.assertEqual(ui["presentation"], "overview")
        self.assertEqual((ui["canvas"]["nodes"], ui["canvas"]["edges"]), ([], []))
        overview = ui["overview"]
        self.assertEqual(overview["nodes"], [])
        self.assertFalse(overview["legend"]["visible"])
        self.assertEqual(overview["title"]["text"], "Your pages")
        self.assertTrue(ui["commandButton"]["visible"])
        shot = self.shot("empty")
        image, scale = shot
        keep = [ui["commandButton"]["frame"], overview["title"]["frame"],
                {"x": 40, "y": 36, "w": 240, "h": 36}]
        total = off = 0
        for y in range(0, int(image.height / scale), 6):
            for x in range(0, int(image.width / scale), 6):
                if any(f["x"] - 8 <= x <= f["x"] + f["w"] + 8 and f["y"] - 8 <= y <= f["y"] + f["h"] + 8
                       for f in keep):
                    continue
                total += 1
                off += not png.close(self.sample(shot, x, y), CANVAS)
        self.assertLessEqual(off, total * 0.01, f"{off} of {total} samples are not canvas colour")

    def test_the_title_is_editable_and_persists(self):
        self.call("test.click", {"target": "canvasTitle"})
        bs.wait_until(lambda: self.overview()["title"]["editing"], what="the title editing")
        self.key("a", "cmd")
        self.call("test.type", {"text": "Trip planning"})
        self.key("Return")
        bs.wait_until(lambda: self.canvas()["title"] == "Trip planning", what="the title committed")
        self.assertEqual(self.overview()["title"]["text"], "Trip planning")
        self.assertFalse(self.overview()["title"]["editing"])
        self.wait_saved("SELECT value FROM canvas_meta WHERE key='title'", [("Trip planning",)])
        self.launch(fresh=False)
        self.assertEqual(self.overview()["title"]["text"], "Trip planning")
        self.call("test.click", {"target": "canvasTitle"})
        self.key("a", "cmd")
        self.call("test.type", {"text": "Discarded"})
        self.key("Escape")
        bs.wait_until(lambda: not self.overview()["title"]["editing"], what="the edit ended")
        self.assertEqual(self.canvas()["title"], "Trip planning")
        self.assertEqual(self.overview()["title"]["text"], "Trip planning")
        self.call("test.click", {"target": "canvasTitle"})
        self.key("a", "cmd")
        self.key("Backspace")
        self.key("Return")
        bs.wait_until(lambda: self.canvas()["title"] == "Your pages", what="the default restored")
        self.assertEqual(self.tab_ids().__len__(), 1)


    def test_the_title_is_reachable_and_editable_by_keyboard_alone(self):
        def responder():
            return self.ui()["firstResponder"].get("chromeId")

        def tab_to(chrome_id):
            for _ in range(4):
                self.key("Tab")
                if responder() == chrome_id:
                    return
            self.fail(f"Tab never reached {chrome_id}; the responder is {responder()}")

        tab_to("canvasTitle")
        bs.wait_until(lambda: self.overview()["title"]["editing"], what="the title editing")
        self.call("test.type", {"text": "Trip planning"})
        self.key("Return")
        bs.wait_until(lambda: self.canvas()["title"] == "Trip planning", what="the title committed")
        self.assertFalse(self.overview()["title"]["editing"])
        self.wait_saved("SELECT value FROM canvas_meta WHERE key='title'", [("Trip planning",)])

        tab_to("canvasTitle")
        self.call("test.type", {"text": "Discarded"})
        self.key("Escape")
        bs.wait_until(lambda: not self.overview()["title"]["editing"], what="the edit ended")
        self.assertEqual(self.canvas()["title"], "Trip planning")
        self.assertEqual(self.overview()["title"]["text"], "Trip planning")

        tab_to("canvasTitle")
        for wanted in ("zoomOut", "zoomPercent", "zoomIn", "commandButton"):
            self.key("Tab")
            self.assertEqual(responder(), wanted)
        for wanted in ("zoomIn", "zoomPercent", "zoomOut", "canvasTitle"):
            self.key("Tab", "shift")
            self.assertEqual(responder(), wanted)
        self.key("Escape")


class DrawingTests(CanvasCase):
    def test_overview_draws_the_graph_it_has(self):
        tabs = [self.band(f"Page {i}", COLOURS[i]) for i in range(6)]
        for tab in tabs[:2]:
            self.call("test.closeTab", {"tabId": tab})
        live = tabs[2:]
        self.focus(live[0])
        self.call("test.activateTab", {"tabId": live[0]})
        self.show_overview()
        overview, canvas = self.overview(), self.canvas()
        self.assertEqual(len(overview["nodes"]), len(canvas["nodes"]))
        host = f"127.0.0.1:{bs.FIXTURE_URL.rsplit(':', 1)[1]}"
        by_id = {n["id"]: n for n in canvas["nodes"]}
        for node in overview["nodes"]:
            graph = by_id[node["id"]]
            self.assertEqual(node["title"], graph["title"])
            self.assertEqual(node["subtitle"],
                             f"Live page · {host}" if graph["kind"] == "live"
                             else "Closed page · Reopen")
        self.assertEqual(sum(n["current"] for n in overview["nodes"]), 1)
        current = next(n for n in overview["nodes"] if n["current"])
        self.assertEqual(current["id"], self.node_of(live[0])["id"])
        self.assertEqual(overview["currentLabel"]["text"], "Current page")
        self.assertEqual(sum(n["selected"] for n in overview["nodes"]), 1)
        self.assertEqual(overview["selection"], current["id"])
        self.assertTrue(all(n["placeholder"] or n["hasImage"] for n in overview["nodes"]))

    def test_edges_are_drawn_per_kind_and_the_legend_follows_them(self):
        first = self.band("First", COLOURS[0])
        self.show_overview()
        self.assertFalse(self.overview()["legend"]["visible"])
        self.assertEqual(self.overview()["edges"], [])
        self.key("\\", "cmd", "shift")
        self.wait_presentation("focused")
        before = self.tab_ids()
        self.commit_launcher(band("Second", COLOURS[1]), kind="openURL")
        second = self.new_tab_after(before, "Second")["id"]
        self.show_overview()
        edges = self.overview()["edges"]
        bs.wait_until(lambda: len(self.db("SELECT * FROM canvas_edges")) == len(edges) and edges,
                      what="the edge saved")
        self.assertEqual([e["kind"] for e in edges], ["navigatedFrom"])
        self.assertEqual(edges[0]["color"], "c0c4b9")
        self.assertEqual((edges[0]["width"], edges[0]["dash"], edges[0]["cap"]),
                         (1.25, [1, 7], "round"))
        legend = self.overview()["legend"]
        self.assertTrue(legend["visible"])
        self.assertEqual([i["label"] for i in legend["items"]], ["Your trail"])
        self.assertIn(first, self.tab_ids())
        self.assertIn(second, self.tab_ids())

    def test_a_node_without_a_preview_shows_its_title_and_origin(self):
        self.band("Seen", COLOURS[0])
        self.band("Unseen", COLOURS[1], activate=False)
        self.show_overview()
        nodes = {n["title"]: n for n in self.overview()["nodes"]}
        self.assertFalse(nodes["Unseen"]["hasImage"])
        self.assertTrue(nodes["Unseen"]["placeholder"])
        self.assertTrue(nodes["Unseen"]["origin"].startswith("127.0.0.1"))
        self.assertTrue(nodes["Seen"]["hasImage"])


class PreviewPixelTests(CanvasCase):
    def test_each_node_shows_the_pixels_of_its_own_page(self):
        tabs = [self.band(f"Band {i}", colour) for i, colour in enumerate(COLOURS)]
        for tab in tabs:
            self.call("test.activateTab", {"tabId": tab})
            bs.wait_until(lambda: self.presentation() == "focused", what="focused")
            self.show_overview()
        self.call("test.canvas", {"viewport": {"cx": 0, "cy": 0, "zoom": 0.5}})
        self.key("0", "cmd")
        bs.wait_until(lambda: all(n["hasImage"] for n in self.overview()["nodes"]), what="previews")
        shot = self.shot("bands")
        seen = []
        for tab, colour in zip(tabs, COLOURS):
            node = self.node_of(tab)
            f = self.frame(node["id"])
            pixel = self.sample(shot, f["x"] + f["w"] / 2, f["y"] + f["h"] / 2)
            self.assertTrue(png.close(pixel, png.hex_rgb(colour), 12), (tab, pixel, colour))
            seen.append(pixel)
        self.assertEqual(len(set(seen)), len(COLOURS))


class PointerTests(CanvasCase):
    def pages(self, count):
        tabs = [self.band(f"Page {i}", COLOURS[i % len(COLOURS)]) for i in range(count)]
        self.show_overview()
        self.key("0", "cmd")
        return tabs

    def test_scroll_pans_by_the_scrolled_distance(self):
        self.pages(3)
        self.set_viewport(100, 100, 1)
        self.call("test.scroll", {"dx": 30, "dy": -20})
        view = self.viewport()
        self.assertAlmostEqual(view["cx"], 70, delta=1)
        self.assertAlmostEqual(view["cy"], 120, delta=1)
        self.call("test.scroll", {"dx": -30, "dy": 20})
        self.assertAlmostEqual(self.viewport()["cx"], 100, delta=1)
        self.assertAlmostEqual(self.viewport()["cy"], 100, delta=1)
        self.set_viewport(100, 100, 0.5)
        self.call("test.scroll", {"dx": 40, "dy": 0})
        self.assertAlmostEqual(self.viewport()["cx"], 100 - 80, delta=1)

    def test_magnify_zooms_around_the_pointer_and_clamps(self):
        self.pages(3)
        self.set_viewport(0, 0, 1)
        size = self.overview()["size"]
        at = {"x": size["w"] * 0.25, "y": size["h"] * 0.75}

        def canvas_under(point):
            view = self.viewport()
            return (view["cx"] + (point["x"] - size["w"] / 2) / view["zoom"],
                    view["cy"] + (point["y"] - size["h"] / 2) / view["zoom"])
        before = canvas_under(at)
        self.call("test.magnify", {"by": 0.5, "at": at})
        after = canvas_under(at)
        self.assertAlmostEqual(self.viewport()["zoom"], 1.5, delta=1e-9)
        self.assertAlmostEqual(before[0], after[0], delta=1)
        self.assertAlmostEqual(before[1], after[1], delta=1)
        for _ in range(5):
            self.call("test.magnify", {"by": 3, "at": at})
        self.assertEqual(self.viewport()["zoom"], 1.5)
        for _ in range(5):
            self.call("test.magnify", {"by": -3, "at": at})
        self.assertEqual(self.viewport()["zoom"], 0.2)

    def test_dragging_a_node_moves_only_that_node_and_persists(self):
        tabs = self.pages(3)
        self.set_viewport(self.node_of(tabs[1])["x"], self.node_of(tabs[1])["y"], 0.5)
        before = {n["id"]: (n["x"], n["y"]) for n in self.nodes()}
        node = self.node_of(tabs[1])
        self.call("test.drag", {"target": f"node:{node['id']}", "dx": 60, "dy": 40})
        after = {n["id"]: (n["x"], n["y"]) for n in self.nodes()}
        moved = [i for i in before if before[i] != after[i]]
        self.assertEqual(moved, [node["id"]])
        self.assertAlmostEqual(after[node["id"]][0] - before[node["id"]][0], 120, delta=1)
        self.assertAlmostEqual(after[node["id"]][1] - before[node["id"]][1], 80, delta=1)
        self.assertEqual(self.presentation(), "overview")
        self.wait_saved(f"SELECT x, y FROM canvas_nodes WHERE id='{node['id']}'",
                        [after[node["id"]]])

    def test_a_click_focuses_the_node_and_a_two_point_drag_is_a_click(self):
        tabs = self.pages(2)
        self.call("test.click", {"target": f"node:{self.node_of(tabs[0])['id']}"})
        self.wait_presentation("focused")
        self.assertEqual(self.active_id(), tabs[0])
        self.show_overview()
        before = self.node_of(tabs[1])
        self.call("test.drag", {"target": f"node:{before['id']}", "dx": 2, "dy": 1})
        self.wait_presentation("focused")
        self.assertEqual(self.active_id(), tabs[1])
        self.assertEqual((self.node_of(tabs[1])["x"], self.node_of(tabs[1])["y"]),
                         (before["x"], before["y"]))

    def test_negative_magnify_in_the_focused_page_returns_to_the_overview(self):
        self.band("One", COLOURS[0])
        self.assertEqual(self.presentation(), "focused")
        self.call("test.magnify", {"by": -0.3})
        self.wait_presentation("overview")

    def test_no_pointer_input_reaches_a_page(self):
        tabs = self.pages(2)
        self.focus(tabs[0])
        self.call("test.click", {"target": tabs[0], "x": 100, "y": 100})
        bs.wait_until(lambda: self.evaluate("window.__pointer", tabs[0]) > 0,
                      what="a click in the focused page to reach it")
        self.show_overview()
        before = [self.evaluate("window.__pointer", tab) for tab in tabs]
        self.call("test.scroll", {"dx": 10, "dy": 10})
        self.call("test.magnify", {"by": 0.1})
        self.call("test.drag", {"target": f"node:{self.node_of(tabs[0])['id']}", "dx": 40, "dy": 0})
        self.assertEqual([self.evaluate("window.__pointer", tab) for tab in tabs], before)


class KeyboardTests(CanvasCase):
    def test_arrow_keys_move_the_selection_and_the_camera_follows(self):
        tabs = [self.band(f"Page {i}", COLOURS[i]) for i in range(3)]
        self.show_overview()
        ids = [self.node_of(t)["id"] for t in tabs]
        # A row of three, far enough apart that the camera must pan to reveal the last.
        for i, node in enumerate(ids):
            self.call("test.canvas", {"move": {"node": node, "x": i * 700, "y": 0}})
        self.set_viewport(0, 0, 1)
        self.call("test.canvas", {"viewport": {"cx": 0, "cy": 0, "zoom": 1}})
        self.assertEqual(self.overview()["selection"], ids[2])
        self.key("ArrowLeft")
        self.assertEqual(self.overview()["selection"], ids[1])
        self.key("ArrowLeft")
        self.assertEqual(self.overview()["selection"], ids[0])
        self.key("ArrowLeft")
        self.assertEqual(self.overview()["selection"], ids[0])
        self.key("ArrowRight")
        self.key("ArrowRight")
        self.assertEqual(self.overview()["selection"], ids[2])
        size = self.overview()["size"]
        f = self.frame(ids[2])
        self.assertTrue(0 <= f["x"] and f["x"] + f["w"] <= size["w"], f)
        self.key("Return")
        self.wait_presentation("focused")
        self.assertEqual(self.active_id(), tabs[2])

    def test_zoom_keys_and_the_menu_agree(self):
        self.band("One", COLOURS[0])
        self.show_overview()
        self.set_viewport(0, 0, 1)
        self.key("=", "cmd")
        zoomed = self.viewport()["zoom"]
        self.assertGreater(zoomed, 1)
        self.key("-", "cmd")
        self.assertAlmostEqual(self.viewport()["zoom"], 1, delta=1e-9)
        self.call("test.menu", {"invoke": "Zoom Out"})
        self.assertLess(self.viewport()["zoom"], 1)
        self.key("0", "cmd")
        self.assertEqual(self.viewport()["zoom"], 1.5)
        view = self.view_menu()
        self.assertEqual(view["Show Page"]["shortcut"], "⇧⌘\\")
        self.assertEqual((view["Zoom In"]["shortcut"], view["Zoom Out"]["shortcut"],
                          view["Zoom to Fit"]["shortcut"]), ("⌘=", "⌘-", "⌘0"))
        self.key("\\", "cmd", "shift")
        self.wait_presentation("focused")
        view = self.view_menu()
        self.assertIn("Show Overview", view)
        self.assertFalse(view["Zoom In"]["enabled"])
        self.assertFalse(view["Zoom to Fit"]["enabled"])
        self.assertEqual(view["Zoom In"]["toolTip"], "Zoom applies to the overview")
        self.key("-", "cmd")
        self.wait_presentation("overview")

    def view_menu(self):
        return {item["title"]: item for menu in self.call("test.menu") if menu["title"] == "View"
                for item in menu["items"] if "title" in item}

    def test_empty_canvas_fits_to_the_origin_at_zoom_one(self):
        self.set_viewport(500, 500, 0.3)
        self.key("0", "cmd")
        self.assertEqual((self.viewport()["cx"], self.viewport()["cy"], self.viewport()["zoom"]),
                         (0, 0, 1))

    def test_zoom_to_fit_contains_every_node(self):
        tabs = [self.band(f"Page {i}", COLOURS[i]) for i in range(4)]
        self.show_overview()
        self.call("test.canvas", {"move": {"node": self.node_of(tabs[0])["id"], "x": -1500, "y": 200}})
        self.key("0", "cmd")
        size = self.overview()["size"]
        for node in self.overview()["nodes"]:
            f = node["frame"]
            self.assertTrue(f["x"] >= 0 and f["y"] >= 0 and f["x"] + f["w"] <= size["w"]
                            and f["y"] + f["h"] <= size["h"], f)

    def test_the_launcher_rows_do_what_the_keys_do(self):
        self.band("One", COLOURS[0])
        self.show_overview()
        self.set_viewport(0, 0, 1)
        for query, check in [
            ("zoom in", lambda: self.viewport()["zoom"] > 1),
            ("zoom out", lambda: self.viewport()["zoom"] <= 1.0001),
            ("zoom to fit", lambda: self.viewport()["zoom"] == 1.5),
            ("show page", lambda: self.presentation() == "focused"),
            ("show overview", lambda: self.presentation() == "overview"),
        ]:
            self.commit_launcher(query, kind="command")
            bs.wait_until(check, what=f"the {query} row to take effect")


class ArchivedTests(CanvasCase):
    def test_choosing_a_closed_page_reopens_its_url_and_says_so(self):
        tab = self.band("Gone", COLOURS[0])
        archived_id = self.node_of(tab)["id"]
        self.band("Stays", COLOURS[1])
        self.call("test.closeTab", {"tabId": tab})
        self.show_overview()
        node = next(n for n in self.overview()["nodes"] if n["id"] == archived_id)
        self.assertEqual(node["subtitle"], "Closed page · Reopen")
        count = self.ui()["cefBrowserCount"]
        since = len(self.fixtures.log(0))
        self.call("test.click", {"target": f"node:{archived_id}"})
        self.wait_presentation("focused")
        revived = bs.wait_until(lambda: next((n for n in self.nodes() if n["id"] == archived_id
                                              and n["kind"] == "live"), None), what="revival")
        self.assertEqual(len([n for n in self.nodes() if n["title"] == "Gone"]), 1)
        self.assertEqual(self.active_id(), revived["tabId"])
        self.assertIn("Reopened closed page", self.call("test.announcements")["announcements"])
        self.assertEqual(self.ui()["cefBrowserCount"], count + 1)
        self.assertTrue(any("band.html" in line for line in self.fixtures.log(since)))

    def test_show_page_follows_the_selected_closed_node_with_a_blank_tab_active(self):
        tab = self.band("Gone", COLOURS[0])
        archived_id = self.node_of(tab)["id"]
        self.call("test.closeTab", {"tabId": tab})
        self.launch(fresh=False)
        self.show_overview()
        self.key("ArrowRight")
        bs.wait_until(lambda: self.overview()["selection"] == archived_id, what="the selection")
        item = next(i for m in self.call("test.menu") if m["title"] == "View"
                    for i in m["items"] if i.get("title") == "Show Page")
        self.assertTrue(item["enabled"])
        self.key("\\", "cmd", "shift")
        self.wait_presentation("focused")
        self.assertIn("Reopened closed page", self.call("test.announcements")["announcements"])


class CaptureTests(CanvasCase):
    def test_leaving_the_page_captures_it_once_before_the_overview_shows(self):
        self.band("One", COLOURS[0])
        bs.wait_until(lambda: len(self.captures()) >= 1, what="the settle capture")
        before = len(self.captures())
        self.key("\\", "cmd", "shift")
        self.wait_presentation("overview")
        log = self.captures()
        self.assertEqual(len(log), before + 1)
        self.assertEqual(log[-1]["outcome"], "stored")
        self.assertEqual(log[-1]["magic"], "ffd8ff")

    def test_a_navigation_settling_in_the_focused_page_captures_once(self):
        tab = self.band("One", COLOURS[0])
        bs.wait_until(lambda: len(self.captures()) == 1, what="the first capture")
        self.navigate(tab, band("Two", COLOURS[1]))
        bs.wait_until(lambda: len(self.captures()) == 2, what="the capture after navigating")
        time.sleep(1)
        self.assertEqual(len(self.captures()), 2)

    def test_hidden_pages_and_an_idle_overview_are_never_captured(self):
        front = self.band("Front", COLOURS[0])
        bs.wait_until(lambda: len(self.captures()) == 1, what="the first capture")
        back = self.band("Back", COLOURS[1], activate=False)
        self.navigate(back, band("Back two", COLOURS[2]))
        self.show_overview()
        count = len(self.captures())
        self.navigate(back, band("Back three", COLOURS[3]))
        deadline = time.time() + 10
        while time.time() < deadline:
            self.assertEqual(len(self.captures()), count)
            time.sleep(1)
        self.assertEqual({r["tabId"] for r in self.captures()}, {front})


class PersistenceTests(CanvasCase):
    def data_version(self):
        # data_version counts commits by other connections, so one connection must watch throughout.
        if not getattr(self, "watcher", None):
            path = os.path.join(self.data_dir, "barestate.sqlite")
            self.watcher = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            self.addCleanup(self.watcher.close)
        return self.watcher.execute("PRAGMA data_version").fetchone()[0]

    def test_gestures_write_nothing_until_they_end(self):
        tabs = [self.band(f"Page {i}", COLOURS[i]) for i in range(3)]
        self.show_overview()
        self.wait_saved("SELECT count(*) FROM canvas_nodes", [(3,)])
        node = self.node_of(tabs[0])["id"]
        # Let any pending save finish.
        time.sleep(1.2)
        gestures = {
            "scroll": lambda: [self.call("test.scroll", {"dx": 2, "dy": 1}) for _ in range(120)],
            "magnify": lambda: [self.call("test.magnify", {"by": 0.001}) for _ in range(60)],
            "drag": lambda: self.call("test.drag", {"target": f"node:{node}", "dx": 90, "dy": 0,
                                                    "release": False, "steps": 90}),
        }
        for name, run in gestures.items():
            seen = self.data_version()
            run()
            self.assertEqual(self.data_version(), seen, f"{name} wrote during the gesture")
            if name == "drag":
                self.call("test.mouseUp")
            bs.wait_until(lambda: self.data_version() != seen, timeout=5,
                          what=f"{name} saved after it ended")
            changes, last = 0, self.data_version()
            deadline = time.time() + 2
            while time.time() < deadline:
                now = self.data_version()
                changes += now != last
                last = now
                time.sleep(0.02)
            self.assertLessEqual(changes, 2)

    def test_viewport_and_positions_survive_a_relaunch(self):
        tabs = [self.band(f"Page {i}", COLOURS[i]) for i in range(2)]
        self.show_overview()
        node = self.node_of(tabs[0])
        self.call("test.canvas", {"move": {"node": node["id"], "x": 333.5, "y": -120.25},
                                  "viewport": {"cx": 42.5, "cy": -17.25, "zoom": 0.75}})
        self.wait_saved(f"SELECT x, y FROM canvas_nodes WHERE id='{node['id']}'",
                        [(333.5, -120.25)])
        self.launch(fresh=False)
        canvas = self.canvas()
        view = canvas["viewport"]
        self.assertAlmostEqual(view["cx"], 42.5, delta=1e-6)
        self.assertAlmostEqual(view["zoom"], 0.75, delta=1e-6)
        self.assertEqual(self.presentation(), "overview")
        restored = next(n for n in canvas["nodes"] if n["id"] == node["id"])
        self.assertEqual((restored["x"], restored["y"], restored["kind"]), (333.5, -120.25, "archived"))
        self.assertEqual(len(self.overview()["nodes"]), 2)

    def test_a_saved_camera_at_the_origin_is_kept_however_far_apart_the_pages_are(self):
        tabs = [self.band(f"Page {i}", COLOURS[i]) for i in range(2)]
        self.show_overview()
        self.call("test.canvas", {"move": {"node": self.node_of(tabs[0])["id"], "x": 2400, "y": 900},
                                  "viewport": {"cx": 0, "cy": 0, "zoom": 1}})
        meta = "SELECT key, value FROM canvas_meta WHERE key LIKE 'viewport.%' ORDER BY key"
        self.wait_saved(meta, [("viewport.cx", "0.0"), ("viewport.cy", "0.0"), ("viewport.zoom", "1.0")])
        self.launch(fresh=False)
        bs.wait_until(lambda: len(self.nodes()) == 2 and self.overview()["nodes"],
                      what="the restored pages drawn")
        time.sleep(0.5)
        view = self.viewport()
        self.assertEqual((view["cx"], view["cy"], view["zoom"]), (0, 0, 1))
        self.assertEqual(self.db(meta), [("viewport.cx", "0.0"), ("viewport.cy", "0.0"),
                                         ("viewport.zoom", "1.0")])

    def test_a_first_run_frames_its_pages_and_a_relaunch_keeps_that_camera(self):
        self.band("One", COLOURS[0])
        self.band("Two", COLOURS[1])
        self.show_overview()
        framed = bs.wait_until(lambda: (lambda v: v if v != {"cx": 0, "cy": 0, "zoom": 1} else None)(
            self.viewport()), what="the first run to frame its pages")
        bs.wait_until(lambda: self.db("SELECT value FROM canvas_meta WHERE key='viewport.cx'")
                      not in ([], [("0.0",)]), what="the framed camera saved")
        self.launch(fresh=False)
        bs.wait_until(lambda: len(self.overview()["nodes"]) == 2, what="the restored cards")
        time.sleep(0.5)
        self.assertEqual(self.viewport(), framed)


class FrameProbeTests(CanvasCase):
    def test_a_pan_is_timed_between_committed_steps(self):
        for i in range(3):
            self.band(f"Page {i}", COLOURS[i])
        self.show_overview()
        self.call("test.frameProbe", {"action": "start", "pan": {"dx": 8, "dy": 3}})
        time.sleep(1)
        probe = self.call("test.frameProbe", {"action": "stop"})
        self.assertGreater(probe["steps"], 20)
        self.assertGreaterEqual(probe["commits"], probe["steps"] - 2)
        self.assertEqual(len(probe["intervalsMs"]), probe["commits"] - 1)
        self.assertTrue(all(v > 0 for v in probe["intervalsMs"]))
        self.assertLessEqual(probe["notPresented"], probe["steps"] // 10)
        self.assertGreater(len(probe["tickIntervalsMs"]), 20)


if __name__ == "__main__":
    unittest.main()
