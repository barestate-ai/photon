"""The Photon task UI over the run engine (VAL-TASK-001, 002, 004 to 009, VAL-ACT-005,
VAL-CROSS-006, the node half of VAL-SPATIAL-014): run rows, the Muse label, the run activity view,
Stop, and the Muse-unavailable recovery. Everything shown is checked against `run.list`.

The model is held (or offline) in every test but the live one, so a run stays where the test put
it: `test.runState` and `test.runStep` stand in for the states and steps a model cannot be made to
produce on demand. The live test needs BARESTATE_LIVE_META=1 and a spend ledger."""
import json
import os
import time
import unittest
from urllib.parse import parse_qs, urlsplit

import bs
import png
from appcase import LOG_DIR, save, url
from test_access import flatten
from test_launcher import KYOTO, LauncherCase
from test_perm import LIVE
from test_run import ENDED, RunBase

PETROL = png.hex_rgb("1a6872")
SELECTION = png.hex_rgb("e7eeee")
TRIVIAL = "Do not use any tool. Just reply with the word ready."


class TaskCase(LauncherCase):
    def setUp(self):
        super().setUp()
        self.addCleanup(self.clean)
        self.call("test.holdModel", {"on": True})

    def clean(self):
        self.close_launcher()
        self.close_activity()
        for run in self.runs():
            if run["state"] not in ENDED:
                self.call("run.stop", {"runId": run["runId"]})
        self.call("test.holdModel", {"on": False})
        self.call("test.modelOffline", {"on": False})

    # Runs and what shows them.

    def start(self, prompt="Read this page", tab=None):
        params = {"prompt": prompt, "origin": "mac"}
        if tab:
            params["tabId"] = tab
        return self.call("run.start", params)

    def run_of(self, run_id):
        return next(r for r in self.runs() if r["runId"] == run_id)

    def state(self, run_id, state, reason=None):
        params = {"runId": run_id, "state": state}
        if reason:
            params["reason"] = reason
        return self.call("test.runState", params)

    def run_rows(self, launcher=None):
        return [r for r in (launcher or self.launcher())["rows"] if r["kind"] == "run"]

    def menu_items(self):
        return {item["title"]: item for menu in self.call("test.menu")
                for item in menu.get("items", []) if "title" in item}

    def presentation(self):
        return self.ui()["presentation"]

    def show(self, wanted):
        if self.presentation() != wanted:
            self.key("\\", "cmd", "shift")
            bs.wait_until(lambda: self.presentation() == wanted, what=f"presentation {wanted}")
            bs.wait_until(lambda: not self.call("test.motion")["inFlight"], what="motion at rest")

    def node_of(self, tab):
        return next(n for n in self.ui()["canvas"]["nodes"] if n["tabId"] == tab)

    def drawn(self, tab):
        """What the overview draws for the page: its node with the Muse label and run ids."""
        self.show("overview")
        node = self.node_of(tab)["id"]
        return next(n for n in self.ui()["overview"]["nodes"] if n["id"] == node)

    def focused_label(self):
        self.show("focused")
        return self.ui()["focus"]["museLabel"]["text"]

    def screenshot(self, name):
        bs.wait_until(lambda: not self.call("test.motion")["inFlight"], what="motion at rest")
        path = f"{LOG_DIR}/{name}.png"
        self.call("test.screenshot", {"path": path})
        return png.Image(path)

    def document(self, tab):
        frame = self.call("test.devtools", {"tabId": tab, "method": "Page.getFrameTree"})
        return [frame["frameTree"]["frame"]["loaderId"], self.evaluate("performance.timeOrigin", tab)]

    # The activity view.

    def activity(self):
        return self.ui()["activity"]

    def close_activity(self):
        if self.activity().get("open"):
            self.key("Escape")
            bs.wait_until(lambda: not self.activity()["open"], what="the activity view closed")

    def open_activity(self):
        self.open_launcher()
        self.type_text("Show Muse activity")
        row = next(r for r in self.launcher()["rows"]
                   if r["kind"] == "command" and r["title"] == "Show Muse activity")
        self.assertTrue(row["enabled"], row)
        self.move_to(row)
        self.key("Return")
        return bs.wait_until(lambda: self.activity() if self.activity().get("open") else None,
                             what="the activity view")

    def tree(self):
        return list(flatten(self.call("test.ax")))

    def wait_stopped(self, run_id, started):
        stopped = bs.wait_until(lambda: (lambda r: r if r["state"] == "stopped" else None)(
            self.run_of(run_id)), timeout=2, what=f"{run_id} stopped")
        self.assertLess(time.monotonic() - started, 2.0)
        return stopped


class StartTests(TaskCase):
    def test_start_task_commits_a_run_on_the_current_page_and_closes_the_launcher(self):
        """VAL-TASK-001 (the part that needs no model), VAL-SPATIAL-014 (the node)"""
        page = self.open_page("launcher.html")
        before = self.snapshot()
        self.open_launcher()
        self.type_text(KYOTO)
        self.assertEqual(self.new_runs(), [])
        self.key("ArrowDown")
        self.key("ArrowUp")
        self.assertEqual(self.new_runs(), [])
        self.key("Return")
        self.wait_launcher(False)
        run, = self.new_runs()
        self.assertEqual((run["prompt"], run["origin"], run["tabId"], run["state"]),
                         (KYOTO, "mac", page["id"], "pending"))
        tab = next(t for t in self.ui()["tabs"] if t["id"] == page["id"])
        self.assertEqual((tab["controller"], tab["controllerSession"]), ("agent", run["sessionId"]))
        self.assertEqual(self.snapshot()["tabs"], before["tabs"])
        self.assertEqual(self.requests(), before["requests"])
        drawn = self.drawn(page["id"])
        self.assertEqual((drawn["muse"], drawn["runs"]), ("Muse · connecting", [run["runId"]]))
        self.assertEqual([e for e in self.ui()["canvas"]["edges"] if e["from"] == e["to"]], [])
        self.open_launcher()
        first = self.launcher()["rows"][0]
        self.assertEqual((first["kind"], first["title"]), ("command", f"Stop {KYOTO}"))
        save("task-start.json", {"run": run, "node": drawn, "launcher": self.launcher()})

    def test_searching_or_opening_never_starts_a_run(self):
        """VAL-TASK-001"""
        self.open_page("launcher.html")
        self.open_launcher()
        self.type_text(KYOTO)
        search = next(r for r in self.launcher()["rows"] if r["kind"] == "search")
        self.call("test.click", {"target": f"launcherRow:{search['id']}"})
        bs.wait_until(lambda: any("q=" in t["url"] for t in self.tabs()), what="the search tab")
        self.assertEqual(self.new_runs(), [])


class StateTests(TaskCase):
    def test_labels_and_rows_show_exactly_the_run_state(self):
        """VAL-TASK-002, VAL-SPATIAL-014 (the node lists its run)"""
        page = self.open_page("launcher.html")
        other = self.open_page("article.html")
        self.call("test.activateTab", {"tabId": page["id"]})
        self.show("overview")
        document = self.document(page["id"])
        wanted = {"pending": "connecting", "running": "working",
                  "waiting-approval": "waiting for approval", "stopped": "stopped",
                  "failed": "failed", "completed": "completed"}
        seen = {}

        def check(run_id, state):
            """The label, the row and run.list name the same state."""
            listed = self.run_of(run_id)
            self.assertEqual(listed["state"], state)
            label = f"Muse · {wanted[state]}"
            drawn = self.drawn(page["id"])
            self.assertEqual((drawn["muse"], drawn["runs"][-1]), (label, run_id))
            self.assertEqual((self.drawn(other["id"])["muse"], self.drawn(other["id"])["runs"]),
                             ("", []))
            self.open_launcher()
            state_ui = self.launcher()
            row = self.run_rows(state_ui)[0]
            seen[state] = {"label": drawn["muse"], "row": [row["title"], row["subtitle"], row["status"]]}
            if state == "pending":
                self.assertEqual(row["title"], "Connecting to Muse")
                self.assertEqual(row["subtitle"], "Your request is saved")
            elif state == "completed":
                self.assertEqual((row["title"], row["subtitle"], row["status"]),
                                 (f"{listed['prompt']} ready", "Open the result", "success"))
            else:
                self.assertEqual(row["subtitle"][:len(label)], label)
            if state in ("pending", "running", "waiting-approval"):
                self.assertEqual(state_ui["rows"][0]["title"], f"Stop {listed['prompt']}")
                self.assertEqual(row["status"], "loading")
            else:
                self.assertNotIn("Stop", state_ui["rows"][0]["title"])
                self.assertEqual(row["status"], "success" if state == "completed" else "ready")
            self.close_launcher()

        run = self.start("Read this page", tab=page["id"])
        check(run["runId"], "pending")
        for state in ("running", "waiting-approval"):
            self.state(run["runId"], state)
            check(run["runId"], state)
            if state == "waiting-approval":
                self.screenshot("task-waiting-approval")
        self.assertEqual(self.focused_label(), "Muse · waiting for approval")
        self.assertEqual(self.document(page["id"]), document)
        self.show("overview")
        self.assertEqual(self.document(page["id"]), document)
        self.call("run.stop", {"runId": run["runId"]})
        check(run["runId"], "stopped")
        second = self.start("Compare", tab=page["id"])
        self.state(second["runId"], "failed", "no model API key")
        check(second["runId"], "failed")
        third = self.start("Summarize", tab=page["id"])
        self.state(third["runId"], "completed")
        check(third["runId"], "completed")
        self.screenshot("task-completed")
        self.assertEqual(self.focused_label(), "Muse · completed")
        save("task-states.json", seen)
        # A run that has not completed never shows the completed row.
        for state in ("pending", "running", "waiting-approval", "stopped", "failed"):
            self.assertNotIn(" ready", json.dumps(seen[state]["row"][:2]))

    def test_the_label_is_only_on_the_page_a_run_owns(self):
        """VAL-TASK-002"""
        page = self.open_page("launcher.html")
        other = self.open_page("article.html")
        self.assertEqual(self.drawn(other["id"])["muse"], "")
        run = self.start("Read", tab=page["id"])
        self.assertEqual(self.drawn(other["id"])["muse"], "")
        self.call("test.activateTab", {"tabId": other["id"]})
        self.assertEqual(self.focused_label(), "")
        self.assertEqual(self.run_of(run["runId"])["tabId"], page["id"])


class StopTests(TaskCase):
    def test_an_active_run_leads_every_result_set_with_stop(self):
        """VAL-TASK-004"""
        self.open_page("launcher.html")
        self.open_launcher()
        self.type_text("stop")
        stop = next(r for r in self.launcher()["rows"] if r["target"] == "stopRun")
        self.assertEqual((stop["enabled"], stop["subtitle"]), (False, "No task is running"))
        self.close_launcher()
        frames = (self.ui()["windowFrame"], self.ui()["contentFrame"])
        run = self.start("Read this page", tab=self.active_id())
        sets = {}
        for query in ("", "kyoto", "reload", url("index.html")):
            self.open_launcher()
            state = self.retype(query)
            first = state["rows"][0]
            sets[query] = [first["title"], first["kind"]]
            self.assertEqual((first["kind"], first["target"], first["title"], first["enabled"]),
                             ("command", "stopRun", f"Stop {run['prompt']}", True), query)
            self.assertEqual([r["id"] for r in state["rows"]].count(first["id"]), 1)
            self.close_launcher()
        save("task-stop-first.json", sets)
        self.state(run["runId"], "completed")
        self.assertEqual((self.ui()["windowFrame"], self.ui()["contentFrame"]), frames)
        chrome = self.ui()["chrome"]
        self.assertNotIn("run", json.dumps(chrome).lower().replace("runs", ""))

    def test_stop_from_the_row_the_activity_view_and_the_socket_stop_within_two_seconds(self):
        """VAL-TASK-005"""
        page = self.open_page("launcher.html")
        seen = {}
        row_run = self.start("From the row", tab=page["id"])
        self.open_launcher()
        self.assertEqual(self.active(), self.launcher()["rows"][0]["id"])
        started = time.monotonic()
        self.key("Return")
        seen["row"] = self.wait_stopped(row_run["runId"], started)
        self.wait_launcher(False)
        view_run = self.start("From the view", tab=page["id"])
        self.open_activity()
        started = time.monotonic()
        self.call("test.click", {"target": "runActivityStop"})
        seen["view"] = self.wait_stopped(view_run["runId"], started)
        self.assertFalse(self.activity()["stop"]["enabled"])
        socket_run = self.start("From the socket", tab=page["id"])
        started = time.monotonic()
        self.call("run.stop", {"runId": socket_run["runId"]})
        seen["socket"] = self.wait_stopped(socket_run["runId"], started)
        for run in seen.values():
            self.assertEqual((run["state"], run["reason"]), ("stopped", "stopped"))
        self.assertIsNone(next(t for t in self.ui()["tabs"] if t["id"] == page["id"]).get("controllerSession"))
        save("task-stop.json", seen)

    def test_the_muse_menu_shows_the_activity_and_stops_the_task_only_while_one_runs(self):
        """VAL-TASK-004, VAL-TASK-005 (the menu route)"""
        page = self.open_page("launcher.html")
        run = self.start("From the menu", tab=page["id"])
        items = self.menu_items()
        for title in ("Show Muse Activity", "Stop Task"):
            self.assertEqual((items[title]["enabled"], items[title]["toolTip"], items[title]["shortcut"]),
                             (True, "", ""), title)
        self.call("test.menu", {"invoke": "Show Muse Activity"})
        bs.wait_until(lambda: self.activity().get("open"), what="the activity view")
        self.close_activity()
        started = time.monotonic()
        self.call("test.menu", {"invoke": "Stop Task"})
        self.wait_stopped(run["runId"], started)
        items = self.menu_items()
        self.assertEqual((items["Stop Task"]["enabled"], items["Stop Task"]["toolTip"]),
                         (False, "No task is running"))
        self.assertTrue(items["Show Muse Activity"]["enabled"])

    def test_dismissing_the_launcher_never_stops_a_run(self):
        """VAL-TASK-005"""
        page = self.open_page("launcher.html")
        self.open_launcher()
        self.type_text(KYOTO)
        self.key("Return")
        self.wait_launcher(False)
        run, = self.new_runs()
        self.open_launcher()
        self.key("Escape")
        self.wait_launcher(False)
        self.assertEqual(self.run_of(run["runId"])["state"], "pending")
        self.open_launcher()
        self.call("test.click", {"target": "root", "x": 20, "y": 300})
        self.wait_launcher(False)
        self.assertEqual(self.run_of(run["runId"])["state"], "pending")
        self.state(run["runId"], "running")
        self.call("test.runStep", {"runId": run["runId"], "text": "Click Next", "tabId": page["id"],
                                   "state": "confirmed"})
        later = self.run_of(run["runId"])
        self.assertEqual((later["state"], len(later["steps"])), ("running", 1))

    def test_a_takeover_shows_stopped_on_the_node_and_the_row(self):
        """VAL-TASK-006"""
        page = self.open_page("launcher.html")
        run = self.start("Read this page", tab=page["id"])
        self.show("focused")
        self.call("test.click", {"tabId": page["id"]})
        taken = self.run_of(run["runId"])
        self.assertEqual((taken["state"], taken["reason"]), ("stopped", "taken-over"))
        self.assertEqual(self.focused_label(), "Muse · stopped")
        self.assertEqual(self.drawn(page["id"])["muse"], "Muse · stopped")
        self.open_launcher()
        row, = self.run_rows()
        self.assertEqual(row["subtitle"], "Muse · stopped · taken-over")
        self.assertNotIn("Stop", self.launcher()["rows"][0]["title"])
        self.close_launcher()
        # Typing in the launcher is not page input and stops nothing.
        other = self.start("Again", tab=page["id"])
        self.open_launcher()
        self.type_text("abc")
        self.close_launcher()
        self.assertEqual(self.run_of(other["runId"])["state"], "pending")


class ActivityTests(TaskCase):
    def test_the_activity_view_lists_each_step_with_its_state_and_reason(self):
        """VAL-TASK-004, VAL-ACT-005"""
        page = self.open_page("launcher.html")
        run = self.start("Click the Next button", tab=page["id"])
        self.open_launcher()
        row = self.run_rows()[0]
        self.assertTrue(row["enabled"])
        self.key("Escape")
        self.state(run["runId"], "running")
        view = self.open_activity()
        self.assertEqual((view["runId"], view["prompt"], view["status"]),
                         (run["runId"], "Click the Next button", "working"))
        self.assertEqual(view["entries"], [])
        self.call("test.runStep", {"runId": run["runId"], "text": 'Click "Next"',
                                   "tabId": page["id"], "state": "confirmed"})
        self.call("test.runStep", {"runId": run["runId"], "text": 'Click "Buy"',
                                   "tabId": page["id"], "state": "failed", "reason": "needs-human"})
        self.state(run["runId"], "failed", "a write ended failed: needs-human")
        view = bs.wait_until(lambda: (lambda a: a if a["status"] == "failed" else None)(self.activity()),
                             what="the failed state in the view")
        listed = self.run_of(run["runId"])
        self.assertEqual([(e["text"], e["detail"]) for e in view["entries"]],
                         [(s["text"], f"Launcher fixture · {s['state']}" + (f" · {s['reason']}" if s["reason"] else ""))
                          for s in listed["steps"]])
        self.assertEqual(view["entries"][1]["detail"].split(" · ")[1:], ["failed", "needs-human"])
        self.assertEqual(view["reason"], "a write ended failed: needs-human")
        self.assertFalse(view["stop"]["enabled"])
        tree = self.tree()
        group = next(n for n in tree if n.get("label") == "Muse activity" and n["role"] == "AXGroup")
        self.assertTrue(group["enabled"])
        for entry in view["entries"]:
            next(n for n in tree if n.get("label") == f"{entry['text']}, {entry['detail']}")
        self.assertTrue(next(n for n in tree if n.get("label") == "Close Muse activity")["actions"] == ["AXPress"])
        self.screenshot("task-activity-failed")
        save("task-activity.json", {"view": view, "run": listed})
        self.key("Escape")
        bs.wait_until(lambda: not self.activity()["open"], what="the view closed")
        self.assertEqual(self.run_of(run["runId"])["state"], "failed")

    def test_the_activity_view_is_reachable_and_operable_by_keyboard(self):
        """VAL-TASK-004, VAL-TASK-005"""
        page = self.open_page("launcher.html")
        run = self.start("Read this page", tab=page["id"])
        self.state(run["runId"], "running")
        self.open_launcher()
        self.assertEqual(self.run_rows()[0]["title"], "Read this page")
        self.move_to(self.run_rows()[0])
        self.key("Return")
        view = bs.wait_until(lambda: self.activity() if self.activity().get("open") else None,
                             what="the activity view")
        self.assertFalse(self.launcher()["open"])
        self.assertEqual(view["runId"], run["runId"])
        self.assertEqual(self.ui()["firstResponder"]["chromeId"], "runActivityStop")
        names = {n["label"]: n for n in self.tree() if n.get("role") == "AXButton"}
        self.assertIn("Stop Read this page", names)
        self.assertEqual(names["Stop Read this page"]["actions"], ["AXPress"])
        self.key("Tab")
        self.assertEqual(self.ui()["firstResponder"]["chromeId"], "runActivityClose")
        self.key("Tab")
        self.assertEqual(self.ui()["firstResponder"]["chromeId"], "runActivityStop")
        started = time.monotonic()
        self.key("Space")
        self.wait_stopped(run["runId"], started)
        self.assertEqual(self.ui()["firstResponder"]["chromeId"], "runActivityClose")
        self.assertEqual(self.activity()["status"], "stopped")
        self.key("Return")
        bs.wait_until(lambda: not self.activity()["open"], what="the view closed")

    def test_a_row_opens_its_own_run_and_a_page_shortcut_leaves_the_view_in_charge(self):
        """VAL-TASK-002, VAL-TASK-004"""
        page = self.open_page("launcher.html")
        older = self.start("Older task", tab=page["id"])
        self.state(older["runId"], "failed", "no model API key")
        newer = self.start("Newer task", tab=page["id"])
        self.state(newer["runId"], "running")
        self.open_launcher()
        row = next(r for r in self.run_rows() if r["title"] == "Older task")
        self.move_to(row)
        self.key("Return")
        view = bs.wait_until(lambda: self.activity() if self.activity().get("open") else None,
                             what="the activity view")
        self.assertEqual((view["runId"], view["prompt"]), (older["runId"], "Older task"))
        self.key("2", "cmd")
        self.assertTrue(self.activity()["open"])
        self.assertEqual(self.ui()["firstResponder"]["chromeId"], "runActivityClose")
        self.assertEqual(self.run_of(newer["runId"])["state"], "running")

    def test_clicking_outside_closes_the_view_without_stopping_the_run(self):
        """VAL-TASK-005"""
        page = self.open_page("launcher.html")
        run = self.start("Read this page", tab=page["id"])
        self.open_activity()
        self.call("test.click", {"target": "root", "x": 20, "y": 500})
        bs.wait_until(lambda: not self.activity()["open"], what="the view closed")
        self.assertEqual(self.run_of(run["runId"])["state"], "pending")


class FirstUseTests(TaskCase):
    """Needs an app that has never had a run, so it is the only test of its class."""

    def test_before_any_run_the_activity_view_explains_why_it_cannot_open(self):
        """VAL-TASK-004"""
        self.open_page("launcher.html")
        self.open_launcher()
        self.type_text("Show Muse activity")
        row = next(r for r in self.launcher()["rows"] if r["target"] == "showRunActivity")
        self.assertEqual((row["enabled"], row["subtitle"]), (False, "No task has run yet"))
        self.call("test.click", {"target": f"launcherRow:{row['id']}"})
        self.assertFalse(self.activity()["open"])
        self.assertEqual(self.run_rows(), [])
        items = self.menu_items()
        for title, reason in (("Show Muse Activity", "No task has run yet"),
                              ("Stop Task", "No task is running")):
            self.assertEqual((items[title]["enabled"], items[title]["toolTip"]), (False, reason))


class ApprovalActivityTests(RunBase):
    """The pending approvals of a run are listed in its activity view."""

    def launcher_pick(self, title):
        self.app.call("test.key", {"key": "t", "modifiers": ["cmd"]})
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the launcher")
        self.app.call("test.type", {"text": title})
        state = bs.wait_until(lambda: (lambda s: s if s["current"] and s["query"] == title else None)(
            self.ui()["launcher"]), what="rows")
        row = next(r for r in state["rows"] if r["title"] == title)
        self.app.call("test.click", {"target": f"launcherRow:{row['id']}"})

    def test_a_waiting_action_is_listed_with_the_run_that_asked(self):
        """VAL-TASK-004"""
        run = self.start("Delete the draft")
        self.quote_for(run)
        self.wait_card()
        self.app.call("test.runState", {"runId": run["runId"], "state": "waiting-approval"})
        self.launcher_pick("Show Muse activity")
        view = bs.wait_until(lambda: (lambda a: a if a.get("open") else None)(self.ui()["activity"]),
                             what="the view")
        self.assertEqual(view["status"], "waiting for approval")
        self.assertEqual(view["waiting"], [a["text"] for a in self.pending()])
        self.assertEqual(view["waiting"], ['Click "Delete draft"'])
        tree = list(flatten(self.app.call("test.ax")))
        self.assertTrue(any(n.get("label") == 'Waiting for you: Click "Delete draft"' for n in tree))
        self.app.call("run.stop", {"runId": run["runId"]})
        bs.wait_until(lambda: self.ui()["activity"]["waiting"] == [], what="the approval to leave")
        self.app.call("test.key", {"key": "Escape"})


class OutageTests(TaskCase):
    def available(self):
        return [r for r in self.launcher()["rows"] if r["kind"] == "startTask"][0]["enabled"]

    def test_the_recovery_state_keeps_the_prompt_and_clears_only_on_retry(self):
        """VAL-TASK-007, VAL-TASK-009, VAL-CROSS-006"""
        self.open_page("launcher.html")
        self.call("test.announcements", {"reset": True})
        self.call("test.modelOffline", {"on": True})
        self.open_launcher()
        self.type_text(KYOTO)
        state = self.launcher()
        task = next(r for r in state["rows"] if r["kind"] == "startTask")
        retry = next(r for r in state["rows"] if r["kind"] == "retry")
        search = next(r for r in state["rows"] if r["kind"] == "search")
        self.assertEqual((task["enabled"], task["subtitle"]),
                         (False, "Muse is unavailable. Web search still works."))
        self.assertEqual((state["active"], search["hint"], state["fieldText"]),
                         (search["id"], True, KYOTO))
        tree = self.tree()
        node = next(n for n in tree if n.get("label", "").startswith("Start task") and n["role"] == "AXButton")
        self.assertEqual((node["enabled"], node["description"]),
                         (False, "Muse is unavailable. Web search still works."))
        self.assertTrue(next(n for n in tree if n.get("label", "").startswith("Retry"))["enabled"])
        # Enter on the dimmed row does nothing; so does a click on it.
        self.call("test.click", {"target": f"launcherRow:{task['id']}"})
        self.assertTrue(self.launcher()["open"])
        self.assertEqual(self.new_runs(), [])
        # Tab reaches Retry; Space on it while offline changes nothing.
        for _ in range(len(state["rows"]) + 1):
            if self.responder() == f"launcherRow:{retry['id']}":
                break
            self.key("Tab")
        self.assertEqual(self.responder(), f"launcherRow:{retry['id']}")
        self.key("Space")
        self.assertTrue(self.launcher()["error"])
        self.assertEqual((self.launcher()["fieldText"], self.new_runs()), (KYOTO, []))
        # Escape and reopening keep the typed request.
        self.key("Escape")
        self.wait_launcher(False)
        self.open_launcher()
        self.assertEqual(self.launcher()["query"], KYOTO)
        self.assertTrue(self.launcher()["error"])
        # Muse coming back does not clear the state; Retry does.
        self.call("test.modelOffline", {"on": False})
        self.assertTrue(self.launcher()["error"])
        retry = next(r for r in self.launcher()["rows"] if r["kind"] == "retry")
        self.call("test.click", {"target": f"launcherRow:{retry['id']}"})
        state = bs.wait_until(lambda: (lambda s: s if not s["error"] else None)(self.launcher()),
                              what="the retry row to go")
        self.assertEqual((state["query"], self.available(), self.new_runs()), (KYOTO, True, []))
        task = next(r for r in state["rows"] if r["kind"] == "startTask")
        self.key("ArrowUp")
        self.assertEqual(self.active(), task["id"])
        self.key("Return")
        self.wait_launcher(False)
        run, = self.new_runs()
        self.assertEqual((run["prompt"], run["origin"]), (KYOTO, "mac"))
        self.assertEqual([a for a in self.call("test.announcements")["announcements"]
                          if a == "Unable to connect to Muse"], ["Unable to connect to Muse"])

    def test_a_new_outage_is_announced_again(self):
        """VAL-TASK-007"""
        self.call("test.announcements", {"reset": True})
        for _ in range(2):
            self.call("test.modelOffline", {"on": True})
            self.open_launcher()
            self.type_text(KYOTO)
            retry = next(r for r in self.launcher()["rows"] if r["kind"] == "retry")
            self.call("test.modelOffline", {"on": False})
            self.call("test.click", {"target": f"launcherRow:{retry['id']}"})
            bs.wait_until(lambda: not self.launcher()["error"], what="the state to clear")
            self.close_launcher()
            self.clear_field_text()
        self.assertEqual(self.call("test.announcements")["announcements"].count(
            "Unable to connect to Muse"), 2)

    def test_search_stays_the_way_on_while_muse_is_down(self):
        """VAL-CROSS-006"""
        self.call("test.modelOffline", {"on": True})
        self.open_launcher()
        self.type_text(KYOTO)
        tabs = self.tab_ids()
        self.key("Return")
        new = bs.wait_until(lambda: [t for t in self.tabs() if t["id"] not in tabs] or None,
                            what="the search tab")
        self.assertEqual(parse_qs(urlsplit(new[0]["url"]).query)["q"], [KYOTO])
        self.assertEqual(self.new_runs(), [])

    def test_with_no_key_every_local_capability_works_and_settings_says_unavailable(self):
        """VAL-CROSS-006"""
        spend = self.spend_path()
        before = os.path.getmtime(spend) if os.path.exists(spend) else None
        entries = self.spend_entries()
        self.call("test.modelOffline", {"on": True})
        first = self.open_page("launcher.html")
        second = self.open_page("article.html")
        self.assertEqual(self.active_id(), second["id"])
        self.open_launcher()
        self.type_text("Launcher")
        tab = next(r for r in self.launcher()["rows"] if r["kind"] == "switchTab")
        self.call("test.click", {"target": f"launcherRow:{tab['id']}"})
        bs.wait_until(lambda: self.active_id() == first["id"], what="the switch to the open page")
        self.open_launcher()
        self.type_text(url("index.html"))
        self.key("Return")
        loaded = bs.wait_until(lambda: [t for t in self.tabs() if t["url"] == url("index.html")] or None,
                               what="Open website")
        self.key("[", "cmd")
        self.key("r", "cmd")
        self.show("overview")
        self.show("focused")
        self.call("test.closeTab", {"tabId": loaded[0]["id"]})
        self.key(",", "cmd")
        settings = bs.wait_until(lambda: (lambda s: s if s["open"] else None)(self.ui()["settings"]),
                                 what="Settings")
        self.assertEqual(settings["model"], "Unavailable")
        self.key("w", "cmd")
        windows = self.ui()["visibleWindows"]
        self.assertFalse([w for w in windows if "Alert" in w or "Sheet" in w], windows)
        self.assertEqual(self.new_runs(), [])
        self.assertEqual(self.spend_entries(), entries)
        if before is not None:
            self.assertEqual(os.path.getmtime(spend), before)

    def spend_path(self):
        return os.environ.get("BARESTATE_SPEND_LOG") or os.path.join(self.data_dir, "spend.json")

    def spend_entries(self):
        path = self.spend_path()
        if not os.path.exists(path):
            return []
        with open(path) as spend:
            return json.load(spend)["entries"]


class FidelityTests(TaskCase):
    def red(self, image, frame, scale):
        return sum(1 for x in range(int(frame["x"] * scale), int((frame["x"] + frame["w"]) * scale), 2)
                   for y in range(int(frame["y"] * scale), int((frame["y"] + frame["h"]) * scale), 2)
                   if (lambda p: p[0] > 190 and p[1] < 90 and p[2] < 90)(image.pixel(x, y)))

    def count(self, image, frame, wanted, scale, tolerance=14):
        return sum(1 for x in range(int(frame["x"] * scale), int((frame["x"] + frame["w"]) * scale))
                   for y in range(int(frame["y"] * scale), int((frame["y"] + frame["h"]) * scale))
                   if png.close(image.pixel(x, y), wanted, tolerance))

    def test_unavailable_connecting_and_ready_carry_the_listed_elements(self):
        """VAL-TASK-008"""
        page = self.open_page("launcher.html")
        self.call("test.modelOffline", {"on": True})
        self.open_launcher()
        self.type_text(KYOTO)
        state = self.launcher()
        image = self.screenshot("task-unavailable")
        scale = image.width / self.ui()["windowFrame"]["w"]
        rows = {r["kind"]: r for r in state["rows"]}
        self.assertEqual(state["fieldText"], KYOTO)
        self.assertEqual((rows["startTask"]["state"], rows["startTask"]["subtitle"]),
                         ("disabled", "Muse is unavailable. Web search still works."))
        self.assertEqual((state["active"], rows["search"]["hint"]), (rows["search"]["id"], True))
        self.assertGreater(self.count(image, rows["retry"]["frame"], PETROL, scale), 20)
        self.assertGreater(self.count(image, rows["search"]["frame"], SELECTION, scale, 6), 500)
        self.assertEqual(self.red(image, state["frame"], scale), 0)
        self.assertEqual(sum(r["hint"] for r in state["rows"]), 1)
        self.close_launcher()
        self.call("test.modelOffline", {"on": False})
        self.clear_field_text()
        run = self.start("Plan the trip", tab=page["id"])
        self.open_launcher()
        row = self.run_rows()[0]
        self.assertEqual((row["title"], row["subtitle"], row["status"]),
                         ("Connecting to Muse", "Your request is saved", "loading"))
        self.screenshot("task-connecting")
        self.close_launcher()
        self.state(run["runId"], "completed")
        self.open_launcher()
        row = self.run_rows()[0]
        self.assertEqual((row["title"], row["subtitle"], row["status"], row["actionLabel"]),
                         ("Plan the trip ready", "Open the result", "success", "Open the result"))
        self.screenshot("task-ready")
        self.move_to(row)
        self.key("Return")
        view = bs.wait_until(lambda: self.activity() if self.activity().get("open") else None,
                             what="the activity view of the ready run")
        self.assertEqual(view["runId"], run["runId"])
        self.screenshot("task-activity-ready")


@unittest.skipUnless(LIVE, "live Meta call: not run (no BARESTATE_LIVE_META/BARESTATE_SPEND_LOG)")
class LiveTaskTests(TaskCase):
    def test_a_real_run_recovers_from_an_outage_and_ends_with_a_ready_row(self):
        """VAL-TASK-009 (live), VAL-TASK-002 (completed), VAL-TASK-008 (ready)"""
        with open(os.environ["BARESTATE_SPEND_LOG"]) as spend:
            seen = len(json.load(spend)["entries"])
        page = self.open_page("launcher.html")
        self.call("test.holdModel", {"on": False})
        self.call("test.modelOffline", {"on": True})
        self.open_launcher()
        self.type_text(TRIVIAL)
        retry = next(r for r in self.launcher()["rows"] if r["kind"] == "retry")
        self.call("test.click", {"target": f"launcherRow:{retry['id']}"})
        self.assertTrue(self.launcher()["error"])
        self.assertEqual(self.new_runs(), [])
        self.call("test.modelOffline", {"on": False})
        retry = next(r for r in self.launcher()["rows"] if r["kind"] == "retry")
        self.call("test.click", {"target": f"launcherRow:{retry['id']}"})
        state = bs.wait_until(lambda: (lambda s: s if not s["error"] else None)(self.launcher()),
                              what="the retry probe to clear the state")
        self.key("ArrowUp")
        self.assertEqual(self.active(), next(r for r in state["rows"] if r["kind"] == "startTask")["id"])
        self.key("Return")
        run = bs.wait_until(lambda: (lambda r: r[0] if r else None)(self.new_runs()), what="the run")
        self.assertEqual((run["prompt"], run["tabId"]), (TRIVIAL, page["id"]))
        done = bs.wait_until(lambda: (lambda r: r if r["state"] in ENDED else None)(
            self.run_of(run["runId"])), timeout=180, what="the run to end")
        self.assertEqual(done["state"], "completed", done)
        self.assertEqual(len(self.new_runs()), 1)
        self.assertEqual(self.drawn(page["id"])["muse"], "Muse · completed")
        self.show("focused")
        self.open_launcher()
        row = self.run_rows()[0]
        self.assertEqual((row["title"], row["subtitle"]), (f"{TRIVIAL} ready", "Open the result"))
        self.screenshot("task-live-ready")
        self.move_to(row)
        self.key("Return")
        bs.wait_until(lambda: self.activity().get("open"), what="the activity view")
        with open(os.environ["BARESTATE_SPEND_LOG"]) as spend:
            ledger = json.load(spend)
        added = ledger["entries"][seen:]
        cost = sum(e["usd"] for e in added) if added and "usd" in added[0] else None
        save("task-live.json", {"run": done, "requests": len(added), "usd": cost})
        print(f"\ntask-live: {len(added)} model requests, usd {cost}", flush=True)
        self.assertLess(done["costUSD"], 3)


if __name__ == "__main__":
    unittest.main()
