"""The polish motion (VAL-POL-001..004, VAL-MOTION-004): the first preview on a card, the Muse
activity panel and its step lines, the notice, the status dot, the command button under an
approval card and the flowing trail. The model is held in every test, so `test.runState` and
`test.runStep` stand in for what a run does. Timings are the registry's, read from `test.motion`."""
import unittest

import bs
from appcase import save
from test_run import RunBase
from test_run_motion import RunMotionCase

STRONG = "easeOut"


class PolishCase(RunMotionCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(self.call, "test.reduceMotion", {"on": False})

    def reduce(self, on):
        self.call("test.reduceMotion", {"on": on})
        self.rest()
        self.mark()

    def wait_item(self, kind, count=1):
        return bs.wait_until(
            lambda: (lambda s: s if len(s) >= count else None)(self.seen(kind)),
            what=f"{kind} in the registry")

    def check(self, item, purpose, ms, paths=("opacity",), transform=False):
        self.assertEqual((item["purpose"], item["curve"], item["durationMs"]),
                         (purpose, STRONG, ms), item)
        self.assertEqual(set(item["keyPaths"]), set(paths), item)
        self.assertEqual(item["transformChanged"], transform, item)


class FirstPreviewTests(PolishCase):
    def placeholder_card(self):
        """A page in the overview whose first preview is still held in the renderer's reply."""
        self.call("test.previews", {"auto": False})
        page = self.open_page("article.html")
        self.call("test.previewHold", {"on": True})
        self.assertEqual(self.call("test.previewCapture", {"tabId": page["id"]})["outcome"], "held")
        self.open_page("launcher.html")
        self.show("overview")
        self.mark()
        node = self.node_of(page["id"])["id"]
        card = next(n for n in self.ui()["overview"]["nodes"] if n["id"] == node)
        self.assertTrue(card["placeholder"], card)
        return page, node

    def capture(self, page):
        self.call("test.previewRelease")
        bs.wait_until(lambda: self.node_of(page["id"])["previewState"] == "fresh",
                      what="the preview to land")
    def test_the_first_preview_fades_in_over_the_placeholder_and_a_pan_replays_nothing(self):
        """VAL-POL-001"""
        page, node = self.placeholder_card()
        self.capture(page)
        fade, = self.wait_item("previewCrossfade")
        self.assertEqual(fade["target"], node)
        self.check(fade, "preview-crossfade", 200)
        self.rest()
        card = next(n for n in self.ui()["overview"]["nodes"] if n["id"] == node)
        self.assertFalse(card["placeholder"], card)
        self.mark()
        self.call("test.scroll", {"dx": 4000, "dy": 0})
        self.call("test.scroll", {"dx": -4000, "dy": 0})
        self.rest()
        self.assertEqual(self.seen("previewCrossfade"), [], "a re-shown card fades again")
        save("polish-first-preview.json", fade)

    def test_with_reduce_motion_the_first_preview_fades_in_shorter(self):
        """VAL-POL-001"""
        page, _ = self.placeholder_card()
        self.reduce(True)
        self.capture(page)
        fade, = self.wait_item("previewCrossfade")
        self.check(fade, "preview-crossfade", 120)
        self.assertTrue(fade["reduced"])


class ActivityTests(PolishCase):
    def open_run_panel(self):
        page = self.open_page("launcher.html")
        run = self.start("Click the Next button", tab=page["id"])
        self.state(run["runId"], "running")
        self.key("Escape")
        self.open_activity()
        self.rest()
        self.mark()
        return page, run

    def step(self, run, page, text):
        self.call("test.runStep", {"runId": run["runId"], "text": text, "tabId": page["id"],
                                   "state": "confirmed"})

    def test_a_new_step_line_fades_in_alone_and_the_panel_fades_out(self):
        """VAL-POL-002"""
        page, run = self.open_run_panel()
        self.step(run, page, "Look at the page")
        first, = self.wait_item("stepIn")
        self.check(first, "panel-fade", 140)
        self.rest()
        self.step(run, page, "Click Next")
        second = self.wait_item("stepIn", 2)[-1]
        self.check(second, "panel-fade", 140)
        self.rest()
        self.mark()
        self.close_activity()
        gone, = self.wait_item("activityOut")
        self.check(gone, "panel-fade", 100)
        self.rest()
        self.assertFalse(self.activity()["open"])
        self.assertFalse(self.activity()["visible"])
        self.mark()
        self.open_activity()
        self.rest()
        self.assertEqual(self.seen("stepIn"), [], "the first draw of a panel adds no step motion")
        self.assertTrue(self.activity()["visible"])
        save("polish-activity.json", [first, second, gone])

    def test_a_step_fade_is_not_interrupted_by_the_next_update(self):
        """VAL-POL-002: rows update in place, so a fade finishes as the next step lands."""
        page, run = self.open_run_panel()
        self.step(run, page, "Look at the page")
        self.step(run, page, "Click Next")
        first, second = self.wait_item("stepIn", 2)
        self.assertFalse(first["interrupted"], first)
        self.assertFalse(second["interrupted"], second)
        self.rest()
        texts = [e["text"] for e in self.activity()["entries"]]
        self.assertEqual(texts[-2:], ["Look at the page", "Click Next"])

    def test_reopening_during_the_fade_out_keeps_the_panel_shown(self):
        """VAL-POL-002"""
        self.open_run_panel()
        self.close_activity()
        self.wait_item("activityOut")
        self.open_activity()
        self.rest()
        self.assertTrue(self.activity()["visible"])
        self.assertTrue(self.activity()["open"])

    def test_with_reduce_motion_the_panel_and_its_lines_fade_in_120_ms_without_travel(self):
        """VAL-POL-002"""
        page, run = self.open_run_panel()
        self.reduce(True)
        self.step(run, page, "Look at the page")
        self.check(self.wait_item("stepIn")[0], "panel-fade", 120)
        self.rest()
        self.close_activity()
        self.check(self.wait_item("activityOut")[0], "panel-fade", 120)


class NoticeTests(PolishCase):
    def notice(self, text="Reopened closed page"):
        self.call("test.notice", {"text": text})

    def test_a_notice_fades_in_and_out_when_the_camera_is_idle(self):
        """VAL-POL-003"""
        self.open_page("launcher.html")
        self.show("overview")
        self.mark()
        self.notice()
        fade, = self.wait_item("notice")
        self.check(fade, "notice-fade", 140)
        self.rest()
        self.assertEqual(self.ui()["overview"]["notice"]["text"], "Reopened closed page")
        out = self.wait_item("notice", 2)
        self.check(out[1], "notice-fade", 140)
        self.rest()
        self.assertFalse(self.ui()["overview"]["notice"]["visible"])

    def test_a_notice_shown_while_the_camera_moves_starts_no_animation(self):
        """VAL-POL-003"""
        self.open_page("launcher.html")
        self.open_page("article.html")
        self.show("overview")
        self.mark()
        self.key("\\", "cmd", "shift")
        self.notice()
        self.assertEqual(self.motion()["camera"]["phase"] != "idle", True)
        self.assertEqual(self.seen("notice"), [])
        self.assertTrue(self.ui()["overview"]["notice"]["visible"])
        self.rest()

    def test_with_reduce_motion_the_notice_fades_in_120_ms(self):
        """VAL-POL-003"""
        self.open_page("launcher.html")
        self.show("overview")
        self.reduce(True)
        self.notice()
        self.check(self.wait_item("notice")[0], "notice-fade", 120)


class StatusDotTests(PolishCase):
    def test_the_dot_fades_in_with_its_label_and_not_again_on_a_new_state(self):
        """VAL-POL-003"""
        page = self.open_page("launcher.html")
        self.show("overview")
        self.mark()
        run = self.start("Read this page", tab=page["id"])
        dot, = self.wait_item("statusDot")
        self.check(dot, "status-fade", 140)
        self.wait_item("museLabel")
        self.rest()
        self.mark()
        self.state(run["runId"], "running")
        bs.wait_until(lambda: self.seen("museLabel"), what="the label to change")
        self.rest()
        self.assertEqual(self.seen("statusDot"), [])

    def test_with_reduce_motion_the_dot_fades_in_120_ms(self):
        """VAL-POL-003"""
        page = self.open_page("launcher.html")
        self.show("overview")
        self.reduce(True)
        self.start("Read this page", tab=page["id"])
        self.check(self.wait_item("statusDot")[0], "status-fade", 120)


class TrailFlowTests(PolishCase):
    def run_with_trail(self):
        owner = self.open_page("launcher.html")
        used = self.open_page("article.html")
        self.show("overview")
        run = self.start("Read the other page", tab=owner["id"])
        self.state(run["runId"], "running")
        request = self.call("request_control", {"sessionId": run["sessionId"], "tabId": used["id"]})
        if request["state"] != "granted":
            self.call("control.decide", {"requestId": request["requestId"], "allow": True})
        self.call("test.runTool", {"runId": run["runId"], "name": "observe",
                                   "arguments": {"tabId": used["id"]}})
        self.owner = self.node_of(owner["id"])["id"]
        bs.wait_until(lambda: self.trail(), what="the Muse trail")
        return run

    def trail(self):
        return [e for e in self.ui()["overview"]["edges"]
                if e["kind"] == "museUsed" and e["from"] == self.owner]

    def flowing(self):
        return [l for l in self.loops() if l["kind"] == "trailFlow"]

    def phase(self):
        return self.trail()[0]["dashPhase"]

    def test_the_newest_edge_flows_while_the_run_works_and_stops_when_it_ends(self):
        """VAL-POL-004"""
        for end, reason in (("completed", None), ("stopped", None), ("failed", "no model API key")):
            run = self.run_with_trail()
            loop = bs.wait_until(lambda: (self.flowing() or [None])[0], what="the trail to flow")
            self.assertEqual((loop["purpose"], loop["curve"], loop["keyPaths"], loop["runId"],
                              loop["surface"], loop["durationS"]),
                             ("trail-flow", "linear", ["lineDashPhase"], run["runId"], "overview",
                              1.2))
            first = self.phase()
            save(f"polish-trail-flow-{end}.json", loop)
            bs.wait_until(lambda: self.phase() != first, timeout=3, what="the dash phase to move")
            self.assertEqual(len(self.flowing()), 1)
            self.state(run["runId"], end, reason)
            bs.wait_until(lambda: not self.flowing(), what="the flow to stop", timeout=2)
            self.assertEqual(self.phase(), 0, "the static dash comes back")
            self.stop_all()

    def test_the_flow_follows_the_page_in_use_when_a_run_returns_to_an_earlier_one(self):
        """VAL-POL-004: A->B, A->C, then another call on B adds no edge; the flow moves back to A->B."""
        owner = self.open_page("launcher.html")
        b = self.open_page("article.html")
        c = self.open_page("input.html")
        self.show("overview")
        run = self.start("Read the other pages", tab=owner["id"])
        self.state(run["runId"], "running")
        for page in (b, c):
            request = self.call("request_control",
                                {"sessionId": run["sessionId"], "tabId": page["id"]})
            if request["state"] != "granted":
                self.call("control.decide", {"requestId": request["requestId"], "allow": True})
        self.owner = self.node_of(owner["id"])["id"]
        node_b, node_c = self.node_of(b["id"])["id"], self.node_of(c["id"])["id"]

        def observe(page):
            self.call("test.runTool", {"runId": run["runId"], "name": "observe",
                                       "arguments": {"tabId": page["id"]}})

        def flowing_into():
            loops = self.flowing()
            return loops[0]["target"].split(">")[1] if len(loops) == 1 else None

        observe(b)
        bs.wait_until(lambda: flowing_into() == node_b, what="the flow on A->B")
        observe(c)
        bs.wait_until(lambda: flowing_into() == node_c, what="the flow on A->C")
        observe(b)
        bs.wait_until(lambda: flowing_into() == node_b, what="the flow back on A->B")
        self.assertEqual(len(self.trail()), 2, "the repeated use added no edge")
        save("polish-trail-flow-return.json", self.flowing())
        self.stop_all()

    def stop_all(self):
        for run in self.runs():
            if run["state"] not in ("completed", "stopped", "failed"):
                self.call("run.stop", {"runId": run["runId"]})

    def test_the_flow_survives_a_zoom(self):
        """VAL-POL-004: a zoom re-keys the loop; the dash keeps moving on the same edge."""
        self.run_with_trail()
        bs.wait_until(lambda: self.flowing(), what="the trail to flow")
        zoom = self.ui()["canvas"]["viewport"]["zoom"]
        self.key("-", "cmd")
        bs.wait_until(lambda: self.ui()["canvas"]["viewport"]["zoom"] < zoom,
                      what="Cmd-- to zoom out")
        bs.wait_until(lambda: not self.call("test.motion")["inFlight"], what="the camera at rest")
        self.assertEqual(len(self.flowing()), 1, "one flow, re-keyed for the new zoom")
        first = self.phase()
        bs.wait_until(lambda: self.phase() != first, timeout=3,
                      what="the dash phase to keep moving after the zoom")

    def test_there_is_no_flow_with_reduce_motion(self):
        """VAL-POL-004"""
        self.reduce(True)
        self.run_with_trail()
        self.assertEqual(self.flowing(), [])
        self.assertEqual(self.phase(), 0)

    def test_the_flow_follows_the_overview_on_and_off_screen(self):
        """VAL-POL-004"""
        self.run_with_trail()
        bs.wait_until(self.flowing, what="the trail to flow")
        self.show("focused")
        bs.wait_until(lambda: not self.flowing(), what="the flow to stop", timeout=2)
        self.show("overview")
        bs.wait_until(self.flowing, what="the trail to flow again")


class ButtonFadeTests(RunBase):
    def fades(self, after):
        return [m for m in self.app.call("test.motion")["recent"]
                if m["kind"] == "buttonFade" and m["id"] > after]

    def button_visible(self):
        return self.ui()["commandButton"]["visible"]

    def test_the_command_button_fades_out_under_an_approval_card_and_back_when_it_is_gone(self):
        """VAL-POL-003"""
        self.addCleanup(self.app.call, "test.windowSize", {"w": 1440, "h": 900})
        self.app.call("test.windowSize", {"w": 1100, "h": 640})
        mark = max([m["id"] for m in self.app.call("test.motion")["recent"]] or [0])
        self.assertTrue(self.button_visible())
        run = self.start()
        self.quote_for(run)
        self.wait_card()
        out, = bs.wait_until(lambda: (lambda f: f if len(f) == 1 else None)(self.fades(mark)),
                             what="the button to fade out")
        self.assertEqual((out["purpose"], out["curve"], out["durationMs"], out["keyPaths"],
                          out["to"]), ("status-fade", "easeOut", 140, ["opacity"], 0))
        bs.wait_until(lambda: not self.button_visible(), what="the button to be hidden")
        self.app.call("run.stop", {"runId": run["runId"]})
        self.card_gone()
        back = bs.wait_until(lambda: (lambda f: f if len(f) == 2 else None)(self.fades(mark)),
                             what="the button to fade back")[1]
        self.assertEqual((back["durationMs"], back["to"]), (140, 1))
        self.assertTrue(self.button_visible())

class OrbTests(PolishCase):
    def orb(self):
        return self.ui()["orb"]

    def orb_loops(self):
        return [l for l in self.loops() if l["kind"] == "thinkingOrb"]

    def test_the_orb_thinks_then_works_then_fades_out_when_the_run_ends(self):
        """VAL-POL-009"""
        page = self.open_page("launcher.html")
        run = self.start("Read this page", tab=page["id"])
        orb = bs.wait_until(lambda: self.orb() if self.orb()["visible"] else None,
                            what="the thinking orb")
        self.assertEqual((orb["variant"], orb["runId"], orb["spinning"]),
                         ("thinking", run["runId"], True))
        loop = bs.wait_until(lambda: (self.orb_loops() or [None])[0], what="the orbit")
        self.assertEqual((loop["purpose"], loop["curve"], loop["runId"], loop["surface"],
                          loop["durationS"]),
                         ("thinking-orb", "linear", run["runId"], "chrome", 2.4))
        self.state(run["runId"], "running")
        self.call("test.runStep", {"runId": run["runId"], "text": "Click Next",
                                   "tabId": page["id"]})
        bs.wait_until(lambda: self.orb()["variant"] == "working", what="the working variant")
        self.assertEqual(len(self.orb_loops()), 1, "one orbit, re-keyed for the variant")
        self.assertEqual(self.orb_loops()[0]["durationS"], 0.9)
        self.assertTrue(self.orb()["spinning"])
        self.mark()
        self.state(run["runId"], "completed")
        bs.wait_until(lambda: not self.orb()["visible"], what="the orb to leave")
        self.assertEqual(self.orb_loops(), [])
        self.assertFalse(self.orb()["spinning"], "nothing animates once the orb is hidden")
        self.rest()
        fades = [i for i in self.items() if i["kind"] == "thinkingOrb"]
        out = next(i for i in fades if i["to"] == 0)
        self.assertEqual((out["purpose"], out["curve"], out["durationMs"], out["keyPaths"]),
                         ("thinking-orb", "easeOut", 140, ["opacity"]))
        save("polish-orb.json", {"loop": loop, "out": out})

    def test_the_orb_is_static_with_reduce_motion(self):
        """VAL-POL-009"""
        page = self.open_page("launcher.html")
        self.reduce(True)
        run = self.start("Read this page", tab=page["id"])
        orb = bs.wait_until(lambda: self.orb() if self.orb()["visible"] else None,
                            what="the thinking orb")
        self.assertEqual((orb["variant"], orb["spinning"]), ("thinking", False))
        self.assertEqual(self.orb_loops(), [], "no orbit with Reduce Motion")
        self.state(run["runId"], "stopped")
        bs.wait_until(lambda: not self.orb()["visible"], what="the orb to leave")
        self.assertFalse(self.orb()["spinning"])

    def test_with_reduce_motion_the_working_variant_stays_static(self):
        """VAL-POL-009: the variant switches with no animation at all under Reduce Motion."""
        page = self.open_page("launcher.html")
        self.reduce(True)
        run = self.start("Read this page", tab=page["id"])
        bs.wait_until(lambda: self.orb()["visible"], what="the thinking orb")
        self.mark()
        self.state(run["runId"], "running")
        self.call("test.runStep", {"runId": run["runId"], "text": "Click Next",
                                   "tabId": page["id"]})
        bs.wait_until(lambda: self.orb()["variant"] == "working", what="the working variant")
        self.assertFalse(self.orb()["spinning"])
        self.assertEqual(self.orb_loops(), [])
        self.assertEqual(self.seen("thinkingOrb"), [], "the restyle does not animate")

    def test_a_click_on_the_page_takes_over_and_the_orb_leaves(self):
        """VAL-POL-009"""
        page = self.open_page("launcher.html")
        run = self.start("Read this page", tab=page["id"])
        self.state(run["runId"], "running")
        bs.wait_until(lambda: self.orb()["visible"], what="the thinking orb")
        self.assertEqual(self.ui()["tabs"][-1]["controller"], "agent")
        self.call("test.click", {"tabId": page["id"], "x": 200, "y": 200})
        stopped = bs.wait_until(
            lambda: (lambda r: r if r["state"] == "stopped" else None)(self.run_of(run["runId"])),
            what="the run to be taken over")
        self.assertEqual(stopped["reason"], "taken-over")
        bs.wait_until(lambda: not self.orb()["visible"], what="the orb to leave")
        self.assertEqual(self.orb_loops(), [])

    def test_with_no_run_the_orb_is_hidden_and_nothing_animates(self):
        """VAL-POL-005"""
        self.open_page("launcher.html")
        self.rest()
        self.assertFalse(self.orb()["visible"])
        self.assertFalse(self.orb()["spinning"])
        self.assertEqual(self.loops(), [])


if __name__ == "__main__":
    unittest.main()
