"""The live acceptance checks that need the real model: first-visit reachability of Start task, Stop
task and Show Muse activity (VAL-CROSS-004), a task from a focused page with its trail, approval and
takeover (VAL-CROSS-005), and the screenshots of that real Muse trail for the fidelity comparison
(VAL-SPATIAL-012).

They need BARESTATE_LIVE_META=1 and a spend ledger; the first test holds the model so only its
second run spends. Read the spend from `self.cost()` in the saved evidence."""
import os
import time
import unittest

import bs
import test_run
from appcase import LOG_DIR, save
from test_perm import LIVE
from test_run import ENDED, LiveBase
from test_tasks import TRIVIAL, TaskCase

PROMPT = ("Do these in order. 1) observe your own page. 2) observe tab {b}. 3) Click the Delete "
          "draft button on your own page with act. 4) Say you are done. You already control both "
          "pages. Do not use any other tab.")
LABELS = ["connecting", "working", "waiting for approval", "working"]


@unittest.skipUnless(LIVE, "live Meta call: not run (no BARESTATE_LIVE_META/BARESTATE_SPEND_LOG)")
class LiveReachabilityTests(TaskCase):
    def command(self, query, title):
        self.open_launcher()
        self.type_text(query)
        row = next(r for r in self.launcher()["rows"] if r["kind"] == "command" and r["title"] == title)
        return row

    def run_command(self, query, title):
        row = self.command(query, title)
        self.assertTrue(row["enabled"], row)
        self.move_to(row)
        self.key("Return")

    def start_task(self, prompt, through):
        if through == "commandButton":
            self.call("test.click", {"target": "commandButton"})
            bs.wait_until(lambda: self.launcher()["open"], what="the launcher from the command button")
        else:
            self.open_launcher()
        self.clear_field()
        self.type_text(prompt)
        row = next(r for r in self.launcher()["rows"] if r["kind"] == "startTask")
        self.call("test.click", {"target": f"launcherRow:{row['id']}"})
        return bs.wait_until(lambda: (lambda r: r[-1] if r else None)(self.new_runs()), what="the run")

    def test_start_task_stop_task_and_show_muse_activity_work_on_a_fresh_data_dir(self):
        """VAL-CROSS-004"""
        self.assertEqual(self.db("select count(*) from bookmarks"), [(0,)])
        self.assertEqual(self.db("select count(*) from history where url not like 'about:%'"), [(0,)])
        page = self.open_page("launcher.html")
        first = self.start_task(TRIVIAL, "cmdT")
        self.assertEqual((first["tabId"], first["state"]), (page["id"], "pending"))
        self.assertEqual(len(self.new_runs()), 1, "Start task made one run")

        self.run_command("Show Muse activity", "Show Muse activity")
        view = bs.wait_until(lambda: self.activity() if self.activity().get("open") else None,
                             what="the activity view")
        self.assertEqual(view["runId"], first["runId"])
        self.close_activity()

        self.run_command("Stop", f"Stop {TRIVIAL}")
        stopped = self.wait_stopped(first["runId"], time.monotonic())
        self.assertEqual(stopped["reason"], "stopped")
        self.assertEqual(len(self.new_runs()), 1, "Stop task made no run")
        self.open_launcher()
        self.type_text("Stop")
        self.assertEqual([r for r in self.launcher()["rows"]
                          if r["kind"] == "command" and r["title"].startswith("Stop") and r["enabled"]], [])
        self.close_launcher()

        second = self.start_task(TRIVIAL, "commandButton")
        self.assertEqual(len(self.new_runs()), 2)
        self.call("test.holdModel", {"on": False})
        done = bs.wait_until(lambda: (lambda r: r if r["state"] in ENDED else None)(
            self.run_of(second["runId"])), timeout=180, what="the real run to end")
        self.assertEqual(done["state"], "completed", done)
        self.run_command("Show Muse activity", "Show Muse activity")
        view = bs.wait_until(lambda: self.activity() if self.activity().get("open") else None,
                             what="the activity view of the real run")
        self.assertEqual(view["runId"], second["runId"])
        self.close_activity()
        titles = sorted(i["title"] for menu in self.call("test.menu") for i in menu.get("items", [])
                        if "title" in i)
        save("cross-004-live.json", {"runs": [first, stopped, done], "menuTitles": titles})


@unittest.skipUnless(LIVE, "live Meta call: not run (no BARESTATE_LIVE_META/BARESTATE_SPEND_LOG)")
class LiveAcceptanceTests(LiveBase):
    open_other = test_run.LiveTrailTests.open_other
    grant_tab = test_run.LiveTrailTests.grant_tab
    overview_trail = test_run.LiveTrailTests.overview_trail

    def key(self, key, *modifiers):
        self.app.call("test.key", {"key": key, "modifiers": list(modifiers)})

    def launcher(self):
        return self.ui()["launcher"]

    def open_launcher(self):
        self.key("t", "cmd")
        bs.wait_until(lambda: self.launcher()["open"]
                      and self.ui()["firstResponder"].get("chromeId") == "launcherField",
                      what="the launcher")
        self.key("a", "cmd")
        self.key("Backspace")

    def close_launcher(self):
        if self.launcher()["open"]:
            self.key("Escape")
            bs.wait_until(lambda: not self.launcher()["open"], what="the launcher closed")

    def run_row(self, run):
        """What the launcher's rows say about the run now."""
        self.open_launcher()
        bs.wait_until(lambda: self.launcher()["query"] == "" and self.launcher()["current"],
                      what="the empty-query rows")
        row = next(r for r in self.launcher()["rows"] if r["kind"] == "run" and r["target"] == run)
        self.close_launcher()
        return {k: row[k] for k in ("title", "subtitle", "status")}

    def label(self):
        return self.ui()["focus"]["museLabel"]["text"]

    def wait_label(self, text):
        bs.wait_until(lambda: self.label() == text, what=f"the label {text!r}")

    def clicks_once(self, wanted):
        self.assertEqual(self.settled_clicks(len(wanted)), wanted)

    def test_a_task_from_a_focused_page_observes_a_second_page_asks_and_is_taken_over(self):
        """VAL-CROSS-005, VAL-SPATIAL-012 (the real Muse trail), VAL-MOTION-006 (live)"""
        self.app.call("test.windowSize", {"w": 1440, "h": 900})
        self.assertEqual(self.ui()["presentation"], "focused")
        b = self.open_other("act.html")
        owner = self.tab
        timeline = []

        def watch(until, timeout=150, what="the run", showing=None):
            """Run state, the focused page's label and the run's edges, until `until` holds
            (and the page shows `showing`, when given: the UI and the run are two reads)."""
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                # One UI snapshot, read before the run: an edge only appears after its step ended
                # and steps only move forward, so a run read taken later cannot contradict it.
                ui = self.ui()
                run = self.run_of(run_id)
                label = ui["focus"]["museLabel"]["text"]
                edges = [e for e in ui["canvas"]["edges"] if e["runId"] == run_id]
                timeline.append((time.time(), run["state"], label, edges, [dict(s) for s in run["steps"]]))
                if until(run) and (showing is None or label == showing):
                    return run
                time.sleep(0.05)
            self.fail(f"timed out waiting for {what}: {timeline[-1][1:3]}")

        self.open_launcher()
        self.app.call("test.type", {"text": PROMPT.format(b=b)})
        bs.wait_until(lambda: self.launcher()["query"] == PROMPT.format(b=b), what="the prompt")
        start = next(r for r in self.launcher()["rows"] if r["kind"] == "startTask")
        self.app.call("test.click", {"target": f"launcherRow:{start['id']}"})
        run = bs.wait_until(lambda: self.runs()[-1:] and self.runs()[-1], what="the run")
        run_id = run["runId"]
        self.assertEqual(run["state"], "pending")
        self.assertEqual(run["tabId"], owner)
        self.grant_tab(run["sessionId"], b)
        self.wait_label("Muse · connecting")
        timeline.append((time.time(), "pending", self.label(), [], []))
        rows = {"pending": self.run_row(run_id)}
        self.assertEqual((rows["pending"]["title"], rows["pending"]["status"]),
                         ("Connecting to Muse", "loading"))

        self.app.call("test.holdModel", {"on": False})
        watch(lambda r: r["state"] == "running", timeout=60, what="working")
        self.app.call("test.holdModel", {"on": True})
        rows["first working"] = self.run_row(run_id)
        self.assertEqual(rows["first working"]["subtitle"], "Muse · working")
        self.wait_label("Muse · working")
        self.app.call("test.holdModel", {"on": False})
        waiting = watch(lambda r: r["state"] == "waiting-approval", what="waiting for approval")
        card = self.wait_card()
        self.assertEqual(self.label(), "Muse · waiting for approval")
        focus = self.ui()["focus"]
        self.assertTrue(card["allow"]["hittable"])
        called = [s for s in waiting["steps"] if s["tabId"] == b]
        self.assertTrue(called, waiting)
        nodes = {n["tabId"]: n["id"] for n in self.ui()["canvas"]["nodes"] if n["tabId"]}
        edges = [e for e in self.ui()["canvas"]["edges"] if e["runId"] == run_id]
        self.assertEqual([(e["from"], e["to"], e["kind"]) for e in edges],
                         [(nodes[owner], nodes[b], "museUsed")])
        for stamp, _, _, seen, steps in timeline:
            if seen:
                self.assertTrue(any(s["tabId"] == b and s["state"] != "working" for s in steps),
                                "an edge before the call on the second page finished")
        first_edge = next(t for t, _, _, seen, _ in timeline if seen)
        ended = min(s["endedAt"] for s in called if s["endedAt"])
        self.assertGreaterEqual(first_edge + 0.5, ended)

        # The row is read while the approval waits; the card hides over the launcher and returns.
        rows["waiting-approval"] = self.run_row(run_id)
        self.assertEqual(rows["waiting-approval"]["subtitle"], "Muse · waiting for approval")
        self.wait_card()

        # Hold the model so that, once Allow once has run the action, the run stays alive.
        self.app.call("test.holdModel", {"on": True})
        self.assertEqual(self.status_text(), "Nothing deleted")
        self.app.call("test.click", {"target": "approvalAllow"})
        working = watch(lambda r: r["state"] == "running", timeout=60, what="working after approval",
                        showing="Muse · working")
        self.assertEqual(self.status_text(), "Draft deleted")
        rows["working"] = self.run_row(run_id)
        self.assertEqual(rows["working"]["subtitle"], "Muse · working")
        self.wait_label("Muse · working")
        confirmed = self.db("select state from actions where session_id = ?", (run["sessionId"],))
        self.assertTrue(confirmed and all(state == "confirmed" for (state,) in confirmed), confirmed)
        self.clicks_once(["delete"])
        self.assertEqual(self.pending(), [])

        # Order of what was shown: connecting, working, waiting for approval, working.
        shown = [label.removeprefix("Muse · ") for _, _, label, _, _ in timeline]
        order = [l for i, l in enumerate(shown) if i == 0 or l != shown[i - 1]]
        self.assertEqual(order[:3], LABELS[:3], order)
        self.assertEqual(order[-1], LABELS[3], order)

        # A person takes the page back while a second sensitive act waits under the old epoch.
        observation = self.observe()
        epoch = self.ui_tab()["epoch"]
        late = self.act("late", observation, "click", "Delete draft", session=run["sessionId"])
        self.assertEqual(late["state"], "quoted", late)
        self.wait_card()
        self.app.call("test.click", {"tabId": owner})
        taken = self.run_of(run_id)
        self.assertEqual((taken["state"], taken["reason"]), ("stopped", "taken-over"))
        self.assertGreater(self.ui_tab()["epoch"], epoch)
        final = self.settled(late, run["sessionId"])
        self.assertEqual(final["state"], "cancelled", final)
        self.assertTrue(final["reason"].startswith("stale"), final)
        self.card_gone()
        self.wait_label("Muse · stopped")
        self.request_owner(run["sessionId"], owner)
        old = self.settled(self.act("old", observation, "click", "Delete draft",
                                    session=run["sessionId"]), run["sessionId"])
        self.assertEqual((old["state"], old["reason"]), ("cancelled", "stale: epoch"))
        self.clicks_once(["delete", "pad"])
        rows["stopped"] = self.run_row(run_id)
        self.assertEqual(rows["stopped"]["subtitle"], "Muse · stopped · taken-over")
        self.screenshot_focus(focus)

        # The real trail, drawn by the overview, for the screen-1 and screen-4 comparison.
        self.key("\\", "cmd", "shift")
        bs.wait_until(lambda: self.ui()["presentation"] == "overview", what="the overview")
        self.overview_trail(run_id, nodes[owner], nodes[b], at_least=6)
        save("cross-005-live.json", {"run": taken, "rows": rows, "labels": order, "edges": edges,
                                     "actions": [late, final, old], "epoch": epoch,
                                     "card": card, "spend": self.cost()})
        print(f"\ncross-005-live: {self.cost()}", flush=True)

    def request_owner(self, session, tab):
        request = self.app.call("request_control", {"sessionId": session, "tabId": tab})
        if request["state"] != "granted":
            self.app.call("control.decide", {"requestId": request["requestId"], "allow": True})

    def screenshot_focus(self, focus):
        """The focused page with the run's label, before the overview is shown again."""
        bs.wait_until(lambda: not self.app.call("test.motion")["inFlight"], what="motion at rest")
        self.app.call("test.screenshot", {"path": os.path.join(LOG_DIR, "run-live-focused.png")})
        shown = self.ui()["focus"]
        label, trails = shown["museLabel"], shown["trails"]
        save("run-live-focused.json", {"label": label, "card": focus["card"], "trails": trails})
        # screen-4: the card at (468, 208) 632 x 532, "Muse · <status>" text from x 824 on the
        # label row, and a copper dotted trail from the page's real Muse call.
        card = focus["card"]
        self.assertLessEqual(abs(card["x"] - 468) + abs(card["y"] - 208), 8)
        self.assertLessEqual(abs(label["frame"]["x"] - 824), 8, label)
        self.assertLessEqual(abs(label["frame"]["y"] + label["frame"]["h"] / 2 - 186), 8, label)
        self.assertEqual([(t["kind"], t["color"], t["dash"], t["cap"], t["width"]) for t in trails],
                         [("museUsed", "b66a48", [1, 7], "round", 1.25)])
