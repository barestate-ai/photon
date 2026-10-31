"""Control epochs, the journal and acting by ref on a real tab."""
import contextlib
import itertools
import os
import sqlite3
import subprocess
import unittest

import bs
from test_core import CoreApp, save


EDIT_KEYS = [("x", ["cmd"]), ("c", ["cmd"]), ("v", ["cmd"]), ("a", ["cmd"]), ("z", ["cmd"]),
             ("z", ["cmd", "shift"])]


@contextlib.contextmanager
def empty_clipboard():
    saved = subprocess.run(["pbpaste"], capture_output=True).stdout
    subprocess.run(["pbcopy"], input=b"")
    try:
        yield
    finally:
        subprocess.run(["pbcopy"], input=saved)


class ActBase(CoreApp):
    """A tab on one fixture page, with the helpers to take control, observe and act on it."""

    start_page = "act.html"
    loads = itertools.count(1)

    def setUp(self):
        # A new document per test, so refs, keys and the log start clean.
        self.app.call("test.releaseDispatch")
        # The page read-back alone decides here; the model's reading is tested in test_perm.
        self.app.call("test.verifier", {"mode": "agree"})
        for item in self.app.call("approval.list")["approvals"]:
            if item["kind"] == "action":
                self.app.call("approval.decide", {"approvalId": item["approvalId"], "allow": False})
        if self.holder():
            self.app.call("handoff", {"sessionId": self.holder(), "tabId": self.tab})
        before = len(self.fixtures.log())
        self.navigate(f"{self.start_page}?load={next(self.loads)}")
        self.wait_input_ready(before)
        self.mark = len(self.fixtures.log())

    @property
    def session(self):
        return f"s-{self._testMethodName[-24:]}"

    def holder(self):
        return self.ui_tab().get("controllerSession")

    def grant(self, session=None):
        session = session or self.session
        request = self.app.call("request_control", {"sessionId": session, "tabId": self.tab})
        if request["state"] != "granted":
            self.assertEqual(request["state"], "pending")
            decided = self.app.call("control.decide",
                                    {"requestId": request["requestId"], "allow": True})
            self.assertEqual(decided["state"], "granted")

    def observe(self):
        return self.app.call("observe", {"tabId": self.tab})

    @staticmethod
    def ref(observation, name):
        return next(e["ref"] for e in observation["elements"] if e["name"] == name)

    def act(self, client_id, observation, kind, name, text=None, session=None):
        params = {"sessionId": session or self.session, "clientActionId": client_id,
                  "observationId": observation["id"], "kind": kind,
                  "ref": self.ref(observation, name)}
        if text is not None:
            params["text"] = text
        return self.app.call("act", params)

    def settled(self, row, session=None, timeout=20):
        final = {"confirmed", "failed", "cancelled", "outcome-unknown"}
        return bs.wait_until(
            lambda: (lambda r: r if r["state"] in final else None)(self.app.call(
                "action_status", {"sessionId": session or self.session,
                                  "clientActionId": row["clientActionId"]})),
            timeout=timeout, what=f"action {row['clientActionId']} to finish")

    def clicks(self):
        return [b["click"][0] for b in self.beacons(self.mark) if "click" in b]

    def inputs(self):
        return [(b["input"][0], b["v"][0]) for b in self.beacons(self.mark) if "input" in b]

    def fence(self):
        """Returns once a beacon sent now is logged, so earlier ones from this page are too."""
        token = str(next(self.loads))
        self.devtools("Runtime.evaluate",
                      {"expression": f"new Image().src = '/__beacon?fence={token}'"})
        bs.wait_until(lambda: any(b.get("fence") == [token] for b in self.beacons(self.mark)),
                      what="the fence beacon")

    def settled_clicks(self, at_least=0):
        bs.wait_until(lambda: len(self.clicks()) >= at_least, what=f"{at_least} click beacons")
        self.fence()
        return self.clicks()

    def settled_inputs(self, at_least=0):
        bs.wait_until(lambda: len(self.inputs()) >= at_least, what=f"{at_least} input beacons")
        self.fence()
        return self.inputs()

    def field_value(self):
        reply = self.devtools("Runtime.evaluate", {
            "expression": "document.getElementById('field').value", "returnByValue": True})
        return reply["result"]["value"]

    def db_path(self):
        return os.path.join(self.app.data_dir, "barestate.sqlite")

    def db(self, sql, args=()):
        with contextlib.closing(sqlite3.connect(f"file:{self.db_path()}?mode=ro", uri=True)) as db:
            return db.execute(sql, args).fetchall()


class ActTests(ActBase):

    # VAL-CORE-012
    def test_click_and_type_by_ref_land_once_on_the_right_element(self):
        self.grant()
        observation = self.observe()
        clicked = self.act("c1", observation, "click", "Count")
        self.assertEqual(self.settled(clicked)["state"], "confirmed")
        typed = self.act("t1", observation, "type", "Name", text="hello kyoto")
        self.assertEqual(self.settled(typed)["state"], "confirmed")
        self.assertEqual(self.settled_clicks(1), ["count"])
        self.assertEqual(self.settled_inputs(1), [("field", "hello kyoto")])
        self.assertEqual(self.field_value(), "hello kyoto")
        self.assertEqual(self.db("select count(*) from actions where state = 'pending'"), [(0,)])
        save("act-click-type.json", {"click": clicked, "type": typed,
                                     "rows": self.db("select id, kind, target, state from actions")})

    # VAL-CORE-007
    def test_act_is_idempotent_by_session_and_client_action_id(self):
        self.grant()
        observation = self.observe()
        rows = [self.act("same", observation, "click", "Count") for _ in range(3)]
        self.settled(rows[0])
        self.assertEqual(len({r["id"] for r in rows}), 1)
        self.assertEqual(self.settled_clicks(1), ["count"])
        key = (self.session, "same")
        self.assertEqual(
            self.db("select count(*) from actions where session_id = ? and client_action_id = ?",
                    key), [(1,)])
        again = self.app.call("action_status", {"sessionId": self.session, "clientActionId": "same"})
        self.assertEqual(again["state"], "confirmed")
        with contextlib.closing(sqlite3.connect(self.db_path())) as db:
            with self.assertRaises(sqlite3.IntegrityError) as raised:
                db.execute("insert into actions(session_id, client_action_id, state) "
                           "values (?, 'same', 'pending')", (self.session,))
        self.assertIn("UNIQUE", str(raised.exception))
        other = self.act("different", observation, "click", "Count")
        self.assertNotEqual(other["id"], rows[0]["id"])
        self.settled(other)
        self.assertEqual(self.settled_clicks(2), ["count", "count"])

    # VAL-CORE-006 and the held half of VAL-CORE-007
    def test_the_row_is_pending_before_dispatch_and_repeats_do_not_dispatch(self):
        self.grant()
        observation = self.observe()
        self.app.call("test.holdDispatch", {"on": True})
        try:
            first = self.act("held", observation, "click", "Count")
            repeat = self.act("held", observation, "click", "Count")
            self.assertEqual((first["state"], repeat["state"]), ("pending", "pending"))
            self.assertEqual(first["id"], repeat["id"])
            rows = self.db("select session_id, client_action_id, tab_id, epoch, observation_id, "
                           "kind, target, state from actions where client_action_id = 'held'")
            self.assertEqual(rows, [(self.session, "held", self.tab, observation["epoch"],
                                     observation["id"], "click",
                                     str(self.ref(observation, "Count")), "pending")])
            self.assertEqual(self.settled_clicks(), [])
        finally:
            self.app.call("test.releaseDispatch")
        self.assertEqual(self.settled(first)["state"], "confirmed")
        self.assertEqual(self.settled_clicks(1), ["count"])

    def test_the_journal_accepts_only_the_six_states(self):
        self.grant()
        self.settled(self.act("one", self.observe(), "click", "Other"))
        with contextlib.closing(sqlite3.connect(self.db_path())) as db:
            with self.assertRaises(sqlite3.IntegrityError) as raised:
                db.execute("update actions set state = 'done'")
        self.assertIn("CHECK", str(raised.exception))
        states = {s for (s,) in self.db("select distinct state from actions")}
        self.assertLessEqual(states, {"quoted", "pending", "confirmed", "failed", "cancelled",
                                      "outcome-unknown"})

    # VAL-CORE-009
    def test_a_stale_action_is_rejected_and_nothing_reaches_the_page(self):
        self.grant()
        old = self.observe()
        self.app.call("test.click", {"tabId": self.tab})
        self.assertEqual(self.ui_tab()["controller"], "human")
        self.grant()
        epoch = self.settled(self.act("epoch", old, "click", "Count"))
        self.assertEqual((epoch["state"], epoch["reason"]), ("cancelled", "stale: epoch"))

        fresh = self.observe()
        self.navigate(f"act.html?other={next(self.loads)}")
        document = self.settled(self.act("document", fresh, "click", "Count"))
        self.assertEqual((document["state"], document["reason"]), ("cancelled", "stale: documentKey"))

        fresh = self.observe()
        self.devtools("Runtime.evaluate", {"expression": "scrollTo(0, 120)"})
        viewport = self.settled(self.act("viewport", fresh, "click", "Count"))
        self.assertEqual((viewport["state"], viewport["reason"]), ("cancelled", "stale: viewportKey"))
        self.assertNotIn("count", self.settled_clicks())
        save("stale-rows.json", [epoch, document, viewport])

    # VAL-CORE-010 and the agent-to-human takeover on a real tab
    def test_a_human_click_while_a_click_is_held_fences_it(self):
        self.grant()
        observation = self.observe()
        self.app.call("test.holdDispatch", {"on": True})
        try:
            row = self.act("fenced", observation, "click", "Count")
            self.assertEqual(row["state"], "pending")
            self.app.call("test.click", {"tabId": self.tab})
            bs.wait_until(lambda: self.clicks(), what="the human click beacon")
        finally:
            self.app.call("test.releaseDispatch")
        final = self.settled(row)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "stale: epoch"))
        self.assertEqual(self.settled_clicks(1), ["pad"])
        self.assertEqual(self.ui_tab()["controller"], "human")

    def test_a_human_click_while_typing_is_held_leaves_the_input_unchanged(self):
        self.grant()
        observation = self.observe()
        self.app.call("test.holdDispatch", {"on": True})
        try:
            row = self.act("fenced-type", observation, "type", "Name", text="agent text")
            self.app.call("test.click", {"tabId": self.tab})
            bs.wait_until(lambda: self.clicks(), what="the human click beacon")
        finally:
            self.app.call("test.releaseDispatch")
        self.assertEqual(self.settled(row)["state"], "cancelled")
        self.assertEqual(self.field_value(), "")
        self.assertEqual(self.settled_inputs(), [])

    def focus_field_with(self, text, selected=None):
        """The page's input holds `text` with `selected` characters selected from the start (all
        of it by default) and has the window's key focus."""
        self.app.call("test.click", {"tabId": self.tab})
        end = len(text) if selected is None else selected
        self.devtools("Runtime.evaluate", {
            "expression": f"field.value = '{text}'; field.focus(); field.setSelectionRange(0, {end})"})

    def press(self, key, modifiers):
        self.app.call("test.key", {"key": key, "modifiers": modifiers})

    def held_type_then(self, human_edit):
        """A typing action is held before dispatch while `human_edit` runs; returns its final row."""
        self.grant()
        observation = self.observe()
        self.app.call("test.holdDispatch", {"on": True})
        try:
            row = self.act(f"held-{self._testMethodName}", observation, "type", "Name", text="agent text")
            self.assertEqual(row["state"], "pending", row)
            human_edit()
            bs.wait_until(lambda: self.field_value() == " beta", what="the cut to reach the field")
        finally:
            self.app.call("test.releaseDispatch")
        return self.settled(row)

    def assert_cut_once_and_fenced(self, final, epoch):
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "stale: epoch"))
        self.assertEqual(self.ui_tab()["epoch"], epoch + 1)
        self.assertEqual(self.ui_tab()["controller"], "human")
        self.assertEqual(self.settled_inputs(1), [("field", " beta")])
        self.assertEqual(self.field_value(), " beta")

    # BF-001: a native page edit is human input, whichever route it came by
    def test_a_cut_shortcut_while_a_type_is_held_fences_it_and_cuts_once(self):
        with empty_clipboard():
            self.focus_field_with("alpha beta", selected=5)
            epoch = self.ui_tab()["epoch"]
            final = self.held_type_then(lambda: self.press("x", ["cmd"]))
        self.assert_cut_once_and_fenced(final, epoch)

    def test_the_cut_menu_item_while_a_type_is_held_fences_it_and_cuts_once(self):
        with empty_clipboard():
            self.focus_field_with("alpha beta", selected=5)
            epoch = self.ui_tab()["epoch"]
            final = self.held_type_then(lambda: self.app.call("test.menu", {"invoke": "Cut"}))
        self.assert_cut_once_and_fenced(final, epoch)

    def test_every_page_edit_shortcut_takes_control_back(self):
        with empty_clipboard():
            self.focus_field_with("alpha")
            for key, modifiers in EDIT_KEYS:
                self.grant()
                epoch = self.ui_tab()["epoch"]
                self.press(key, modifiers)
                self.assertEqual((self.ui_tab()["epoch"], self.ui_tab()["controller"]),
                                 (epoch + 1, "human"), (key, modifiers))

    def test_edits_in_the_launcher_find_and_settings_leave_control_alone(self):
        with empty_clipboard():
            self.focus_field_with("")
            self.grant()
            observation = self.observe()
            epoch = self.ui_tab()["epoch"]
            self.app.call("test.holdDispatch", {"on": True})
            try:
                row = self.act("held-ui", observation, "type", "Name", text="agent text")
                for opener, closer in ((("t", ["cmd"]), ("Escape", [])),
                                       (("f", ["cmd"]), ("Escape", [])),
                                       ((",", ["cmd"]), ("w", ["cmd"]))):
                    self.press(*opener)
                    if opener[0] == ",":
                        bs.wait_until(lambda: (lambda s: s["open"] and s["key"])(
                            self.app.call("test.ui")["settings"]), what="Settings open and key")
                    else:
                        self.app.call("test.type", {"text": "alpha"})
                    for key, modifiers in EDIT_KEYS:
                        self.press(key, modifiers)
                    closes = self.app.call("test.ui")["settings"].get("closes", 0)
                    self.press(*closer)
                    if closer[0] == "w":
                        bs.wait_until(lambda: self.app.call("test.ui")["settings"]["closes"] == closes + 1,
                                      what="Settings closed")
                    self.assertEqual((self.ui_tab()["epoch"], self.ui_tab()["controller"]),
                                     (epoch, "agent"), opener)
            finally:
                self.app.call("test.releaseDispatch")
        self.assertEqual(self.settled(row)["state"], "confirmed")
        self.assertEqual(self.field_value(), "agent text")

    # VAL-CORE-011
    def test_writes_need_a_grant_reads_are_free_and_handoff_returns_control(self):
        observation = self.observe()
        refused = self.act("no-grant", observation, "click", "Count")
        self.assertEqual((refused["state"], refused["reason"]), ("failed", "not-in-control"))
        self.assertEqual(self.app.call("tabs")["tabs"][0]["id"], self.tab)
        self.assertIn("Act fixture", self.app.call("extract", {"tabId": self.tab})["content"])
        self.assertEqual(self.app.call("action_status", {"sessionId": self.session,
                                                         "clientActionId": "no-grant"})["state"],
                         "failed")

        denied = self.app.call("request_control", {"sessionId": self.session, "tabId": self.tab})
        self.assertEqual(denied["state"], "pending")
        answer = self.app.call("control.decide", {"requestId": denied["requestId"], "allow": False})
        self.assertEqual(answer["state"], "denied")
        self.assertEqual(self.ui_tab()["controller"], "human")
        self.assertEqual(self.act("after-deny", observation, "click", "Count")["reason"],
                         "not-in-control")

        self.grant()
        self.assertEqual(self.ui_tab()["controller"], "agent")
        self.assertEqual(self.settled(self.act("granted", observation, "click", "Count"))["state"],
                         "confirmed")
        self.assertEqual(self.settled_clicks(1), ["count"])

        self.app.call("handoff", {"sessionId": self.session, "tabId": self.tab})
        self.assertEqual(self.ui_tab()["controller"], "human")
        self.assertEqual(self.act("after-handoff", observation, "click", "Count")["reason"],
                         "not-in-control")
        self.observe()
        self.assertEqual(self.settled_clicks(1), ["count"])

    def test_one_session_cannot_hand_off_anothers_control(self):
        self.grant("owner")
        with self.assertRaises(bs.RpcError):
            self.app.call("handoff", {"sessionId": "intruder", "tabId": self.tab})
        self.assertEqual(self.ui_tab()["controllerSession"], "owner")
        self.app.call("handoff", {"sessionId": "owner", "tabId": self.tab})

    def test_typing_into_a_field_whose_page_moves_focus_inserts_nothing(self):
        self.navigate(f"focus-redirect.html?load={next(self.loads)}")
        self.mark = len(self.fixtures.log())
        self.grant()
        observation = self.observe()
        row = self.act("redirected", observation, "type", "Source", text="secret")
        settled = self.settled(row)
        self.assertEqual((settled["state"], settled["reason"]), ("failed", "focus-redirected"))
        self.fence()
        self.assertEqual(self.inputs(), [])
        values = self.devtools("Runtime.evaluate", {
            "expression": "[source.value, sink.value]", "returnByValue": True})
        self.assertEqual(values["result"]["value"], ["", ""])

    def test_an_element_that_cannot_be_acted_on_is_refused_before_dispatch(self):
        self.grant()
        observation = self.observe()
        row = self.app.call("act", {"sessionId": self.session, "clientActionId": "ghost",
                                    "observationId": observation["id"], "kind": "click",
                                    "ref": 987654})
        self.assertEqual((row["state"], row["reason"]), ("failed", "unknown-ref"))
        row = self.app.call("act", {"sessionId": self.session, "clientActionId": "ghost-obs",
                                    "observationId": "t0-o0", "kind": "click", "ref": 1})
        self.assertEqual((row["state"], row["reason"]), ("failed", "unknown-observation"))
        row = self.act("not-text", observation, "type", "Count", text="x")
        self.assertEqual((row["state"], row["reason"]), ("failed", "not-editable"))
        self.assertEqual(self.settled_clicks(), [])


if __name__ == "__main__":
    unittest.main()
