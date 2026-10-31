"""Motion that follows a run's state (VAL-MOTION-006) and its Reduce Motion variant (VAL-MOTION-003).

The model is held in every test, so `test.runState` and `test.runStep` stand in for the states a
run reaches. Timing limits are asserted only below a 1-minute load of 8; the load is saved next to
the samples. The live acceptance checks are in test_run_acceptance.py."""
import os
import time
import unittest

import bs
from appcase import save
from test_motion import PURPOSES, MotionCase
from test_run import RunBase
from test_tasks import TaskCase

BUSY = 8


def quiet():
    return os.getloadavg()[0] < BUSY


class RunMotionCase(TaskCase):
    def setUp(self):
        super().setUp()
        self.call("test.reduceMotion", {"on": False})
        self.mark()

    def mark(self):
        """Later `items` and `seen` calls list only what the registry shows from now on."""
        state = self.motion()
        self.floor = max([i["id"] for i in state["recent"] + state["inFlight"]], default=0)

    def motion(self):
        return self.call("test.motion")

    def loops(self):
        return self.motion()["infiniteLoops"]

    def seen(self, kind):
        return [i for i in self.items() if i["kind"] == kind]

    def items(self):
        """Everything the registry listed since this test began."""
        state = self.motion()
        return [i for i in state["recent"] + state["inFlight"] if i["id"] > self.floor]

    def rest(self):
        bs.wait_until(lambda: not self.motion()["inFlight"], what="motion at rest")

    def wait_loop(self):
        return bs.wait_until(lambda: (lambda l: l[0] if l else None)(self.loops()),
                             what="the Muse pulse")

    def gone_within(self, action, limit=0.3):
        """Runs `action`; the pulse must be out of the registry (loop and settle) in `limit`."""
        started = time.monotonic()
        action()

        def gone():
            state = self.motion()
            return not state["infiniteLoops"] and not any(
                i["kind"] == "musePulse" for i in state["inFlight"])
        bs.wait_until(gone, what="the pulse to be gone", timeout=2)
        elapsed = time.monotonic() - started
        if quiet():
            self.assertLess(elapsed, limit)
        return elapsed

    def sample_all(self, action, limit=0.6):
        """Every item the registry listed at 16 ms samples while `action` and its effects ran."""
        found, end = {}, time.time() + limit
        action()
        while time.time() < end:
            state = self.motion()
            for item in state["inFlight"] + state["recent"]:
                if item["id"] > self.floor:
                    found[item["id"]] = item
            time.sleep(0.016)
        return list(found.values())

    def pulse_run(self, page, prompt):
        run = self.start(prompt, tab=page["id"])
        self.state(run["runId"], "running")
        return run


class PulseTests(RunMotionCase):
    def test_the_pulse_runs_only_while_a_run_is_working_or_waiting_for_approval(self):
        """VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        self.show("overview")
        node = self.node_of(page["id"])["id"]
        timeline = {"load": os.getloadavg()[0]}
        for end in ("completed", "stopped", "failed"):
            run = self.start(f"Read {end}", tab=page["id"])
            self.assertEqual(self.loops(), [], "connecting does not pulse")
            self.state(run["runId"], "running")
            loop = self.wait_loop()
            self.assertEqual(
                (loop["kind"], loop["purpose"], loop["target"], loop["runId"], loop["surface"],
                 loop["curve"], loop["keyPaths"]),
                ("musePulse", "muse-pulse", node, run["runId"], "overview", "easeOut",
                 ["opacity"]))
            self.state(run["runId"], "waiting-approval")
            self.assertEqual([l["runId"] for l in self.loops()], [run["runId"]])
            self.state(run["runId"], "running")
            self.assertEqual(len(self.loops()), 1)
            timeline[end] = self.gone_within(
                lambda: self.state(run["runId"], end, "no model API key" if end == "failed" else None))
            self.rest()
        save("run-motion-pulse.json", timeline)

    def test_the_pulse_follows_the_surface_that_shows_the_owner(self):
        """VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        self.show("overview")
        run = self.pulse_run(page, "Read this page")
        self.assertEqual(self.wait_loop()["surface"], "overview")
        self.show("focused")
        bs.wait_until(lambda: [l["surface"] for l in self.loops()] == ["focus"],
                      what="only the focused page pulsing")
        self.gone_within(lambda: self.state(run["runId"], "stopped"))
        self.show("overview")
        self.assertEqual(self.loops(), [])

    def test_a_pulse_never_starts_for_another_page_or_after_the_run_ends(self):
        """VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        other = self.open_page("article.html")
        self.show("overview")
        run = self.pulse_run(page, "Read this page")
        self.assertEqual(self.wait_loop()["target"], self.node_of(page["id"])["id"])
        self.assertEqual(len(self.loops()), 1)
        self.gone_within(lambda: self.state(run["runId"], "completed"))
        self.call("test.activateTab", {"tabId": other["id"]})
        self.show("overview")
        self.assertEqual(self.loops(), [])

    def test_the_pulse_is_static_and_every_change_opacity_only_with_reduce_motion(self):
        """VAL-MOTION-003, VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        self.show("overview")
        self.call("test.reduceMotion", {"on": True})
        self.rest()
        self.mark()

        def drive():
            run = self.start("Read this page", tab=page["id"])
            self.open_launcher()
            for state in ("running", "waiting-approval", "running", "completed"):
                self.state(run["runId"], state)
                self.assertEqual(self.loops(), [], f"a pulse while {state}")
            self.close_launcher()
        items = self.sample_all(drive, limit=0.8)
        self.assertEqual(self.loops(), [])
        self.assertTrue(items)
        for item in items:
            self.assertTrue(item["reduced"], item)
            self.assertFalse(item["transformChanged"], item)
            self.assertLessEqual(item["durationMs"], 150, item)
            self.assertNotEqual(item["purpose"], "camera", item)
            self.assertEqual(set(item["keyPaths"]), {"opacity"}, item)
        self.assertIn("completion", {i["kind"] for i in items})
        self.assertIn("rowState", {i["kind"] for i in items})


class RowStateTests(RunMotionCase):
    def test_a_run_row_animates_each_actual_state_change_and_nothing_else(self):
        """VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        run = self.start("Plan the trip", tab=page["id"])
        self.open_launcher()
        self.rest()
        self.assertEqual(self.seen("rowState"), [], "opening the launcher never animates")
        timeline = []
        for state in ("running", "waiting-approval", "running", "completed"):
            before = len(self.seen("rowState"))
            self.state(run["runId"], state)
            item = bs.wait_until(
                lambda: (lambda s: s[-1] if len(s) > before else None)(self.seen("rowState")),
                what=f"the row to animate to {state}")
            self.assertEqual((item["purpose"], item["curve"]), ("result-state", "easeOut"))
            self.assertLessEqual(item["durationMs"], 300)
            self.assertEqual(self.run_rows()[0]["status"], "success" if state == "completed" else "loading")
            timeline.append((state, item["durationMs"], item["keyPaths"]))
            self.rest()
        ready = self.seen("rowState")[-1]
        self.assertIn("transform", ready["keyPaths"])
        save("run-motion-row.json", timeline)

    def test_a_refresh_that_changes_no_state_animates_nothing(self):
        """VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        run = self.start("Plan the trip", tab=page["id"])
        self.state(run["runId"], "running")
        self.open_launcher()
        self.rest()
        before = len(self.seen("rowState"))
        for step in range(3):
            self.call("test.runStep", {"runId": run["runId"], "text": f"Looked at step {step}"})
            time.sleep(0.1)
        self.rest()
        self.assertEqual(len(self.seen("rowState")), before)

    def test_reopening_the_launcher_after_a_change_made_while_it_was_closed_animates_nothing(self):
        """VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        run = self.start("Plan the trip", tab=page["id"])
        self.open_launcher()
        self.close_launcher()
        self.rest()
        self.mark()
        for state in ("running", "completed"):
            self.state(run["runId"], state)
            self.open_launcher()
            self.rest()
            self.assertEqual(self.run_rows()[0]["status"], "success" if state == "completed" else "loading")
            self.close_launcher()
        self.assertEqual(self.seen("rowState"), [])

    def test_the_row_fades_without_travel_with_reduce_motion(self):
        """VAL-MOTION-003"""
        page = self.open_page("launcher.html")
        self.call("test.reduceMotion", {"on": True})
        run = self.start("Plan the trip", tab=page["id"])
        self.open_launcher()
        self.state(run["runId"], "running")
        self.state(run["runId"], "completed")
        self.rest()
        rows = self.seen("rowState")
        self.assertEqual(len(rows), 2)
        for item in rows:
            self.assertTrue(item["reduced"])
            self.assertFalse(item["transformChanged"], item)
            self.assertLessEqual(item["durationMs"], 150)


class CompletionTests(RunMotionCase):
    def test_the_completion_moment_plays_once_on_completed_and_never_otherwise(self):
        """VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        self.show("overview")
        for end in ("stopped", "failed"):
            run = self.pulse_run(page, f"Read {end}")
            self.state(run["runId"], end)
            self.rest()
        self.assertEqual(self.seen("completion"), [])
        run = self.pulse_run(page, "Read to the end")
        self.state(run["runId"], "completed")
        bs.wait_until(lambda: self.seen("completion"), what="the completion")
        self.rest()
        done, = self.seen("completion")
        self.assertEqual((done["purpose"], done["curve"]), ("completion", "spring"))
        self.assertLessEqual(done["bounce"], 0.2)
        self.assertLessEqual(done["durationMs"], 300)
        for _ in range(3):
            self.call("test.runStep", {"runId": run["runId"], "text": "Looked again"})
        self.show("focused")
        self.show("overview")
        self.rest()
        self.assertEqual(len(self.seen("completion")), 1, "nothing replays it")

    def test_a_surface_shown_after_the_run_ended_does_not_celebrate(self):
        """VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        self.show("focused")
        run = self.pulse_run(page, "Read to the end")
        self.state(run["runId"], "completed")
        bs.wait_until(lambda: self.seen("completion"), what="the focused page's completion")
        self.show("overview")
        self.rest()
        self.assertEqual(len(self.seen("completion")), 1, "the overview does not play it again")
        self.assertEqual(self.loops(), [])


    def test_leaving_the_page_ends_its_completion_with_it(self):
        """VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        other = self.open_page("article.html")
        self.call("test.activateTab", {"tabId": page["id"]})
        self.show("focused")
        run = self.pulse_run(page, "Read to the end")
        self.state(run["runId"], "completed")
        self.call("test.activateTab", {"tabId": other["id"]})
        self.rest()
        done, = self.seen("completion")
        if quiet():
            self.assertTrue(done["interrupted"], "the completion left with its page")


class RegistryTests(RunMotionCase):
    def test_every_run_animation_has_a_named_purpose_the_strong_ease_out_and_at_most_300_ms(self):
        """VAL-MOTION-004, VAL-MOTION-006"""
        page = self.open_page("launcher.html")
        self.show("overview")
        run = self.pulse_run(page, "Read this page")
        self.open_launcher()
        self.state(run["runId"], "waiting-approval")
        self.state(run["runId"], "completed")
        with open(os.path.join(self.app.data_dir, "logs", "photon.log")) as log:
            self.assertRegex(log.read(), rf"runs state run={run['runId']} state=waiting-approval")
        self.close_launcher()
        self.rest()
        recent = [i for i in self.items() if i["purpose"] != "camera"]
        kinds = {i["kind"] for i in recent}
        self.assertTrue({"rowState", "completion", "musePulse"} <= kinds, kinds)
        for item in recent:
            self.assertIn(item["purpose"], PURPOSES, item)
            self.assertIn(item["curve"], ("easeOut", "spring"), item)
            self.assertLessEqual(item["bounce"], 0.2, item)
            self.assertLessEqual(item["durationMs"], 300, item)
        save("run-motion-registry.json", recent)


class ApprovalEntranceTests(RunBase):
    def approvals(self, kind, after):
        return [m for m in self.app.call("test.motion")["recent"]
                if m["kind"] == kind and m["id"] > after]

    def test_the_card_enters_for_a_new_approval_and_nothing_animates_while_the_list_is_unchanged(self):
        """VAL-MOTION-006"""
        mark = max([m["id"] for m in self.app.call("test.motion")["recent"]] or [0])
        run = self.start()
        self.quote_for(run)
        self.wait_card()
        entered, = self.approvals("approvalIn", mark)
        self.assertEqual((entered["purpose"], entered["curve"]), ("approval-entrance", "easeOut"))
        self.assertLessEqual(entered["durationMs"], 200)
        for step in range(3):
            self.app.call("test.runStep", {"runId": run["runId"], "text": f"Looked at step {step}"})
        self.app.call("test.windowSize", {"w": 1300, "h": 820})
        self.app.call("test.windowSize", {"w": 1440, "h": 900})
        self.wait_card()
        self.assertEqual(len(self.approvals("approvalIn", mark)), 1)
        self.assertEqual(self.approvals("approvalOut", mark), [])
        self.app.call("run.stop", {"runId": run["runId"]})
        self.card_gone()
        left, = self.approvals("approvalOut", mark)
        self.assertLessEqual(left["durationMs"], 140)
        with open(os.path.join(self.app.data_dir, "logs", "photon.log")) as log:
            text = log.read()
        for line in (r"approvals open id=\S+ kind=action", r"approvals resolve id=\S+ decision="):
            self.assertRegex(text, line)


class ReduceMotionSweepTests(MotionCase):
    """The parts of VAL-MOTION-003 that came before the run motion still hold beside it."""

    def test_focus_overview_entrance_trail_preview_and_button_are_short_opacity_fades(self):
        """VAL-MOTION-003"""
        self.call("test.reduceMotion", {"on": True})
        self.call("test.previews", {"auto": False})
        opener = self.open_page("opener", "popups.html")
        self.popups(opener, 1)
        bs.wait_until(lambda: self.edges(), what="an edge")
        self.settle()
        floor = max([i["id"] for i in self.motion()["recent"]], default=0)
        found = {}

        def sweep():
            state = self.motion()
            for item in state["recent"] + state["inFlight"]:
                if item["id"] > floor:
                    found[item["id"]] = item
            return state

        self.assertEqual(self.call("test.previewCapture", {"tabId": opener})["outcome"], "stored")
        self.show_overview()
        self.settle()
        sweep()
        self.call("test.devtools", {"tabId": opener, "method": "Page.reload", "params": {}})
        bs.wait_until(lambda: self.node_of(opener)["previewState"] == "stale", what="stale")
        self.wait_loaded(next(t["url"] for t in self.tabs() if t["id"] == opener), opener)
        self.click_node(opener)
        for _ in range(60):
            sweep()
            time.sleep(0.016)
        self.settle()
        self.assertEqual(self.call("test.previewCapture", {"tabId": opener})["outcome"], "stored")
        self.toggle()
        for _ in range(60):
            sweep()
            time.sleep(0.016)
        self.settle()
        self.call("test.drag", {"target": "commandButton", "dx": 0, "dy": 0, "release": False})
        time.sleep(0.1)
        scale = self.motion()["camera"]["commandButtonScale"]
        self.call("test.mouseUp")
        sweep()
        self.assertEqual(scale, 1, "the command button does not scale")
        kinds = {i["kind"] for i in found.values()}
        self.assertTrue({"nodeEnter", "trailDraw", "previewCrossfade"} <= kinds, kinds)
        for item in found.values():
            self.assertTrue(item["reduced"], item)
            self.assertNotEqual(item["purpose"], "camera", item)
            self.assertFalse(item["transformChanged"], item)
            self.assertLessEqual(item["durationMs"], 150, item)
        save("run-motion-reduced-sweep.json", sorted(found.values(), key=lambda i: i["id"]))
        self.call("test.reduceMotion", {"on": False})


if __name__ == "__main__":
    unittest.main()
