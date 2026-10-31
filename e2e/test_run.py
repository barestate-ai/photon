"""The run engine over the socket (VAL-TASK-003, VAL-MODEL-005, the run half of VAL-TASK-010), then
live on Muse (VAL-ACT-004 live, VAL-ACT-011, VAL-ACT-012, VAL-SPATIAL-014).

Deterministic tests hold the model before its first call and keep it offline, so a run stays where
the test put it and nothing is spent. Live tests need BARESTATE_LIVE_META=1 and a spend ledger."""
import json
import os
import threading
import time
import unittest

import bs
import png
from test_core import LOG_DIR, save, url
from test_perm import LIVE, PermBase

ENDED = {"stopped", "failed", "completed"}
FINAL = {"confirmed", "failed", "cancelled", "outcome-unknown"}
ATOM = {"BARESTATE_ATOM_PYTHON", "BARESTATE_ATOM_RUNTIME", "BARESTATE_ATOM_MODEL"}
CONTRIBUTOR = "muse-spark-1.3-contributor"


class RunBase(PermBase):
    def setUp(self):
        super().setUp()
        self.addCleanup(self.clean)
        self.app.call("test.modelOffline", {"on": True})
        self.app.call("test.holdModel", {"on": True})

    def clean(self):
        for run in self.runs():
            if run["state"] not in ENDED:
                self.app.call("run.stop", {"runId": run["runId"]})
        self.app.call("test.holdModel", {"on": False})
        self.app.call("test.modelOffline", {"on": False})

    def runs(self):
        return self.app.call("run.list")["runs"]

    def run_of(self, run_id):
        return next(r for r in self.runs() if r["runId"] == run_id)

    def start(self, prompt="Read this page", tab="owner"):
        params = {"prompt": prompt, "origin": "mac"}
        if tab:
            params["tabId"] = self.tab if tab == "owner" else tab
        return self.app.call("run.start", params)

    def finish(self, run_id, timeout=20):
        return bs.wait_until(lambda: (lambda r: r if r["state"] in ENDED else None)(self.run_of(run_id)),
                             timeout=timeout, what=f"run {run_id} to end")

    def spend(self):
        path = os.environ.get("BARESTATE_SPEND_LOG") or os.path.join(self.app.data_dir, "spend.json")
        if not os.path.exists(path):
            return {"total_usd": 0, "entries": []}
        with open(path) as spend:
            return json.load(spend)

    def spend_of(self, session):
        return [e for e in self.spend()["entries"] if e["source"].startswith(f"{session}:")]

    def quote_for(self, run, name="Delete draft"):
        """A sensitive act on the run's page under the run's own session, left waiting for a person."""
        observation = self.observe()
        row = self.act("held", observation, "click", name, session=run["sessionId"])
        self.assertEqual(row["state"], "quoted", row)
        self.assertEqual(len(self.pending()), 1)
        return row

    def status(self, row, session):
        return self.app.call("action_status", {"sessionId": session,
                                               "clientActionId": row["clientActionId"]})

    def card_gone(self):
        bs.wait_until(lambda: not self.ui()["approval"].get("visible"), what="the card to leave")


class RunEngineTests(RunBase):
    def test_a_run_controls_its_owner_tab_lists_no_step_before_a_call_and_stops_on_request(self):
        run = self.start()
        self.assertEqual((run["state"], run["origin"], run["tabId"]), ("pending", "mac", self.tab))
        self.assertEqual(run["steps"], [])
        self.assertEqual(self.holder(), run["sessionId"])
        self.assertEqual([r["runId"] for r in self.runs() if r["state"] == "pending"], [run["runId"]])
        stopped = self.app.call("run.stop", {"runId": run["runId"]})
        self.assertEqual((stopped["state"], stopped["reason"]), ("stopped", "stopped"))
        self.assertIsNone(self.holder())
        again = self.app.call("run.stop", {"runId": run["runId"]})
        self.assertEqual((again["state"], again["reason"]), ("stopped", "stopped"))
        with self.assertRaises(bs.RpcError):
            self.app.call("run.stop", {"runId": "r999"})
        with self.assertRaises(bs.RpcError):
            self.start(prompt="  ")

    # The run half of VAL-TASK-010: the card leaves with the run, whichever way it ends.
    def test_stopping_a_run_cancels_its_quoted_act_and_the_card_leaves(self):
        run = self.start()
        row = self.quote_for(run)
        self.wait_card()
        self.app.call("run.stop", {"runId": run["runId"]})
        final = self.settled(row, run["sessionId"])
        self.assertEqual(final["state"], "cancelled", final)
        self.assertTrue(final["reason"].startswith("stale"), final)
        self.assertEqual(self.pending(), [])
        self.card_gone()
        self.assertEqual(self.settled_clicks(), [])
        self.assertEqual(self.status_text(), "Nothing deleted")

    def test_a_takeover_stops_the_run_before_the_hook_returns_and_the_card_leaves(self):
        run = self.start()
        row = self.quote_for(run)
        self.wait_card()
        self.app.call("test.click", {"tabId": self.tab})
        taken = self.run_of(run["runId"])
        self.assertEqual((taken["state"], taken["reason"]), ("stopped", "taken-over"))
        self.assertIsNone(self.holder())
        self.assertEqual(self.pending(), [])
        final = self.settled(row, run["sessionId"])
        self.assertEqual(final["state"], "cancelled", final)
        self.card_gone()
        self.assertEqual(self.settled_clicks(1), ["pad"])
        self.assertEqual(self.status_text(), "Nothing deleted")
        late = self.app.call("run.stop", {"runId": run["runId"]})
        self.assertEqual(late["reason"], "taken-over")

    # VAL-MODEL-005
    def test_a_run_at_the_cap_fails_without_a_model_call_and_other_runs_continue(self):
        before = len(self.spend()["entries"])
        self.app.call("test.runCost", {"usd": 3})
        capped = self.start(tab=None)
        other = self.start(tab=None)
        ended = self.finish(capped["runId"])
        self.assertEqual((ended["state"], ended["reason"]), ("failed", "run-cap"))
        self.assertGreaterEqual(ended["costUSD"], 2.99)
        self.assertEqual(ended["steps"], [])
        self.assertEqual(self.run_of(other["runId"])["state"], "pending")
        self.app.call("test.holdModel", {"on": False})
        carried_on = self.finish(other["runId"])
        self.assertEqual(carried_on["state"], "failed")
        self.assertNotEqual(carried_on["reason"], "run-cap")
        self.assertTrue(carried_on["reason"], carried_on)
        self.assertEqual(self.spend_of(capped["sessionId"]), [])
        self.assertEqual(len(self.spend()["entries"]), before)
        save("run-cap.json", {"capped": ended, "other": carried_on})

    # VAL-STABILITY-003: a verifier's free text can quote the page, so it stays off the logs.
    def test_a_verdicts_free_text_reaches_the_journal_and_run_list_but_not_the_log(self):
        sentinel = "SENTINEL-page-text-7f3a"
        self.grant()
        self.app.call("test.verifier", {"mode": "failure", "reason": sentinel})
        self.addCleanup(self.app.call, "test.verifier", {"mode": "live"})
        row = self.settled(self.act("sentinel", self.observe(), "click", "Count"))
        self.assertEqual(row["state"], "outcome-unknown", row)
        self.assertIn(sentinel, row["reason"])
        run = self.start()
        self.app.call("test.runState", {"runId": run["runId"], "state": "failed",
                                        "reason": f"a write ended {row['state']}: {row['reason']}"})
        self.assertIn(sentinel, self.run_of(run["runId"])["reason"])
        with open(os.path.join(self.app.data_dir, "logs", "photon.log")) as log:
            text = log.read()
        self.assertNotIn(sentinel, text)
        self.assertIn(f"end run={run['runId']} state=failed reason=write-not-confirmed", text)

    # VAL-TASK-003: a model that stops without a task done is not a completed run.
    def test_a_run_that_cannot_reach_the_model_fails_with_a_reason_and_never_completes(self):
        run = self.start()
        self.app.call("test.holdModel", {"on": False})
        ended = self.finish(run["runId"])
        self.assertEqual(ended["state"], "failed")
        self.assertTrue(ended["reason"], ended)
        self.assertIsNone(self.holder())


class LiveBase(RunBase):
    """Runs on the real model: the model is online and the tests pay for it."""

    @classmethod
    def setUpClass(cls):
        if not LIVE:
            raise unittest.SkipTest("live Meta call: not run (no BARESTATE_LIVE_META/BARESTATE_SPEND_LOG)")
        super().setUpClass()

    def setUp(self):
        super().setUp()
        self.app.call("test.modelOffline", {"on": False})
        self.spent0 = self.spend()

    def cost(self):
        now = self.spend()
        return {"requests": len(now["entries"]) - len(self.spent0["entries"]),
                "usd": round(now["total_usd"] - self.spent0["total_usd"], 6)}

    def record(self, name, **evidence):
        evidence["spend"] = self.cost()
        save(f"{name}.json", evidence)
        print(f"\n{name}: {evidence['spend']}", flush=True)
        return evidence

    def task(self, prompt, tab="owner", timeout=180, before=None):
        run = self.start(prompt, tab=tab)
        if before:
            before(run)
        self.app.call("test.holdModel", {"on": False})
        return self.finish(run["runId"], timeout=timeout)

    def sampled(self, run_id, timeout=240):
        """Run states, steps and canvas edges as they change, until the run ends."""
        samples = []
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            run = self.run_of(run_id)
            edges = [e for e in self.ui()["canvas"]["edges"] if e["runId"] == run_id]
            samples.append((time.time(), run["state"], [dict(s) for s in run["steps"]], edges))
            if run["state"] in ENDED:
                return run, samples
            time.sleep(0.1)
        self.fail(f"run {run_id} did not end")


class LiveRunTests(LiveBase):
    # VAL-TASK-003 (read-only run with a model stop)
    def test_a_read_only_run_with_a_model_stop_completes(self):
        ended = self.task("Look at your page with observe, then tell me in one sentence what its "
                          "heading says. Do not click or type anything.")
        self.assertEqual((ended["state"], ended["reason"]), ("completed", None), ended)
        kinds = [s["kind"] for s in ended["steps"]]
        self.assertIn("observe", kinds)
        self.assertNotIn("act", kinds)
        self.assertGreater(ended["costUSD"], 0)
        self.assertGreater(len(self.spend_of(ended["sessionId"])), 0)
        self.assertEqual(self.db("select count(*) from actions where session_id = ?",
                                 (ended["sessionId"],)), [(0,)])
        self.assertIsNone(self.holder())
        self.record("run-live-read-only", run=ended)

    # VAL-MODEL-009: the provider is given a response id it never issued (the fault it answers
    # for a response it lost) and the real model carries on from the replayed transcript.
    def test_a_lost_chained_response_is_replayed_once_and_the_run_completes(self):
        log_path = os.path.join(self.app.data_dir, "logs", "photon.log")
        mark = os.path.getsize(log_path)
        run = self.start("First call tabs. Then observe your page. Then tell me in one sentence "
                         "what its heading says. Do not click or type anything.")
        self.assertTrue(self.app.call("test.breakChain", {"on": True})["on"])
        self.app.call("test.holdModel", {"on": False})
        ended = self.finish(run["runId"], timeout=180)
        self.assertEqual((ended["state"], ended["reason"]), ("completed", None), ended)
        with open(log_path) as log:
            log.seek(mark)
            lines = log.read().splitlines()
        session = run["sessionId"]
        failed = [l for l in lines if "model call failed" in l and f"source={session}:loop" in l]
        replays = [l for l in lines if "chain replay" in l]
        done = [l for l in lines if "model call provider=" in l and f"source={session}:loop" in l]
        self.assertEqual(len(failed), 1, failed)
        self.assertIn("error=rejected", failed[0])
        self.assertEqual(len(replays), 1, replays)
        self.assertRegex(replays[0], r"chain replay reason=missing-reference turn=\d+$")
        self.assertLess(lines.index(failed[0]), lines.index(replays[0]))
        self.assertFalse(self.app.call("test.breakChain", {"on": False})["on"])
        loop = [e for e in self.spend_of(session) if e["source"].endswith(":loop")]
        self.assertEqual(len(loop), len(done), (loop, done))
        self.assertGreaterEqual(len(loop), 2)
        self.assertIsNone(self.holder())
        self.record("run-live-chain-replay", run=ended, failed=failed, replays=replays,
                    ledgerEntries=len(loop))

    # VAL-TASK-003 (every write confirmed, then a failed write)
    def test_a_confirmed_write_completes_and_a_write_that_changes_nothing_fails(self):
        done = self.task("Click the Count button on your page once, look at the page again, "
                         "then say you are done.")
        rows = self.db("select state from actions where session_id = ?", (done["sessionId"],))
        self.assertEqual(done["state"], "completed", (done, rows))
        self.assertTrue(rows and all(state == "confirmed" for (state,) in rows), rows)
        acts = [s for s in done["steps"] if s["kind"] == "act"]
        self.assertTrue(acts and all(s["state"] == "confirmed" and s["actionId"] for s in acts), acts)
        self.record("run-live-write-completed", run=done, rows=rows)
        self.assertEqual(self.status_text(), "Counted 1")

        before = len(self.fixtures.log())
        self.navigate(f"{self.start_page}?load={next(self.loads)}")
        self.wait_input_ready(before)
        failed = self.task("Click the Inert button on your page once, then tell me what happened.")
        rows = self.db("select state from actions where session_id = ?", (failed["sessionId"],))
        self.assertEqual(failed["state"], "failed", (failed, rows))
        self.assertIn("a write ended", failed["reason"])
        self.assertTrue(rows and "confirmed" not in {state for (state,) in rows}, rows)
        self.record("run-live-write-failed", run=failed, rows=rows)

    def test_a_sensitive_act_puts_the_run_in_waiting_approval_until_it_is_decided(self):
        run = self.start("Click the Delete draft button on your page, then say you are done.")
        self.app.call("test.holdModel", {"on": False})
        waiting = bs.wait_until(lambda: (lambda r: r if r["state"] == "waiting-approval" else None)(
            self.run_of(run["runId"])), timeout=90, what="the run to wait for approval")
        card = self.pending()
        self.assertEqual([a["sessionId"] for a in card], [run["sessionId"]])
        self.assertEqual(self.status_text(), "Nothing deleted")
        time.sleep(1)
        self.assertEqual(self.run_of(run["runId"])["state"], "waiting-approval")
        self.app.call("approval.decide", {"approvalId": card[0]["approvalId"], "allow": True})
        ended = self.finish(run["runId"], timeout=120)
        self.assertEqual(ended["state"], "completed", ended)
        self.assertEqual(self.status_text(), "Draft deleted")
        self.assertEqual(self.pending(), [])
        self.record("run-live-approval", waiting=waiting, run=ended)


class LiveTrailTests(LiveBase):
    # VAL-SPATIAL-014
    def test_trail_edges_come_only_from_the_pages_the_run_actually_called(self):
        b = self.open_other("act.html")
        c = self.open_other("article.html")
        self.app.call("test.holdModel", {"on": True})
        run = self.start(f"Do these in order. 1) observe your own page. 2) extract tab {b}. "
                         f"3) observe tab {b}, then click its Count button with act. 4) Say you are "
                         "done. You already control both pages. Do not use any other tab.")
        self.grant_tab(run["sessionId"], b)
        self.app.call("test.holdModel", {"on": False})
        ended, samples = self.sampled(run["runId"])
        nodes = {n["tabId"]: n["id"] for n in self.ui()["canvas"]["nodes"] if n["tabId"]}
        edges = [e for e in self.ui()["canvas"]["edges"] if e["runId"] == run["runId"]]
        called = {s["tabId"] for s in ended["steps"] if s["tabId"]}
        self.assertIn(b, called, ended)
        self.assertNotIn(c, called)
        self.assertEqual([(e["from"], e["to"], e["kind"]) for e in edges],
                         [(nodes[self.tab], nodes[b], "museUsed")])
        bs.wait_until(lambda: self.db("select count(*) from canvas_edges where run_id = ?",
                                      (run["runId"],)) == [(1,)], what="the edge to be saved")
        # Never an edge in a sample before a step on the target page began.
        for stamp, _, steps, seen in samples:
            if seen:
                self.assertTrue(any(s["tabId"] == b and s["state"] != "working" for s in steps),
                                (stamp, steps, seen))
        first = next(t for t, _, _, seen in samples if seen)
        step_end = min(s["endedAt"] for s in ended["steps"] if s["tabId"] == b and s["endedAt"])
        self.assertGreaterEqual(first + 0.5, step_end)
        self.assertEqual(ended["tabId"], self.tab)
        self.overview_trail(run["runId"], nodes[self.tab], nodes[b])
        self.record("run-live-trail", run=ended, edges=edges, nodes=nodes,
                    firstEdgeSeenAt=first, steps=[(s["kind"], s["tabId"], s["state"]) for s in ended["steps"]])

    def overview_trail(self, run_id, owner, used, at_least=11):
        """The owner's node lists the run instead of a self-edge, and the museUsed edge is drawn
        copper, dotted, with "Muse" in the legend and copper pixels between the two cards."""
        if self.ui()["presentation"] != "overview":
            self.app.call("test.key", {"key": "\\", "modifiers": ["cmd", "shift"]})
            bs.wait_until(lambda: self.ui()["presentation"] == "overview", what="the overview")
        bs.wait_until(lambda: not self.app.call("test.motion")["inFlight"], what="motion at rest")
        overview = self.ui()["overview"]
        cards = {n["id"]: n for n in overview["nodes"]}
        self.assertEqual(cards[owner]["runs"][-1], run_id)
        self.assertNotEqual(cards[owner]["muse"], "")
        self.assertEqual(cards[used]["runs"], [])
        edges = [e for e in overview["edges"] if e["kind"] == "museUsed"]
        self.assertEqual([(e["from"], e["to"]) for e in edges], [(owner, used)])
        self.assertEqual((edges[0]["color"], edges[0]["cap"]), ("b66a48", "round"))
        self.assertTrue(edges[0]["dash"], edges[0])
        self.assertEqual([e for e in overview["edges"] if e["from"] == e["to"]], [])
        self.assertIn("Muse", [i["label"] for i in overview["legend"]["items"]])
        path = f"{LOG_DIR}/run-live-trail.png"
        self.app.call("test.screenshot", {"path": path})
        image = png.Image(path)
        scale = image.width / self.ui()["windowFrame"]["w"]
        boxes = [cards[owner]["frame"], cards[used]["frame"]]
        x0, x1 = min(b["x"] for b in boxes), max(b["x"] + b["w"] for b in boxes)
        y0, y1 = min(b["y"] for b in boxes) - 40, max(b["y"] + b["h"] for b in boxes)

        def on_card(x, y):
            return any(b["x"] - 2 <= x <= b["x"] + b["w"] + 2 and b["y"] - 40 <= y <= b["y"] + b["h"] + 2
                       for b in boxes)
        copper = png.hex_rgb("b66a48")
        found = sum(1 for x in range(int(x0), int(x1)) for y in range(int(y0), int(y1))
                    if not on_card(x, y) and png.close(image.pixel(int(x * scale), int(y * scale)), copper, 24))
        self.assertGreaterEqual(found, at_least, "copper pixels along the museUsed edge")

    def test_a_run_that_makes_no_page_call_records_no_edge(self):
        self.open_other("act.html")
        ended = self.task("Do not use any tool. Just reply with the word ready.")
        self.assertEqual(ended["steps"], [])
        self.assertEqual(self.db("select count(*) from canvas_edges where run_id = ?",
                                 (ended["runId"],)), [(0,)])
        self.assertEqual(ended["state"], "completed", ended)
        self.record("run-live-no-calls", run=ended)

    def open_other(self, page):
        tab = self.app.call("open_tab", {"url": url(page), "activate": False})["id"]
        self.wait_loaded(url(page), tab)
        self.addCleanup(self.app.call, "test.closeTab", {"tabId": tab})
        return tab

    def grant_tab(self, session, tab):
        request = self.app.call("request_control", {"sessionId": session, "tabId": tab})
        if request["state"] != "granted":
            self.app.call("control.decide", {"requestId": request["requestId"], "allow": True})
        self.assertEqual(self.ui_tab(tab).get("controllerSession"), session)


class LiveGroundTests(PermBase):
    """Muse's computer tool on a page of icons that no accessible name matches (VAL-ACT-004 live,
    VAL-ACT-011, VAL-ACT-012). Every model call here is a grounding or an acknowledgement."""

    start_page = "icons.html"

    @classmethod
    def setUpClass(cls):
        if not LIVE:
            raise unittest.SkipTest("live Meta call: not run (no BARESTATE_LIVE_META/BARESTATE_SPEND_LOG)")
        # The contributor tier may train on its inputs, so only this synthetic page reaches it.
        patched = ATOM | {"BARESTATE_MODEL"}
        saved = {key: os.environ.get(key) for key in patched}
        os.environ.update({key: "/nonexistent/atom" for key in ATOM})
        os.environ["BARESTATE_MODEL"] = CONTRIBUTOR
        try:
            super().setUpClass()
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def setUp(self):
        self.app.call("test.grounding", {"reset": True})
        super().setUp()
        self.mark_spend = self.spend()
        self.acked0 = len(self.log_lines("acknowledged"))
        self.carried0 = len(self.log_lines("carries"))

    def spend(self):
        with open(os.environ["BARESTATE_SPEND_LOG"]) as spend:
            return json.load(spend)

    def mine(self, suffix=None):
        new = self.spend()["entries"][len(self.mark_spend["entries"]):]
        entries = [e for e in new if e["source"].startswith(f"{self.session}:")]
        return [e for e in entries if suffix is None or e["source"].endswith(suffix)]

    def record(self, name, **evidence):
        now = self.spend()
        evidence["spend"] = {"requests": len(now["entries"]) - len(self.mark_spend["entries"]),
                             "usd": round(now["total_usd"] - self.mark_spend["total_usd"], 6),
                             "sources": [(e["source"], e["model"]) for e in self.mine()]}
        save(f"{name}.json", evidence)
        print(f"\n{name}: {evidence['spend']}", flush=True)

    def ground(self, client_id, words, observation=None):
        observation = observation or self.observe()
        client = bs.Rpc(self.app.data_dir, timeout=120)
        try:
            return client.call("act", {"sessionId": self.session, "clientActionId": client_id,
                                       "observationId": observation["id"], "kind": "click",
                                       "instruction": words})
        finally:
            client.close()

    def quoted(self, name, checked=False):
        """A sensitive click held for approval; with `checked`, one the model attached a safety check
        to. The model abstains or leaves the check off now and then, so it is asked up to four times."""
        for attempt in range(4):
            before = self.carried()[0]
            row = self.ground(f"{name}{attempt}", "delete draft")
            if row["state"] == "quoted" and (not checked or self.carried()[0] > before):
                self.assertEqual(self.rung(row), "muse")
                return row
            if row["state"] == "quoted":
                self.assertEqual(self.decide(row, False)["state"], "denied")
        self.fail(f"no {'checked ' if checked else ''}click was held for approval in four tries")

    def carried(self):
        """Safety checks the model attached to clicks since this test began, and checks acknowledged."""
        return (len(self.log_lines("carries")) - self.carried0,
                len(self.log_lines("acknowledged")) - self.acked0)

    def rung(self, row):
        return self.db("select rung from actions where id = ?", (row["id"],))[0][0]

    def log_lines(self, text):
        path = os.path.join(self.app.data_dir, "logs", "photon.log")
        with open(path) as log:
            return [line.rstrip() for line in log if text in line]

    # VAL-ACT-004 (live case), VAL-ACT-011, VAL-ACT-012 (an allowed action)
    def test_muse_grounds_through_a_computer_call_and_the_click_lands_once(self):
        self.grant()
        for attempt in range(3):
            row = self.ground("gear" if attempt == 0 else f"gear{attempt}", "settings")
            row = row if row["state"] in FINAL else self.settled(row)
            if row.get("reason") != "needs-human":
                break
        self.assertEqual((row["state"], self.rung(row)), ("confirmed", "muse"), row)
        self.assertEqual(self.settled_clicks(1), ["gear"])
        grounds, acks = self.mine("ground"), self.mine("ack")
        self.assertTrue(grounds)
        self.assertEqual({e["model"] for e in grounds + acks}, {CONTRIBUTOR})
        # A pending check is acknowledged exactly once, in one follow-up, after the click was allowed.
        carried, acked = self.carried()
        self.assertEqual((len(acks), acked), (carried, carried), [e["source"] for e in self.mine()])
        self.assertLessEqual(carried, 1)
        order = [e["source"].rsplit(":", 1)[1] for e in self.mine()]
        self.assertEqual(order[-1], "ack" if carried else "ground", order)
        self.assertEqual(self.db("select count(*) from actions where client_action_id like 'gear%' "
                                 "and state = 'confirmed'"), [(1,)])
        self.record("act-live-muse-rung", row=row, rung="muse", clicks=self.clicks())

    # VAL-ACT-011
    def test_a_point_that_matches_no_control_is_not_dispatched(self):
        self.grant()
        row = self.ground("nothing", "the trash can")
        row = row if row["state"] in {"failed", "cancelled", "confirmed"} else self.settled(row)
        self.assertEqual(row["state"], "failed", row)
        # Muse either finds nothing or points at a control the words do not name.
        self.assertRegex(row["reason"], r"^(needs-human|point-rejected: .+)$")
        self.assertEqual(self.settled_clicks(), [])
        self.assertEqual(self.mine("ack"), [])
        self.record("act-live-no-match", row=row)

    # VAL-ACT-011
    def test_a_human_click_while_the_model_is_thinking_lands_nothing(self):
        for attempt in range(3):
            self.grant()
            observation = self.observe()
            results = []
            worker = threading.Thread(
                target=lambda: results.append(self.ground(f"mid{attempt}", "settings", observation)))
            worker.start()
            # Past the row and the control check, with the model's request on its way.
            bs.wait_until(lambda: self.app.call("test.grounding")["calls"].count("muse: settings")
                          > attempt, what="the model call to start")
            self.app.call("test.click", {"tabId": self.tab})
            worker.join(120)
            row = results[0] if results[0]["state"] in FINAL else self.settled(results[0])
            # The model may find nothing to click; only a click it did return is under test.
            if row.get("reason") != "needs-human":
                break
        self.assertEqual((row["state"], row["reason"]), ("cancelled", "stale: epoch"), row)
        self.assertFalse({"gear", "pen", "bin"} & set(self.settled_clicks()))
        self.assertEqual(self.mine("ack"), [])
        self.record("act-live-takeover", row=row, clicks=self.clicks())

    # VAL-ACT-012: a sensitive click stays quoted with no acknowledgement; Deny sends none, Allow sends it once
    def test_a_sensitive_muse_click_is_acknowledged_only_after_allow_and_never_after_deny(self):
        self.grant()
        denied = self.quoted("deny")
        self.wait_card()
        self.assertEqual(self.mine("ack"), [])
        self.assertEqual(self.decide(denied, False)["state"], "denied")
        final = self.settled(denied)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "denied"))
        self.assertEqual(self.mine("ack"), [])
        self.assertEqual(self.settled_clicks(), [])

        allowed = self.quoted("allow", checked=True)
        time.sleep(2)
        self.assertEqual(self.mine("ack"), [])
        self.assertEqual(self.settled_clicks(), [])
        self.decide(allowed, True)
        final = self.settled(allowed)
        self.assertEqual(final["state"], "confirmed", final)
        self.assertEqual(self.settled_clicks(1), ["bin"])
        self.assertEqual(len(self.mine("ack")), 1)
        self.assertEqual(self.log_lines("could not acknowledge"), [])
        carried, acked = self.carried()
        self.assertEqual(acked, 1)
        self.record("act-live-safety-checks", denied=denied, allowed=final)


if __name__ == "__main__":
    unittest.main()
