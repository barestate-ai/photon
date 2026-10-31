"""Motion: the camera between the overview and a page, its Reduce Motion variant, the small
animations (entrance, trail, preview, press, drag, rubber band) and the paths that must never
animate (VAL-MOTION-001..005, VAL-TABS-012). Samples come from `test.motion`."""
import os
import subprocess
import time
import unittest

import bs
import png
from appcase import save, url
from test_focus import FocusCase

PURPOSES = {"camera", "node-entrance", "trail-draw", "preview-crossfade", "button-press",
            "muse-pulse", "result-state", "approval-entrance", "completion", "panel-fade",
            "notice-fade", "status-fade", "trail-flow", "thinking-orb"}
SOURCES = os.path.join(bs.ROOT, "Sources", "Barestate")


def centre(rect):
    return rect["x"] + rect["w"] / 2, rect["y"] + rect["h"] / 2


def distance(a, b):
    return max(abs(a["x"] - b["x"]), abs(a["y"] - b["y"]), abs(a["w"] - b["w"]),
               abs(a["h"] - b["h"]))


class MotionCase(FocusCase):
    def motion(self):
        return self.call("test.motion")

    def idle(self):
        state = self.motion()
        return state["camera"]["phase"] == "idle" and not state["inFlight"]

    def settle(self):
        bs.wait_until(self.idle, what="no motion left", timeout=5)

    def sample(self, until=None, limit=2.0):
        """Reads the motion state back to back until it has moved and come to rest."""
        samples, moved = [], False
        end = time.time() + limit
        while time.time() < end:
            now = time.time()
            state = self.motion()
            samples.append((now, state))
            moved = moved or bool(state["inFlight"]) or state["camera"]["phase"] != "idle"
            if moved and (until(state) if until else self.settled(state)):
                break
        return samples

    @staticmethod
    def settled(state):
        return state["camera"]["phase"] == "idle" and not state["inFlight"]

    def overview_with_pages(self, count=3):
        tabs = self.pages(count)
        self.row(tabs)
        self.focus(tabs[0])
        self.show_overview()
        self.settle()
        return tabs

    def wait_renderer_follows_view(self, tab):
        """The page's own viewport equals the live view's frame (points are CSS pixels)."""
        def follows():
            frame = next(t for t in self.ui()["tabs"] if t["id"] == tab)["frame"]
            seen = self.call("test.devtools", {
                "tabId": tab, "method": "Runtime.evaluate",
                "params": {"expression": "[innerWidth, innerHeight]", "returnByValue": True}})
            return seen["result"]["value"] == [frame["w"], frame["h"]]
        bs.wait_until(follows, what="the renderer to follow its view", timeout=5)

    def click_node(self, tab):
        self.call("test.click", {"target": f"node:{self.node_of(tab)['id']}"})

    def toggle(self):
        self.key("\\", "cmd", "shift")

    def recent(self, kind):
        state = self.motion()
        return [item for item in state["recent"] + state["inFlight"] if item["kind"] == kind]


class CameraTests(MotionCase):
    def test_the_camera_flies_the_preview_to_the_page_and_back_without_resizing_the_live_view(self):
        """VAL-MOTION-001, VAL-MOTION-002"""
        tabs = self.overview_with_pages()
        before = self.motion()["camera"]["liveFrame"]
        self.click_node(tabs[1])
        forward = self.sample()
        self.wait_presentation("focused")
        card = self.assert_card_is_page()
        moving = [s for _, s in forward if s["camera"]["phase"] == "moving"]
        self.assertTrue(moving, "a camera animation ran")
        item = next(i for s in moving for i in s["inFlight"] if i["kind"] == "camera")
        self.assertEqual((item["purpose"], item["curve"]), ("camera", "spring"))
        self.assertLessEqual(item["bounce"], 0.2)
        self.assertLessEqual(item["durationMs"], 450)
        self.assertEqual(item["to"]["scale"], 1)
        for state in moving:
            self.assertIn(state["camera"]["layer"], ("preview", "placeholder"))
            self.assertFalse(state["camera"]["liveVisible"], "the live view waits for the end")
            self.assertEqual(state["camera"]["liveFrame"], before)
        rects = [s["camera"]["rect"] for s in moving if s["camera"]["rect"]]
        self.assertLess(rects[0]["w"], card["card"]["w"] * 0.6)
        self.assertGreater(rects[-1]["w"], card["card"]["w"] * 0.8)
        steps = [distance(a, b) for a, b in zip(rects, rects[1:])]
        total = max(distance(rects[0], rects[-1]), 1)
        self.assertLess(max(steps), total * 0.6, "no jump")
        last = forward[-1][1]
        self.assertEqual((last["camera"]["phase"], last["camera"]["layer"]), ("idle", None))
        self.assertTrue(last["camera"]["liveVisible"])
        self.assertEqual(last["camera"]["liveFrame"], before)
        self.assertEqual(last["counters"]["cefResizesDuringCamera"], 0)
        self.assertEqual(self.active_id(), tabs[1])

        self.toggle()
        back = self.sample()
        self.wait_presentation("overview")
        moving = [s for _, s in back if s["camera"]["phase"] == "moving"]
        self.assertTrue(moving)
        for state in moving:
            self.assertFalse(state["camera"]["liveVisible"])
            self.assertEqual(state["camera"]["liveFrame"], before)
        node = next(n for n in self.ui()["overview"]["nodes"] if n["id"] == self.node_of(tabs[1])["id"])
        self.assertLess(moving[-1]["camera"]["rect"]["w"], card["card"]["w"] * 0.5)
        self.assertLess(distance(moving[-1]["camera"]["rect"], node["frame"]), 120)
        last = back[-1][1]
        self.assertEqual((last["camera"]["phase"], last["camera"]["layer"]), ("idle", None))
        self.assertEqual(last["counters"]["cefResizesDuringCamera"], 0)
        self.assertAlmostEqual(last["camera"]["canvasOpacity"], 1, places=2)
        save("motion-camera.json", {"forward": [s for _, s in forward][:40]})

    def test_reversing_midway_continues_from_where_the_layer_is(self):
        """VAL-MOTION-001"""
        tabs = self.overview_with_pages()
        self.click_node(tabs[2])
        samples = []

        def halfway(state):
            samples.append((time.time(), state))
            rect = state["camera"]["rect"]
            return rect is not None and rect["w"] > self.focus_state()["card"]["w"] * 0.4

        bs.wait_until(lambda: halfway(self.motion()), what="the camera at 40 %", timeout=3, interval=0.004)
        self.toggle()
        after = self.motion()
        fresh = [i for i in after["inFlight"] if i["kind"] == "camera"]
        self.assertTrue(fresh, "the reversal runs its own camera animation")
        self.assertEqual(self.ui()["presentation"], "overview")
        (t1, before), (t0, earlier) = samples[-1], samples[-2]
        speed = distance(before["camera"]["rect"], earlier["camera"]["rect"]) / max(t1 - t0, 1e-3)
        started = fresh[-1]
        gap = max(0, started["startedAtMs"] / 1000 - t1)
        page = self.focus_state()["card"]
        scale = started["from"]["scale"]
        self.assertGreater(scale, 0.2)
        self.assertGreater(scale, 0.0)
        self.assertLessEqual(abs(scale * page["w"] - before["camera"]["rect"]["w"]),
                             8 + speed * (gap + 0.03))
        self.settle()
        self.assertEqual(self.presentation(), "overview")
        self.assertIsNone(self.motion()["camera"]["layer"])
        self.assertEqual(self.motion()["counters"]["cefResizesDuringCamera"], 0)

    def test_six_toggles_in_600_ms_end_in_the_last_commands_presentation(self):
        """VAL-MOTION-001"""
        tabs = self.overview_with_pages()
        for count, expected in ((6, "overview"), (5, "focused"), (6, "focused")):
            started = time.time()
            for _ in range(count):
                self.toggle()
            self.assertLess(time.time() - started, 1.5)
            self.settle()
            state = self.motion()
            self.assertEqual(self.presentation(), expected)
            self.assertEqual(state["inFlight"], [])
            self.assertIsNone(state["camera"]["layer"])
            self.assertEqual(state["camera"]["liveVisible"], expected == "focused")
            self.assertEqual(state["counters"]["cefResizesDuringCamera"], 0)
        self.assertEqual(self.active_id(), tabs[0])

    def test_reduce_motion_swaps_with_a_short_fade_and_ends_in_the_same_frames(self):
        """VAL-MOTION-003"""
        tabs = self.overview_with_pages()
        self.click_node(tabs[1])
        self.sample()
        self.wait_presentation("focused")
        normal = {"page": self.focus_state()["liveFrame"]}
        self.toggle()
        self.sample()
        self.wait_presentation("overview")
        self.settle()
        normal["nodes"] = {n["id"]: n["frame"] for n in self.ui()["overview"]["nodes"]}

        self.call("test.reduceMotion", {"on": True})
        seen = []
        self.click_node(tabs[1])
        seen += self.sample()
        self.wait_presentation("focused")
        self.assertEqual(self.focus_state()["liveFrame"], normal["page"])
        self.toggle()
        seen += self.sample()
        self.wait_presentation("overview")
        self.settle()
        self.assertEqual({n["id"]: n["frame"] for n in self.ui()["overview"]["nodes"]},
                         normal["nodes"])
        page = normal["page"]
        for _, state in seen:
            self.assertTrue(state["reduceMotion"])
            for item in state["inFlight"]:
                self.assertNotEqual(item["purpose"], "camera", item)
                self.assertFalse(item["transformChanged"], item)
                self.assertLessEqual(item["durationMs"], 150, item)
            rect = state["camera"]["rect"]
            if rect:
                self.assertEqual(distance(rect, page), 0, "identity transform")
        self.assertTrue(any(s["inFlight"] for _, s in seen), "the crossfade ran")
        for item in self.motion()["recent"]:
            self.assertFalse(item["transformChanged"] and item["reduced"], item)
        self.call("test.reduceMotion", {"on": False})


LISTENER = ("window.__resizes = []; "
            "addEventListener('resize', () => window.__resizes.push([innerWidth, innerHeight]))")
RED, TEAL = "e63946", "2a9d8f"


class LeavingCaptureTests(MotionCase):
    """VAL-PREVIEW-001: the capture never resizes the page, and leaving waits for it."""

    def band(self, colour):
        address = url(f"band.html?c={colour}&t=Band")
        tab = self.call("open_tab", {"url": address})["id"]
        self.wait_loaded(address, tab)
        self.wait_node(tab)
        return tab

    def enter(self, tab):
        self.show_overview()
        self.settle()
        self.click_node(tab)
        self.wait_presentation("focused")
        self.settle()

    def log(self):
        return self.call("test.previews")["log"]

    def presentation_start(self, since):
        starts = [i["startedAtMs"] for i in self.motion()["recent"]
                  if i["startedAtMs"] >= since and (
                      i["kind"] == "camera" or (i["kind"] == "previewCrossfade" and i["target"] == "swap"))]
        return min(starts)

    def card_colour(self, tab):
        node = next(n for n in self.ui()["overview"]["nodes"] if n["id"] == self.node_of(tab)["id"])
        path = f"/tmp/bs-shot-{os.getpid()}-leaving.png"
        self.call("test.screenshot", {"path": path})
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        image = png.Image(path)
        scale = image.width / self.ui()["windowFrame"]["w"]
        f = node["frame"]
        return image.pixel(int((f["x"] + f["w"] / 2) * scale), int((f["y"] + f["h"] / 2) * scale))

    def check_no_resize(self, reduced):
        self.call("test.reduceMotion", {"on": reduced})
        tab = self.band(RED)
        self.enter(tab)
        before = len(self.log())
        self.call("test.devtools", {"tabId": tab, "method": "Page.enable"})
        self.call("test.devtools", {"tabId": tab, "method": "Page.addScriptToEvaluateOnNewDocument",
                                    "params": {"source": LISTENER}})
        self.navigate(tab, url(f"band.html?c={TEAL}&t=Band"))
        bs.wait_until(lambda: len(self.log()) > before, what="the navigation-settled capture")
        self.assertEqual(self.log()[-1]["outcome"], "stored")
        self.call("test.previewCapture", {"tabId": tab})
        self.toggle()
        self.wait_presentation("overview")
        self.settle()
        self.click_node(tab)
        self.wait_presentation("focused")
        self.settle()
        self.assertEqual(self.evaluate("window.__resizes", tab), [], "a capture resized the page")
        self.assertEqual(self.motion()["counters"]["cefResizesDuringCamera"], 0)

    def check_leaving_shows_the_changed_page(self, reduced):
        self.call("test.reduceMotion", {"on": reduced})
        tab = self.band(RED)
        self.enter(tab)
        self.assertEqual(self.call("test.previewCapture", {"tabId": tab})["outcome"], "stored")
        self.evaluate(f"document.getElementById('band').style.background = '#{TEAL}'", tab)
        timeouts = self.motion()["counters"]["previewCaptureTimeouts"]
        before = len(self.log())
        self.toggle()
        self.wait_presentation("overview")
        self.settle()
        self.assertEqual(len(self.log()), before + 1, "one leaving capture")
        record = self.log()[-1]
        self.assertEqual(record["outcome"], "stored")
        start = self.presentation_start(record["startedMs"])
        self.assertLessEqual(record["finishedMs"], start,
                             f"the overview started {record['finishedMs'] - start:.1f} ms before the capture ended")
        self.assertEqual(self.motion()["counters"]["previewCaptureTimeouts"], timeouts)
        self.assertTrue(png.close(self.card_colour(tab), png.hex_rgb(TEAL), 12))

    def test_a_capture_never_resizes_the_page(self):
        self.check_no_resize(True)

    def test_a_capture_never_resizes_the_page_with_motion(self):
        self.check_no_resize(False)

    def test_leaving_waits_for_the_capture_and_shows_the_changed_page(self):
        self.check_leaving_shows_the_changed_page(True)

    def test_leaving_waits_for_the_capture_and_shows_the_changed_page_with_motion(self):
        self.check_leaving_shows_the_changed_page(False)


class CameraGapTests(MotionCase):
    def timeouts(self):
        return self.motion()["counters"]["previewCaptureTimeouts"]

    def test_a_multi_packet_pinch_out_with_a_held_capture_ends_in_the_overview(self):
        """VAL-SPATIAL-009"""
        tabs = self.overview_with_pages()
        self.click_node(tabs[0])
        self.wait_presentation("focused")
        self.settle()
        self.call("test.previewHold", {"on": True})
        for _ in range(2):
            self.call("test.magnify", {"by": -0.1})
        self.wait_presentation("overview")
        self.settle()
        self.call("test.previewRelease")
        self.assertEqual(self.presentation(), "overview")

    def test_a_toggle_asked_again_while_the_page_is_being_left_takes_the_request_back(self):
        tabs = self.overview_with_pages()
        self.click_node(tabs[0])
        self.wait_presentation("focused")
        self.settle()
        self.call("test.previewHold", {"on": True})
        self.toggle()
        self.toggle()
        self.settle()
        self.call("test.previewRelease")
        self.assertEqual(self.presentation(), "focused")

    def test_a_capture_that_does_not_answer_is_cut_off_at_the_deadline_and_counted(self):
        """The safety net: the overview shows the stored preview and the toggle is not held up"""
        tabs = self.overview_with_pages()
        self.call("test.reduceMotion", {"on": True})
        self.click_node(tabs[0])
        self.wait_presentation("focused")
        self.settle()
        before = self.timeouts()
        self.call("test.previewHold", {"on": True})
        self.call("test.toggleTimings", {"reset": True})
        self.toggle()
        self.wait_presentation("overview")
        self.settle()
        (toggled,) = self.call("test.toggleTimings")["toggle"]
        self.assertLess(toggled, 200, "capture deadline + the Reduce Motion fade + two frames")
        self.assertEqual(self.timeouts(), before + 1)
        self.call("test.previewRelease")
        late = bs.wait_until(
            lambda: (lambda s: s if s["log"] and s["log"][-1]["outcome"] == "stored" else None)(
                self.call("test.previews")),
            what="the late capture stored")
        self.assertTrue(late["log"][-1]["documentKey"])
        self.call("test.reduceMotion", {"on": False})

    def test_a_capture_landing_during_the_arrival_does_not_extend_the_toggle(self):
        """VAL-SPATIAL-013: a late preview is applied under the arriving overview, not faded in"""
        tabs = self.overview_with_pages()
        self.call("test.reduceMotion", {"on": True})
        self.click_node(tabs[0])
        self.wait_presentation("focused")
        self.settle()
        stored = lambda: sum(r["outcome"] == "stored" for r in self.call("test.previews")["log"])
        before = stored()
        self.call("test.toggleTimings", {"reset": True})
        for done in range(1, 13):
            self.toggle()
            bs.wait_until(lambda: len(self.call("test.toggleTimings")["toggle"]) == done,
                          what="the toggle to settle")
        leaving = self.call("test.toggleTimings")["toggle"][0::2]
        self.assertLess(max(leaving), 140, leaving)
        bs.wait_until(lambda: stored() - before >= 6, what="every page's last look to land")
        self.call("test.reduceMotion", {"on": False})

    def type_after_click(self, tab, before):
        """Clicks `tab`'s node from the overview over `before` and types at once."""
        self.evaluate("var b = document.getElementById('box'); b.value = ''; b.focus()", tab)
        self.focus(before)
        self.show_overview()
        self.settle()
        epoch = next(t for t in self.ui()["tabs"] if t["id"] == tab)["epoch"]
        text = "order-0123456789"
        self.click_node(tab)
        self.call("test.type", {"text": text})
        bs.wait_until(lambda: self.evaluate("document.getElementById('box').value", tab) == text,
                      what="every key in the page")
        after = next(t for t in self.ui()["tabs"] if t["id"] == tab)
        self.assertEqual(after["epoch"], epoch + len(text))
        self.assertEqual(after["controller"], "human")
        self.assertEqual(self.active_id(), tab)
        self.assertEqual(self.motion()["camera"]["phase"], "idle")

    def test_keys_typed_right_after_selecting_a_page_reach_it_in_order(self):
        """Animation plan row 1: nothing is dropped during entry"""
        blank = self.tab_ids()[0]
        typing = self.open_page("typing", "input.html")
        other = self.open_page("other", "input.html")
        self.call("test.closeTab", {"tabId": blank})
        self.row([typing, other])
        self.type_after_click(typing, other)

    def test_keys_typed_after_selecting_a_page_with_neighbours_reach_it_in_order(self):
        """The click changes the layout (a page with context), which must not cancel the entry"""
        blank = self.tab_ids()[0]
        opener = self.open_page("opener", "popups.html")
        plain = self.open_page("plain")
        self.focus(opener)
        self.show_page()
        popup = self.popups(opener, 1)[0]
        self.call("test.closeTab", {"tabId": blank})
        self.row([opener, popup, plain])
        self.type_after_click(popup, plain)

    def test_a_resize_during_the_flight_lands_the_page_on_the_new_layout_without_a_cef_resize(self):
        """VAL-MOTION-002"""
        tabs = self.overview_with_pages()
        self.click_node(tabs[1])
        bs.wait_until(lambda: self.motion()["camera"]["phase"] == "moving", what="the flight")
        self.call("test.windowSize", {"w": 1200, "h": 800})
        self.settle()
        self.wait_presentation("focused")
        state = self.motion()
        self.assertEqual(state["counters"]["cefResizesDuringCamera"], 0)
        self.assertTrue(state["camera"]["liveVisible"])
        self.assertIsNone(state["camera"]["layer"])
        self.assert_card_is_page()
        self.wait_renderer_follows_view(tabs[1])
        self.call("test.windowSize", {"w": 1440, "h": 900})
        self.wait_renderer_follows_view(tabs[1])

    def test_a_resize_while_the_overview_hides_every_page_reaches_the_renderer(self):
        tabs = self.overview_with_pages()
        self.call("test.windowSize", {"w": 1200, "h": 800})
        self.click_node(tabs[1])
        self.wait_presentation("focused")
        self.settle()
        self.wait_renderer_follows_view(tabs[1])
        self.call("test.windowSize", {"w": 1440, "h": 900})
        self.wait_renderer_follows_view(tabs[1])


class SmallMotionTests(MotionCase):
    def test_a_page_opened_from_another_enters_from_it_and_its_trail_draws_once(self):
        """VAL-MOTION-005"""
        opener = self.open_page("opener", "popups.html")
        child = self.popups(opener, 1)[0]
        bs.wait_until(lambda: self.edges(), what="an edge")
        self.assertEqual(self.recent("nodeEnter") + self.recent("trailDraw"), [],
                         "nothing animates while the page is in front")
        self.show_overview()
        self.settle()
        entered = self.recent("nodeEnter")
        arrivals = {i["target"] for i in entered}
        self.assertEqual(arrivals, {self.node_of(opener)["id"], self.node_of(child)["id"]})
        item = next(i for i in entered if i["target"] == self.node_of(child)["id"])
        self.assertEqual((item["purpose"], item["curve"], item["durationMs"]),
                         ("node-entrance", "easeOut", 240))
        self.assertIn("opacity", item["keyPaths"])
        self.assertIn("transform", item["keyPaths"])
        self.assertLess(item["from"]["scale"], 1)
        drawn = self.recent("trailDraw")
        self.assertEqual(len(drawn), 1)
        self.assertEqual(drawn[0]["keyPaths"], ["strokeEnd"])
        self.assertEqual((drawn[0]["purpose"], drawn[0]["curve"]), ("trail-draw", "easeOut"))
        self.assertLessEqual(drawn[0]["durationMs"], 300)
        self.call("test.scroll", {"dx": 5, "dy": 0})
        self.show_page()
        self.settle()
        self.show_overview()
        self.settle()
        self.assertEqual(len(self.recent("nodeEnter")), 2, "nothing enters twice")
        self.assertEqual(len(self.recent("trailDraw")), 1, "re-drawing the same trail replays nothing")

    def test_a_page_opened_while_the_overview_shows_enters_without_a_source(self):
        """VAL-MOTION-005"""
        self.pages(1)
        self.show_overview()
        self.settle()
        entering = self.open_page("second", activate=False)
        entered = [i for i in self.recent("nodeEnter") if i["target"] == self.node_of(entering)["id"]]
        self.assertEqual(len(entered), 1)
        self.assertEqual(entered[0]["durationMs"], 240)
        self.call("test.reduceMotion", {"on": True})
        again = self.open_page("third", activate=False)
        reduced = [i for i in self.recent("nodeEnter") if i["target"] == self.node_of(again)["id"]]
        self.assertEqual(len(reduced), 1)
        self.assertEqual((reduced[0]["durationMs"], reduced[0]["transformChanged"]), (120, False))

    def test_a_stale_preview_dims_and_a_fresh_one_fades_in(self):
        """VAL-MOTION-005"""
        self.call("test.previews", {"auto": False})
        tab = self.pages(1)[0]
        self.assertEqual(self.call("test.previewCapture", {"tabId": tab})["outcome"], "stored")
        self.show_overview()
        self.settle()
        self.call("test.devtools", {"tabId": tab, "method": "Page.reload", "params": {}})
        stale = bs.wait_until(lambda: self.recent("previewStale") or None, what="the dimming")
        self.assertEqual(stale[0]["keyPaths"], ["opacity"])
        self.assertLessEqual(stale[0]["durationMs"], 300)
        bs.wait_until(lambda: self.node_of(tab)["previewState"] == "stale", what="stale")
        self.wait_loaded(self.tabs()[0]["url"], tab)
        self.show_page()
        self.settle()
        self.assertEqual(self.call("test.previewCapture", {"tabId": tab})["outcome"], "stored")
        self.show_overview()
        faded = bs.wait_until(lambda: self.recent("previewCrossfade") or None, what="the crossfade")
        self.assertEqual((faded[0]["purpose"], faded[0]["curve"]), ("preview-crossfade", "easeOut"))
        self.assertLessEqual(faded[0]["durationMs"], 300)
        self.settle()

    def test_pressing_the_command_button_scales_it_and_releases_within_150_ms(self):
        """VAL-MOTION-005"""
        self.pages(1)
        self.show_overview()
        self.settle()
        self.assertEqual(self.recent("buttonPress"), [])
        self.call("test.drag", {"target": "commandButton", "dx": 0, "dy": 0, "release": False})
        held = bs.wait_until(
            lambda: (lambda s: s if s["camera"]["commandButtonScale"] < 0.99 else None)(
                self.motion()), what="the button pressed", timeout=3)["camera"]
        time.sleep(0.2)
        scale = self.motion()["camera"]["commandButtonScale"]
        self.assertGreaterEqual(scale, 0.95)
        self.assertLessEqual(scale, 0.99)
        self.assertIsNotNone(held)
        self.call("test.mouseUp")
        released = time.time()
        bs.wait_until(lambda: self.motion()["camera"]["commandButtonScale"] == 1, what="released",
                      timeout=2)
        self.assertLess(time.time() - released, 0.5)
        presses = self.recent("buttonPress")
        self.assertTrue(presses)
        self.assertEqual(presses[0]["purpose"], "button-press")
        self.assertLessEqual(max(p["durationMs"] for p in presses), 150)
        self.settle()

    def test_dragging_a_node_lifts_it_and_drops_it_with_a_spring(self):
        """VAL-MOTION-004"""
        tabs = self.overview_with_pages(2)
        node = self.node_of(tabs[0])["id"]
        self.call("test.drag", {"target": f"node:{node}", "dx": 90, "dy": 40, "steps": 6,
                                "release": False})
        lifted = bs.wait_until(lambda: self.recent("nodePickup") or None, what="the pickup")
        self.assertEqual((lifted[0]["purpose"], lifted[0]["curve"]), ("button-press", "easeOut"))
        self.assertLessEqual(lifted[0]["durationMs"], 150)
        self.call("test.mouseUp")
        dropped = bs.wait_until(lambda: self.recent("nodeDrop") or None, what="the drop")
        self.assertEqual(dropped[0]["curve"], "spring")
        self.assertLessEqual(dropped[0]["bounce"], 0.2)
        self.settle()

    def test_a_pinch_past_the_limit_stretches_and_springs_back(self):
        """VAL-MOTION-004"""
        self.overview_with_pages(2)
        self.call("test.canvas", {"viewport": {"zoom": 1.5}})
        stretched = 1.0
        for _ in range(6):
            self.call("test.magnify", {"by": 0.1})
            stretched = max(stretched, self.motion()["camera"]["stretchScale"])
        self.assertGreater(stretched, 1.0)
        self.assertLessEqual(stretched, 1.13)
        self.assertEqual(self.canvas()["viewport"]["zoom"], 1.5)
        bs.wait_until(lambda: self.recent("rubberBack") or None, what="the spring back", timeout=3)
        item = self.recent("rubberBack")[0]
        self.assertEqual((item["purpose"], item["curve"]), ("camera", "spring"))
        self.assertLessEqual(item["bounce"], 0.2)
        self.assertLessEqual(item["durationMs"], 450)
        self.settle()
        self.assertEqual(self.motion()["camera"]["stretchScale"], 1)


class FirstRunTests(MotionCase):
    def test_the_empty_overview_arrives_in_stages_once(self):
        """VAL-MOTION-005"""
        state = self.motion()
        items = [i for i in state["recent"] + state["inFlight"] if i["kind"] == "firstRun"]
        self.assertEqual(len(items), 1)
        self.assertEqual((items[0]["purpose"], items[0]["curve"]), ("node-entrance", "easeOut"))
        self.assertLessEqual(items[0]["durationMs"], 300)
        self.assertIn("opacity", items[0]["keyPaths"])
        self.assertIn("transform", items[0]["keyPaths"])


class NeverAnimateTests(MotionCase):
    def silent(self, step, action, after=0.3):
        baseline = len(self.motion()["recent"])
        action()
        end = time.time() + after
        while time.time() < end:
            state = self.motion()
            self.assertEqual(state["inFlight"], [], step)
            self.assertEqual(state["camera"]["phase"], "idle", step)
        self.assertEqual(len(state["recent"]), baseline, step)

    def run_paths(self):
        tabs = self.pages(3)
        self.show_page()
        self.settle()
        self.silent("launcher open", lambda: self.key("t", "cmd"))
        self.wait_launcher(True)
        self.silent("arrow keys", lambda: self.key("ArrowDown"))
        self.silent("typing", lambda: self.call("test.type", {"text": "pa"}))
        self.silent("launcher close", lambda: self.key("Escape"))
        self.wait_launcher(False)
        self.silent("cmd-1", lambda: self.key("1", "cmd"))
        self.silent("cmd-2", lambda: self.key("2", "cmd"))
        self.silent("ctrl-tab", lambda: self.key("Tab", "ctrl"))
        self.silent("reload", lambda: self.key("r", "cmd"))
        self.silent("find open", lambda: self.key("f", "cmd"))
        self.silent("find close", lambda: self.key("Escape"))
        self.silent("close page", lambda: self.key("w", "cmd"))
        self.silent("idle", lambda: time.sleep(3), after=0.1)
        return tabs

    def test_frequent_keyboard_paths_never_animate(self):
        """VAL-TABS-012"""
        self.run_paths()

    def test_frequent_keyboard_paths_never_animate_with_reduce_motion(self):
        """VAL-TABS-012"""
        self.call("test.reduceMotion", {"on": True})
        self.run_paths()

    def test_reload_from_the_overview_dims_the_stale_preview_in_place(self):
        """VAL-TABS-012"""
        self.call("test.previews", {"auto": False})
        tab = self.pages(1)[0]
        self.assertEqual(self.call("test.previewCapture", {"tabId": tab})["outcome"], "stored")
        self.show_overview()
        self.settle()
        self.silent("reload in the overview", lambda: self.key("r", "cmd"), after=0.8)

    def test_a_tab_shortcut_during_the_flight_ends_it_on_the_new_page(self):
        """VAL-TABS-012"""
        tabs = self.overview_with_pages()
        self.click_node(tabs[1])
        bs.wait_until(lambda: self.motion()["camera"]["phase"] == "moving", what="the flight")
        self.key("3", "cmd")
        camera = self.motion()["camera"]
        self.assertEqual((camera["phase"], camera["layer"], camera["liveVisible"]),
                         ("idle", None, True))
        self.assertEqual([i for i in self.motion()["inFlight"] if i["kind"] == "camera"], [])


class RegistryTests(MotionCase):
    def test_every_animation_has_a_purpose_the_strong_ease_out_or_a_calm_spring(self):
        """VAL-MOTION-004"""
        tabs = self.overview_with_pages(3)
        self.click_node(tabs[1])
        self.sample()
        self.toggle()
        self.sample()
        node = self.node_of(tabs[0])["id"]
        self.call("test.drag", {"target": f"node:{node}", "dx": 60, "dy": 30})
        self.settle()
        state = self.motion()
        save("motion-registry.json", state["recent"])
        self.assertGreater(len(state["recent"]), 3)
        for item in state["recent"]:
            self.assertIn(item["purpose"], PURPOSES, item)
            self.assertIn(item["curve"], ("easeOut", "spring"), item)
            self.assertLessEqual(item["bounce"], 0.2, item)
            self.assertLessEqual(item["durationMs"], 450 if item["purpose"] == "camera" else 300,
                                 item)
        self.assertEqual(state["infiniteLoops"], [])

    # The only places in the app that may match: MuseMark's pulse, Trail's flow and the orb's
    # spin are the infinite animations; the rest are not animations (a 3 s guard on a dropped synthetic event, the notice's
    # dismissal, the toggle measurement and the frame probe test hook).
    ALLOWED = (("MuseMark.swift", "repeatCount = .infinity"),
               ("Trail.swift", "repeatCount = .infinity"),
               ("ThinkingOrbView.swift", "repeatCount = .infinity"),
               ("BarestateApplication.swift", "asyncAfter(deadline: .now() + 3)"),
               ("WindowRootView.swift", "noticeTimer"),
               ("AppController.swift", "ToggleTimer"),
               ("AppController+Overview.swift", "ToggleTimer"),
               ("TestHooksCanvas.swift", "CADisplayLink"))

    def test_no_timer_drives_an_animation_in_the_app_code(self):
        """VAL-MOTION-004"""
        lines = subprocess.run(
            ["rg", "-n", r"Timer|asyncAfter|CADisplayLink|repeatCount", SOURCES,
             "--glob", "*.swift"], capture_output=True, text=True).stdout.splitlines()
        found = [line for line in lines
                 if not any(os.path.basename(line.split(":", 1)[0]) == name and text in line
                            for name, text in self.ALLOWED)]
        self.assertEqual(found, [], found)
        self.assertTrue(any("MuseMark.swift" in line for line in lines), "the guard saw no pulse")


if __name__ == "__main__":
    unittest.main()
