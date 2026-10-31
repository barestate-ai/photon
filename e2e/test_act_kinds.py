"""The rest of the act kinds, settling, the instruction ladder, point acceptance and Atom on a real
tab; plus two acts racing on one tab and a second launch against a live data dir."""
import json
import os
import re
import statistics
import subprocess
import threading
import time
import unittest

import bs
from bs import wait_until
from test_act import ActBase
from test_core import LOG_DIR, save, url

DONE = {"confirmed", "failed", "cancelled", "outcome-unknown", "quoted"}
SOURCES = os.path.join(bs.ROOT, "Sources")
DECISIONS = os.path.join(bs.ROOT, "DECISIONS.md")
STOPPED = "navigation stopped: no response in 10 s"
LIVE = os.environ.get("BARESTATE_LIVE_META") == "1" and os.environ.get("BARESTATE_SPEND_LOG")
ATOM = {"BARESTATE_ATOM_PYTHON", "BARESTATE_ATOM_RUNTIME", "BARESTATE_ATOM_MODEL"}


def atom_installed():
    """Atom at the product defaults: the venv and model from setup-atom.sh, the bundled runtime."""
    support = os.path.expanduser("~/Library/Application Support/Barestate")
    return all(os.path.exists(path) for path in (
        os.environ.get("BARESTATE_ATOM_PYTHON", f"{support}/Runtime/venv/bin/python"),
        os.environ.get("BARESTATE_ATOM_RUNTIME", f"{bs.APP_BUNDLE}/Contents/Resources/atom/atom_runtime.py"),
        os.environ.get("BARESTATE_ATOM_MODEL",
                       f"{support}/models/atom/tinyclick-4bit-v1/tinyclick-4bit")))


class KindsBase(ActBase):
    def setUp(self):
        self.app.call("test.grounding", {"reset": True})
        super().setUp()

    def run_act(self, client_id, observation, kind, **extra):
        client = bs.Rpc(self.app.data_dir, timeout=30)
        try:
            return client.call("act", {"sessionId": self.session, "clientActionId": client_id,
                                       "observationId": observation["id"], "kind": kind, **extra})
        finally:
            client.close()

    def finished(self, row):
        return wait_until(
            lambda: (lambda r: r if r["state"] in DONE else None)(self.app.call(
                "action_status", {"sessionId": self.session, "clientActionId": row["clientActionId"]})),
            timeout=30, what=f"action {row['clientActionId']} to finish")

    def timed(self, *args, **extra):
        """(final row, milliseconds from the socket call to the final-state response)."""
        started = time.monotonic()
        row = self.run_act(*args, **extra)
        elapsed = (time.monotonic() - started) * 1000
        return (row if row["state"] in DONE else self.finished(row)), elapsed

    def page(self, expression):
        reply = self.devtools("Runtime.evaluate", {"expression": expression, "returnByValue": True})
        return reply["result"].get("value")

    def grounding(self, **params):
        return self.app.call("test.grounding", params)

    def row(self, row):
        return self.db("select state, reason, kind, target, rung from actions where id = ?",
                       (row["id"],))[0]


class KindsTests(KindsBase):
    start_page = "kinds.html"

    # VAL-ACT-001
    def test_select_sets_the_value_with_input_then_change_and_opens_no_popup(self):
        self.grant()
        observation = self.observe()
        windows = []
        stop = threading.Event()

        def sample():
            while not stop.is_set():
                windows.append(self.app.call("test.ui")["visibleWindows"])
                time.sleep(0.02)

        before = self.app.call("test.ui")["visibleWindows"]
        sampler = threading.Thread(target=sample)
        sampler.start()
        try:
            row, _ = self.timed("sel", observation, "select", ref=self.ref(observation, "Color"),
                                value="b")
        finally:
            stop.set()
            sampler.join()
        self.assertEqual(row["state"], "confirmed", row)
        self.assertEqual(self.page("pick.value"), "b")
        # `spy:value` is the page's own HTMLSelectElement.prototype override; the script that sets
        # the value runs in the isolated world and never reaches it.
        self.assertEqual(self.page("seen"), ["input:b", "change:b"])
        self.assertGreater(len(windows), 2)
        for sample_ in windows + [self.app.call("test.ui")["visibleWindows"]]:
            self.assertEqual(sample_, before)
        save("select-row.json", {"row": row, "windows": before})

    def test_select_refuses_a_value_the_element_does_not_offer(self):
        self.grant()
        observation = self.observe()
        row, _ = self.timed("sel-bad", observation, "select", ref=self.ref(observation, "Color"),
                            value="zzz")
        self.assertNotEqual(row["state"], "confirmed", row)
        self.assertEqual(self.page("pick.value"), "a")
        self.assertEqual(self.page("seen"), [])

    def test_a_select_the_page_snaps_back_is_not_confirmed(self):
        self.grant()
        observation = self.observe()
        row, _ = self.timed("sticky", observation, "select", ref=self.ref(observation, "Sticky"),
                            value="b")
        self.assertEqual(row["state"], "failed", row)
        self.assertEqual(self.page("sticky.value"), "a")

    # VAL-ACT-001
    def test_press_enter_in_a_form_input_logs_the_keydown_and_submits(self):
        self.grant()
        observation = self.observe()
        typed, _ = self.timed("q", observation, "type", ref=self.ref(observation, "Query"),
                              text="kyoto")
        self.assertEqual(typed["state"], "confirmed", typed)
        quoted, _ = self.timed("enter", observation, "press", ref=self.ref(observation, "Query"),
                               key="Enter")
        # Enter submits through the form's Go button, which is a submit control (architecture 5.6).
        self.assertEqual(quoted["state"], "quoted", quoted)
        self.assertEqual(self.page("seen.filter(e => e.startsWith('submit'))"), [])
        approval = next(a for a in self.app.call("approval.list")["approvals"]
                        if a.get("actionId") == quoted["id"])
        self.app.call("approval.decide", {"approvalId": approval["approvalId"], "allow": True})
        pressed = wait_until(
            lambda: (lambda r: r if r["state"] in DONE - {"quoted"} else None)(self.app.call(
                "action_status", {"sessionId": self.session, "clientActionId": "enter"})),
            what="the allowed Enter")
        self.assertEqual(pressed["state"], "confirmed", pressed)
        seen = self.page("seen")
        self.assertEqual([e for e in seen if not e.startswith("keydown:k")][-2:],
                         ["keydown:Enter:q", "submit:kyoto"], seen)
        self.assertEqual(seen.count("submit:kyoto"), 1)
        self.assertEqual(self.row(pressed)[2:4], ("press", "Enter"))

    # VAL-ACT-001
    def test_scroll_down_moves_the_page_by_a_positive_amount(self):
        self.grant()
        observation = self.observe()
        before = self.page("scrollY")
        row, _ = self.timed("down", observation, "scroll", direction="down")
        self.assertEqual(row["state"], "confirmed", row)
        after = self.page("scrollY")
        self.assertGreater(after, before)
        up, _ = self.timed("up", self.observe(), "scroll", direction="up")
        self.assertEqual(up["state"], "confirmed", up)
        self.assertLess(self.page("scrollY"), after)

    # VAL-ACT-001
    def test_navigate_changes_the_tab_url_and_the_loader(self):
        self.grant()
        observation = self.observe()
        loader = self.devtools("Page.getFrameTree")["frameTree"]["frame"]["loaderId"]
        target = url("act.html?navigated=1")
        row, _ = self.timed("nav", observation, "navigate", url=target)
        self.assertEqual(row["state"], "confirmed", row)
        self.wait_loaded(target)
        self.assertNotEqual(self.devtools("Page.getFrameTree")["frameTree"]["frame"]["loaderId"],
                            loader)
        self.assertEqual(next(t["url"] for t in self.app.call("tabs")["tabs"] if t["id"] == self.tab),
                         target)

    def test_navigate_refuses_anything_but_http_and_https(self):
        self.grant()
        observation = self.observe()
        for index, bad in enumerate(("file:///etc/hosts", "javascript:alert(1)", "about:blank")):
            row, _ = self.timed(f"bad-{index}", observation, "navigate", url=bad)
            self.assertEqual(row["state"], "failed", row)
        self.assertIn("kinds.html", self.app.call("tabs")["tabs"][0]["url"])

    def test_bad_parameters_are_rejected_at_the_socket(self):
        self.grant()
        observation = self.observe()
        for kind, extra in (("select", {"ref": 1}), ("press", {}), ("press", {"key": "Cmd+Q"}),
                            ("scroll", {"direction": "sideways"}), ("navigate", {}), ("hop", {})):
            with self.assertRaises(bs.RpcError, msg=(kind, extra)):
                self.run_act(f"bad-{kind}", observation, kind, **extra)


class SettleTests(KindsBase):
    start_page = "settle.html"

    # VAL-ACT-002
    def test_a_click_that_starts_a_slow_request_settles_after_the_response_plus_quiet(self):
        self.grant()
        observation = self.observe()
        row, elapsed = self.timed("xhr", observation, "click", ref=self.ref(observation, "Load"))
        self.assertEqual(row["state"], "confirmed", row)
        self.assertTrue(600 <= elapsed <= 850, elapsed)
        self.assertEqual(self.page("out.textContent"), "loaded")
        save("settle-xhr.json", {"ms": elapsed})

    def test_a_page_that_mutates_forever_settles_at_the_two_second_cap(self):
        self.grant()
        observation = self.observe()
        row, elapsed = self.timed("churn", observation, "click", ref=self.ref(observation, "Churn"))
        self.assertEqual(row["state"], "confirmed", row)
        self.assertTrue(1900 <= row["settle"]["ms"] <= 2100, row)
        self.assertLess(elapsed, 4000)
        save("settle-churn.json", {"ms": elapsed})

    def test_a_click_that_navigates_waits_for_the_load_not_the_two_second_cap(self):
        self.grant()
        observation = self.observe()
        row, elapsed = self.timed("slow", observation, "click", ref=self.ref(observation, "Slow page"))
        self.assertIn(row["state"], {"confirmed", "outcome-unknown"}, row)
        self.assertTrue(3000 <= elapsed <= 3600, elapsed)
        save("settle-navigation.json", {"ms": elapsed, "row": row})

    # VAL-ACT-014
    def test_a_navigation_that_never_commits_is_stopped_at_ten_seconds_and_recorded_as_unknown(self):
        self.grant()
        observation = self.observe()
        before = len(self.fixtures.log())
        row, elapsed = self.timed("stuck", observation, "click", ref=self.ref(observation, "Stuck page"))
        self.assertEqual((row["state"], row["reason"]), ("outcome-unknown", STOPPED), row)
        # The cap is measured by the app; wall clock also carries harness latency under load.
        self.assertTrue(9800 <= row["settle"]["ms"] <= 10200, row)
        self.assertLess(elapsed, 12000)
        self.assertEqual({k: row["settle"][k] for k in ("capped", "navigationStopped")},
                         {"capped": True, "navigationStopped": True})
        self.assertEqual(self.row(row)[:2], ("outcome-unknown", STOPPED))
        self.assertEqual(self.db("select count(*) from actions where client_action_id = 'stuck'"), [(1,)])
        bs.wait_until(lambda: "aborted" in self.held("/hang", before), what="the stopped request to abort")
        self.assertEqual(self.held("/hang", before), ["started", "aborted"])
        save("settle-stuck.json", {"ms": elapsed, "row": row})

    # VAL-ACT-014
    def test_a_takeover_before_the_cap_suppresses_the_stop_and_the_late_page_is_shown(self):
        self.grant()
        observation = self.observe()
        before = len(self.fixtures.log())
        results = []
        thread = threading.Thread(target=lambda: results.append(self.run_act(
            "takeover", observation, "click", ref=self.ref(observation, "Stuck page"))))
        thread.start()
        bs.wait_until(lambda: "started" in self.held("/hang", before), what="the navigation to be pending")
        # A real click in the tab's empty corner: the person takes the tab over.
        self.app.call("test.click", {"tabId": self.tab, "x": 450, "y": 380})
        thread.join()
        row = results[0]
        self.assertFalse(row["settle"]["navigationStopped"], row)
        self.assertNotEqual(row.get("reason"), STOPPED, row)
        self.assertEqual(self.ui_tab()["controller"], "human")
        bs.wait_until(lambda: "delivered" in self.held("/hang", before), timeout=15,
                      what="the late response")
        self.assertEqual(self.held("/hang", before), ["started", "delivered"])
        shown = bs.wait_until(lambda: next((t for t in self.app.call("tabs")["tabs"]
                                            if t["id"] == self.tab and t["url"].endswith("/hang")
                                            and t["title"] == "Slow page"), None),
                              what="the tab to show the late page")
        save("settle-takeover.json", {"row": row, "tab": shown})

    # VAL-ACT-013
    def test_a_committed_page_still_loading_an_image_is_never_stopped(self):
        self.grant()
        observation = self.observe()
        before = len(self.fixtures.log())
        row, elapsed = self.timed("image", observation, "navigate", url=url("settle-image.html"))
        self.assertEqual(row["state"], "confirmed", row)
        self.assertLessEqual(row["settle"]["ms"], 2300, row)
        self.assertEqual({k: row["settle"][k] for k in ("capped", "navigationStopped")},
                         {"capped": True, "navigationStopped": False})
        self.assertEqual(self.page("document.readyState"), "interactive")
        bs.wait_until(lambda: "delivered" in self.held("/slow-image", before), timeout=15,
                      what="the image to be delivered")
        bs.wait_until(lambda: self.page("document.readyState") == "complete", what="the load event")
        self.assertEqual(self.held("/slow-image", before), ["started", "delivered"])
        self.assertEqual(self.page("pic.naturalWidth"), 1)
        save("settle-image.json", {"ms": elapsed, "settle": row["settle"]})

    # VAL-ACT-013
    def test_a_long_poll_opened_after_load_does_not_hold_the_settle(self):
        self.grant()
        observation = self.observe()
        before = len(self.fixtures.log())
        row, elapsed = self.timed("poll", observation, "navigate", url=url("settle-poll.html"))
        self.assertEqual(row["state"], "confirmed", row)
        self.assertLessEqual(row["settle"]["ms"], 2300, row)
        self.assertFalse(row["settle"]["navigationStopped"], row)
        bs.wait_until(lambda: any(b.get("poll") == ["done"] for b in self.beacons(before)),
                      timeout=20, what="the long-poll to complete")
        self.assertEqual(self.held("/long-poll", before), ["started", "delivered"])
        save("settle-poll.json", {"ms": elapsed, "settle": row["settle"]})

    # VAL-ACT-013
    def test_a_click_that_inserts_a_never_answering_iframe_settles_at_the_click_cap(self):
        self.grant()
        observation = self.observe()
        before = len(self.fixtures.log())
        row, elapsed = self.timed("frame", observation, "click", ref=self.ref(observation, "Frame"))
        self.assertEqual(row["state"], "confirmed", row)
        self.assertTrue(1800 <= elapsed <= 2200, elapsed)
        self.assertEqual({k: row["settle"][k] for k in ("capped", "navigationStopped")},
                         {"capped": True, "navigationStopped": False})
        bs.wait_until(lambda: "delivered" in self.held("/hang", before), timeout=20,
                      what="the iframe request to be answered")
        self.assertEqual(self.held("/hang", before), ["started", "delivered"])
        save("settle-iframe.json", {"ms": elapsed, "settle": row["settle"]})

    def held(self, path, since):
        """What the fixture server did with each response it held on `path`, in order."""
        return [line.split()[2] for line in self.fixtures.log(since)
                if line.startswith(f"HELD {path} ")]

    def test_an_act_after_one_that_left_a_navigation_pending_starts_promptly_and_lands(self):
        self.grant()
        observation = self.observe()
        row, _ = self.timed("stuck", observation, "click", ref=self.ref(observation, "Stuck page"))
        self.assertEqual((row["state"], row["reason"]), ("outcome-unknown", STOPPED), row)
        before = len(self.fixtures.log())
        started = time.monotonic()
        results = []
        thread = threading.Thread(target=lambda: results.append(self.run_act(
            "after", observation, "click", ref=self.ref(observation, "Load"))))
        thread.start()
        wait_until(lambda: any("click=xhr" in line for line in self.fixtures.log(before)),
                   what="the click to reach the page")
        reached = (time.monotonic() - started) * 1000
        thread.join()
        self.assertEqual(results[0]["state"], "confirmed", results[0])
        save("settle-after-pending-navigation.json", {"reached_ms": reached})
        self.assertLess(reached, 500)

    def test_the_act_pipeline_uses_no_fixed_sleep_to_settle(self):
        pipeline = [os.path.join(SOURCES, "BarestateCore", name) for name in
                    ("Settle.swift", "Dispatch.swift", "GroundingProbe.swift")]
        pipeline += [os.path.join(SOURCES, "Barestate", name) for name in
                     ("ActMethods.swift", "Grounders.swift")]
        found = []
        for path in pipeline:
            with open(path) as source:
                found += [f"{os.path.basename(path)}:{n}: {line.strip()}"
                          for n, line in enumerate(source, 1)
                          if re.search(r"Task\.sleep|usleep|asyncAfter|Thread\.sleep|sleep\(", line)]
        self.assertEqual(found, [])


class ActLatency(KindsBase):
    start_page = "act.html"

    # VAL-ACT-003
    def test_dom_act_p50_is_under_250_ms(self):
        self.grant()
        observation = self.observe()
        timings = []
        for index in range(40):
            if index % 2:
                row, elapsed = self.timed(f"t{index}", observation, "type",
                                          ref=self.ref(observation, "Name"), text=f"value {index}")
            else:
                row, elapsed = self.timed(f"c{index}", observation, "click",
                                          ref=self.ref(observation, "Other"))
            self.assertEqual(row["state"], "confirmed", row)
            timings.append(elapsed)
        ordered = sorted(timings)
        result = {"n": len(timings), "p50": statistics.median(timings),
                  "p95": bs.nearest_rank(ordered, 0.95), "max": ordered[-1], "values": timings}
        save("act-latency.json", result)
        print(f"DOM act n={result['n']} p50={result['p50']:.1f} ms p95={result['p95']:.1f} ms "
              f"max={result['max']:.1f} ms", flush=True)
        self.assertLess(result["p50"], 250)

    # VAL-ACT-003, the live half: reported on its own, never counted against the 250 ms budget
    @unittest.skipUnless(LIVE, "live Meta call: not run (no BARESTATE_LIVE_META/BARESTATE_SPEND_LOG)")
    def test_live_verifier_added_latency_per_act(self):
        ledger = os.environ["BARESTATE_SPEND_LOG"]

        def spent():
            with open(ledger) as spend:
                return json.load(spend)["total_usd"]

        before = spent()
        self.assertLess(before, 40)
        self.grant()
        pairs = []
        for index, (kind, name) in enumerate((("click", "Count"), ("type", "Name"), ("click", "Count"))):
            self.assertLess(spent() - before, 3)
            pair = {"kind": kind}
            for mode in ("agree", "live"):
                self.app.call("test.verifier", {"mode": mode})
                observation = self.observe()
                extra = {"ref": self.ref(observation, name)}
                if kind == "type":
                    extra["text"] = f"{mode} {index}"
                billed = spent()
                row, elapsed = self.timed(f"{index}-{mode}", observation, kind, **extra)
                if mode == "live":
                    # A reply the parser rejects (output cap) still cost the round trip being timed.
                    self.assertGreater(spent(), billed, row)
                pair[mode] = {"ms": elapsed, "state": row["state"], "modelVerdict": row["modelVerdict"]}
            pair["added_ms"] = pair["live"]["ms"] - pair["agree"]["ms"]
            pairs.append(pair)
        after = spent()
        self.assertLess(after, 40)
        self.assertLess(after - before, 3)
        result = {"pairs": pairs, "added": [p["added_ms"] for p in pairs],
                  "median_added_ms": statistics.median(p["added_ms"] for p in pairs),
                  "spend_usd": after - before}
        save("act-live-verifier.json", result)
        print("Live verifier added per act (ms): "
              + ", ".join(f"{p['kind']} {p['added_ms']:.1f}" for p in pairs)
              + f"; median {result['median_added_ms']:.1f} ms; spend ${result['spend_usd']:.6f}", flush=True)

    def test_two_concurrent_acts_on_one_tab_serialize_and_each_lands_once_in_order(self):
        self.grant()
        observation = self.observe()
        self.app.call("test.holdDispatch", {"on": True})
        try:
            first = self.run_act("first", observation, "click", ref=self.ref(observation, "Count"))
            second = self.run_act("second", observation, "click", ref=self.ref(observation, "Other"))
        finally:
            self.app.call("test.releaseDispatch")
        self.assertEqual((first["state"], second["state"]), ("pending", "pending"))
        done = [self.finished(first), self.finished(second)]
        self.assertEqual([r["state"] for r in done], ["confirmed", "confirmed"])
        self.assertEqual(self.settled_clicks(2), ["count", "other"])
        # The same race with both calls blocked on the socket at once.
        results = {}

        def call(name, button):
            results[name] = self.run_act(name, observation, "click", ref=self.ref(observation, button))

        threads = [threading.Thread(target=call, args=(name, button))
                   for name, button in (("a", "Count"), ("b", "Other"))]
        threads[0].start()
        wait_until(lambda: self.db("select count(*) from actions where client_action_id = 'a'")[0][0],
                   what="the first row")
        threads[1].start()
        for thread in threads:
            thread.join()
        self.assertEqual([results["a"]["state"], results["b"]["state"]], ["confirmed", "confirmed"])
        self.assertEqual(self.settled_clicks(4), ["count", "other", "count", "other"])
        self.assertEqual(self.db("select count(*) from actions where state = 'pending'"), [(0,)])


class Ladder(KindsBase):
    start_page = "ground.html"

    def click_ground(self, client_id, instruction):
        observation = self.observe()
        row = self.run_act(client_id, observation, "click", instruction=instruction)
        return self.finished(row) if row["state"] not in DONE else row

    def clicks_now(self):
        self.fence()
        return self.clicks()

    # VAL-ACT-004
    def test_the_dom_answers_first_and_no_other_rung_is_called(self):
        self.grant()
        self.grounding(atom={"x": 70, "y": 60}, muse={"x": 70, "y": 60})
        row = self.click_ground("dom", "Cancel")
        self.assertEqual(row["state"], "confirmed", row)
        self.assertEqual(self.row(row)[4], "dom")
        self.assertEqual(self.grounding()["calls"], [])
        self.assertEqual(self.clicks_now(), ["cancel"])

    def test_a_target_renamed_after_the_observation_is_not_clicked(self):
        self.grant()
        observation = self.observe()
        self.page("document.getElementById('cancel').textContent = 'Dismiss'")
        row = self.run_act("renamed", observation, "click", instruction="Cancel")
        row = row if row["state"] in DONE else self.finished(row)
        self.assertEqual((row["state"], row["reason"]), ("cancelled", "stale: target"))
        self.assertEqual(self.row(row)[:2], ("cancelled", "stale: target"))
        self.assertEqual(self.grounding()["calls"], [])
        self.assertEqual(self.clicks_now(), [])

    def test_the_check_reads_the_accessible_name_not_the_visible_text(self):
        self.grant()
        self.page("""document.body.insertAdjacentHTML('beforeend',
            '<span id="lbl">Archive</span><button id="labelled" aria-labelledby="lbl"'
            + ' class="abs" style="left: 20px; top: 200px">X</button>')""")
        self.assertEqual(self.click_ground("labelled", "Archive")["state"], "confirmed")
        self.assertEqual(self.clicks_now(), ["labelled"])
        observation = self.observe()
        self.page("document.getElementById('cancel').setAttribute('aria-label', 'Dismiss')")
        row = self.run_act("relabelled", observation, "click", instruction="Cancel")
        row = row if row["state"] in DONE else self.finished(row)
        self.assertEqual((row["state"], row["reason"]), ("cancelled", "stale: target"))
        self.assertEqual(self.clicks_now(), ["labelled"])

    # VAL-ACT-004, VAL-ACT-006
    def test_atom_answers_when_the_dom_has_no_single_match_and_muse_is_not_called(self):
        self.grant()
        self.grounding(atom={"x": 70, "y": 60}, muse={"x": 400, "y": 120}, policy={"hits": 10, "samples": 10})
        row = self.click_ground("atom", "Click Save")
        self.assertEqual(row["state"], "confirmed", row)
        self.assertEqual(self.row(row)[4], "atom")
        self.assertEqual(self.grounding()["calls"], ["atom: Click Save"])
        self.assertEqual(self.clicks_now(), ["save"])

    def test_muse_answers_when_atom_abstains(self):
        self.grant()
        self.grounding(atom="abstain", muse={"x": 70, "y": 60})
        row = self.click_ground("muse", "Click Save")
        self.assertEqual(row["state"], "confirmed", row)
        self.assertEqual(self.row(row)[4], "muse")
        self.assertEqual(self.grounding()["calls"], ["atom: Click Save", "muse: Click Save"])
        self.assertEqual(self.clicks_now(), ["save"])

    def test_an_absent_atom_is_skipped_and_dom_acts_still_work(self):
        self.grant()
        self.grounding(atom="absent", muse={"x": 70, "y": 60})
        self.assertTrue(self.app.status()["ready"])
        self.assertEqual(self.click_ground("dom", "Cancel")["state"], "confirmed")
        row = self.click_ground("muse", "Click Save")
        self.assertEqual(self.row(row)[4], "muse")
        self.assertEqual(self.grounding()["calls"], ["muse: Click Save"])

    # VAL-ACT-004 (live case), VAL-ACT-005's row
    def test_an_instruction_nothing_answers_ends_in_needs_human_without_a_click(self):
        self.grant()
        self.grounding(atom="abstain", muse="abstain")
        row = self.click_ground("nothing", "Click the unicorn")
        self.assertEqual((row["state"], row["reason"]), ("failed", "needs-human"))
        self.assertEqual(self.grounding()["calls"], ["atom: Click the unicorn", "muse: Click the unicorn"])
        self.assertEqual(self.clicks_now(), [])

    # VAL-ACT-006
    def test_a_point_is_accepted_only_on_a_visible_interactive_matching_element(self):
        self.grant()
        rejected = {
            "display:none": (180, 60), "visibility:hidden": (290, 60), "opacity:0": (400, 60),
            "non-interactive label": (70, 120), "non-interactive div": (180, 120),
            "Cancel button": (290, 120)}
        table = {}
        for name, (x, y) in rejected.items():
            self.grounding(atom={"x": x, "y": y}, muse="abstain", policy={"hits": 10, "samples": 10})
            row = self.click_ground(f"reject-{name}", "Click Save")
            table[name] = [row["state"], row["reason"]]
            self.assertEqual(row["state"], "failed", (name, row))
            self.assertRegex(row["reason"], r"^point-rejected: ", name)
        self.assertEqual(self.clicks_now(), [])
        self.grounding(atom={"x": 70, "y": 60}, muse="abstain")
        accepted = self.click_ground("accept", "Click Save")
        self.assertEqual(accepted["state"], "confirmed", accepted)
        self.assertEqual(self.clicks_now(), ["save"])
        save("point-acceptance.json", {"rejected": table, "accepted": accepted})

    def test_a_button_inside_a_transparent_shadow_host_is_not_visible(self):
        self.grant()
        self.grounding(atom={"x": 70, "y": 180}, muse="abstain", policy={"hits": 10, "samples": 10})
        row = self.click_ground("ghost", "Click Save")
        self.assertEqual((row["state"], row["reason"]), ("failed", "point-rejected: not-visible"))
        self.assertEqual(self.clicks_now(), [])

    def test_the_rejection_reason_names_what_was_wrong_with_the_point(self):
        self.grant()
        self.grounding(muse="abstain", policy={"hits": 10, "samples": 10})
        for name, point, reason in (("hidden", (290, 60), "no-interactive-element"),
                                    ("clear", (400, 60), "not-visible"),
                                    ("label", (70, 120), "no-interactive-element"),
                                    ("cancel", (290, 120), "no-match")):
            self.grounding(atom={"x": point[0], "y": point[1]})
            row = self.click_ground(f"why-{name}", "Click Save")
            self.assertEqual(row["reason"], f"point-rejected: {reason}", name)

    def test_a_point_matches_on_the_words_the_element_shows_not_only_its_ax_name(self):
        self.grant()
        size = self.page("[innerWidth, innerHeight]")
        self.grounding(atom={"x": size[0] * 0.6, "y": size[1] * 0.8}, muse="abstain",
                       policy={"hits": 10, "samples": 10})
        row = self.click_ground("gear", "open settings")
        self.assertEqual(row["state"], "confirmed", row)
        self.assertEqual(self.clicks_now(), ["gear"])

    # VAL-ACT-010
    def test_atom_grounded_clicks_follow_the_measured_rate(self):
        self.grant()
        for hits, state in ((7, "quoted"), (8, "confirmed")):
            self.grounding(atom={"x": 70, "y": 60}, muse="abstain",
                           policy={"hits": hits, "samples": 10})
            row = self.click_ground(f"ft4-{hits}", "Click Save")
            self.assertEqual(row["state"], state, (hits, row))
            if state == "quoted":
                self.assertIn("atom-grounded", row["reason"])
                self.assertEqual(self.clicks_now(), [])
                held = [a for a in self.app.call("approval.list")["approvals"]
                        if a.get("actionId") == row["id"]]
                self.assertEqual(len(held), 1)
                self.app.call("approval.decide", {"approvalId": held[0]["approvalId"], "allow": True})
                allowed = wait_until(
                    lambda: (lambda r: r if r["state"] not in {"quoted", "pending"} else None)(
                        self.app.call("action_status", {"sessionId": self.session,
                                                        "clientActionId": row["clientActionId"]})),
                    what="the allowed click to finish")
                self.assertEqual(allowed["state"], "confirmed", allowed)
                self.assertEqual(self.clicks_now(), ["save"])
            else:
                self.assertEqual(self.clicks_now(), ["save", "save"])
        quoted = self.grounding(policy={"hits": 7, "samples": 10})
        self.assertTrue(quoted["atomNeedsApproval"])

    def test_the_app_starts_with_the_rate_recorded_in_decisions(self):
        recorded = recorded_ft4()
        self.assertIsNotNone(recorded, "DECISIONS.md has no FT4 measurement")
        hits, samples = recorded
        self.assertGreaterEqual(samples, 20)
        started = self.grounding()
        self.assertEqual((started["hits"], started["samples"]), (hits, samples))
        self.assertEqual(started["atomNeedsApproval"], hits / samples < 0.8)
        self.grant()
        self.grounding(atom={"x": 70, "y": 60}, muse="abstain")
        row = self.click_ground("recorded", "Click Save")
        self.assertEqual(row["state"], "quoted" if hits / samples < 0.8 else "confirmed", row)


def recorded_ft4():
    with open(DECISIONS) as text:
        found = re.search(r"Atom verified hits: (\d+)/(\d+)", text.read())
    return (int(found[1]), int(found[2])) if found else None


class NoAtomRuntime(KindsBase):
    """The runtime is not installed: the app is ready, DOM acts work and the ladder passes over Atom."""

    start_page = "ground.html"

    @classmethod
    def setUpClass(cls):
        saved = {key: os.environ.get(key) for key in ATOM}
        os.environ.update({key: "/nonexistent/atom" for key in ATOM})
        try:
            super().setUpClass()
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    # VAL-ACT-004
    def test_without_the_runtime_dom_acts_work_and_the_ladder_goes_straight_to_muse(self):
        self.assertTrue(self.app.status()["ready"])
        self.grant()
        self.grounding(muse={"x": 70, "y": 60})
        observation = self.observe()
        dom = self.run_act("dom", observation, "click", instruction="Cancel")
        self.assertEqual(self.finished(dom)["state"], "confirmed")
        row = self.finished(self.run_act("ladder", observation, "click", instruction="Click Save"))
        self.assertEqual(self.row(row)[4], "muse")
        self.assertEqual(self.grounding()["calls"], ["muse: Click Save"])
        self.assertTrue(self.app.status()["ready"])


@unittest.skipUnless(atom_installed(), "the Atom runtime is not installed on this machine")
class RealAtom(KindsBase):
    start_page = "ground.html"

    def ground(self, instruction):
        return self.app.call("test.ground", {"tabId": self.tab, "instruction": instruction})

    # VAL-ACT-009
    def test_atom_warm_latency_median_is_under_500_ms(self):
        self.ground("click Save")
        samples = [self.ground("click Save") for _ in range(12)]
        self.assertTrue(all(s.get("point") and s["clientMs"] > 0 for s in samples), samples)
        times = [s["clientMs"] for s in samples]
        median = statistics.median(times)
        result = {"n": len(times), "median_ms": median, "values": times,
                  "points": [s.get("point") for s in samples]}
        save("atom-warm.json", result)
        print(f"Atom warm n={len(times)} median={median:.1f} ms "
              f"min={min(times):.1f} max={max(times):.1f}", flush=True)
        self.assertLess(median, 500)


@unittest.skipUnless(atom_installed(), "the Atom runtime is not installed on this machine")
class FT4(KindsBase):
    start_page = "targets.html"

    # VAL-ACT-010
    def test_atom_hit_rate_on_the_labelled_targets(self):
        observation = self.observe()
        labels = [e["name"] for e in observation["elements"] if e["interactive"]]
        self.assertGreaterEqual(len(labels), 20)
        self.app.call("test.ground", {"tabId": self.tab, "instruction": f"click {labels[0]}"})
        table = []
        for label in labels:
            found = self.app.call("test.ground", {"tabId": self.tab, "instruction": f"click {label}"})
            wanted = self.ref(observation, label)
            table.append({"label": label, "wanted": wanted, "verdict": found["verdict"],
                          "ref": found.get("ref"), "point": found.get("point"),
                          "hit": found["verdict"] == "accepted" and found.get("ref") == wanted})
        hits = sum(row["hit"] for row in table)
        save("ft4-targets.json", {"hits": hits, "samples": len(table), "rows": table})
        print(f"FT4 Atom verified hits: {hits}/{len(table)}", flush=True)
        for row in table:
            print(f"  {'hit ' if row['hit'] else 'miss'} {row['label']}: {row['verdict']}", flush=True)
        recorded = recorded_ft4()
        self.assertIsNotNone(recorded, "record the measurement in DECISIONS.md")
        self.assertEqual(recorded[1], len(table))
        self.assertEqual(recorded[0] / recorded[1] < 0.8, hits / len(table) < 0.8)


class SecondLaunch(unittest.TestCase):
    # The refusal comes from the socket check; it must come before the second process opens the
    # log, the journal or the browser engine in the first one's data dir.
    def test_a_second_launch_on_a_live_data_dir_refuses_and_leaves_the_running_app_alone(self):
        data_dir = f"/tmp/bs-second-{os.getpid()}"
        app = bs.App(data_dir, LOG_DIR, label="SecondLaunch").start()
        try:
            def state():
                logs = os.path.join(data_dir, "logs")
                with open(os.path.join(logs, "photon.log")) as log:
                    launches = log.read().count("launch version=")
                with open(os.path.join(data_dir, "app.pid")) as pid:
                    return {"pid": pid.read(), "launches": launches,
                            "tabs": [t["id"] for t in app.call("tabs")["tabs"]],
                            "cef": os.path.getsize(os.path.join(logs, "cef.log"))}

            before = state()
            reports = bs.crash_reports()
            started = time.monotonic()
            second = subprocess.run(
                [os.path.join(bs.ROOT, "scripts", "run-app.sh"), "--data-dir", data_dir,
                 "--test-hooks"], capture_output=True, text=True, timeout=30,
                stdin=subprocess.DEVNULL)
            elapsed = time.monotonic() - started
            self.assertEqual(second.returncode, 75, second.stderr)
            self.assertIn("another instance", second.stderr)
            self.assertLess(elapsed, 5)
            self.assertIsNone(app.proc.poll())
            self.assertTrue(app.status()["ready"])
            self.assertEqual(state(), before)
            self.assertEqual(bs.crash_reports(), reports)
            save("second-launch.json", {"exit": second.returncode, "stderr": second.stderr,
                                        "seconds": elapsed, "state": before})
        finally:
            app.stop()


if __name__ == "__main__":
    unittest.main()
