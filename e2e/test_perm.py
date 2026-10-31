"""Sensitive actions, Allow once, verified outcomes and restart reconciliation (VAL-PERM-001..006)
on a real tab."""
import hashlib
import os
import signal
import sqlite3
import time
import unittest

import bs
from appcase import url
from test_act import ActBase
from test_core import LOG_DIR, save

LIVE = os.environ.get("BARESTATE_LIVE_META") == "1" and os.environ.get("BARESTATE_SPEND_LOG")


def token(tab, epoch, document, ref, kind, text_hash):
    return hashlib.sha256(f"{tab}|{epoch}|{document}|{ref}|{kind}|{text_hash or ''}".encode()).hexdigest()


class PermBase(ActBase):
    start_page = "perm.html"

    def quote(self, client_id, name, kind="click", text=None, observation=None):
        observation = observation or self.observe()
        row = self.act(client_id, observation, kind, name, text=text)
        self.assertEqual(row["state"], "quoted", row)
        return observation, row

    def ui(self):
        return self.app.call("test.ui")

    def pending(self):
        return self.app.call("approval.list")["approvals"]

    def approval_of(self, row):
        found = [a for a in self.pending() if a.get("actionId") == row["id"]]
        self.assertEqual(len(found), 1, self.pending())
        return found[0]

    def decide(self, row, allow):
        return self.app.call("approval.decide",
                             {"approvalId": self.approval_of(row)["approvalId"], "allow": allow})

    def wait_card(self):
        return bs.wait_until(
            lambda: (lambda c: c if c.get("visible") and c["allow"]["hittable"]
                     and not self.app.call("test.motion")["inFlight"] else None)(self.ui()["approval"]),
            what="the approval card")

    def state(self, row):
        return self.app.call("action_status", {"sessionId": self.session,
                                               "clientActionId": row["clientActionId"]})

    def status_text(self):
        return self.devtools("Runtime.evaluate", {
            "expression": "document.getElementById('status').textContent",
            "returnByValue": True})["result"]["value"]


class QuoteTests(PermBase):
    # VAL-PERM-001
    def test_sensitive_actions_wait_quoted_and_nothing_reaches_the_page(self):
        self.grant()
        observation = self.observe()
        by_name = {e["name"]: e for e in observation["elements"]}
        self.assertTrue(by_name["Delete draft"]["sensitive"])
        self.assertTrue(by_name["Password"]["sensitive"])
        self.assertFalse(by_name["Count"]["sensitive"])

        _, delete = self.quote("q-delete", "Delete draft", observation=observation)
        _, secret = self.quote("q-secret", "Password", "type", "hunter2", observation=observation)
        listed = self.pending()
        self.assertEqual({a["actionId"] for a in listed}, {delete["id"], secret["id"]})
        for item in listed:
            self.assertEqual(item["kind"], "action")
            self.assertEqual(item["sessionId"], self.session)
            self.assertEqual(item["tabId"], self.tab)
        text = {a["actionId"]: a["text"] for a in listed}
        self.assertEqual(text[delete["id"]], 'Click "Delete draft"')
        self.assertEqual(text[secret["id"]], 'Type "hunter2" into "Password"')

        plain = self.settled(self.act("plain", observation, "click", "Count"))
        self.assertEqual(plain["state"], "confirmed", plain)
        self.assertEqual(self.settled_clicks(1), ["count"])
        self.assertEqual(self.settled_inputs(), [])
        time.sleep(0.5)
        self.assertEqual({self.state(r)["state"] for r in (delete, secret)}, {"quoted"})
        rows = self.db("select state, sensitive, approval_token_hash is not null from actions "
                       "where client_action_id in ('q-delete', 'q-secret')")
        self.assertEqual(rows, [("quoted", 1, 1), ("quoted", 1, 1)])
        self.assertEqual(self.db("select count(*) from actions where state = 'pending'"), [(0,)])
        save("perm-quoted.json", {"rows": [delete, secret], "approvals": listed})


class LiveSensitivityTests(PermBase):
    """The page can change what a control is after the observation without moving any key."""

    def page(self, expression):
        self.devtools("Runtime.evaluate", {"expression": expression})

    def test_a_control_renamed_after_the_observation_is_quoted(self):
        self.grant()
        observation = self.observe()
        self.page("document.getElementById('count').textContent = 'Delete everything'")
        row = self.act("renamed", observation, "click", "Count")
        self.assertEqual(row["state"], "quoted", row)
        self.assertEqual(self.settled_clicks(), [])
        self.assertEqual(self.approval_of(row)["text"], 'Click "Delete everything"')

    def test_a_field_retyped_as_a_password_is_quoted_and_kept_from_the_model(self):
        self.grant()
        observation = self.observe()
        self.page("document.getElementById('field').type = 'password'")
        row = self.act("retyped", observation, "type", "Name", text="hunter2")
        self.assertEqual(row["state"], "quoted", row)
        self.assertEqual(self.settled_inputs(), [])

    def test_a_key_press_with_no_target_is_quoted_when_the_focus_is_on_a_sensitive_control(self):
        self.grant()
        observation = self.observe()
        self.page("document.getElementById('delete').focus()")
        row = self.app.call("act", {"sessionId": self.session, "clientActionId": "blind-enter",
                                    "observationId": observation["id"], "kind": "press",
                                    "key": "Enter"})
        self.assertEqual(row["state"], "quoted", row)
        self.assertIn("Delete draft", self.approval_of(row)["text"])
        self.assertEqual(self.settled_clicks(), [])
        self.page("document.getElementById('count').focus()")
        self.decide(row, True)
        final = self.settled(row)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "stale: target"))
        self.assertEqual(self.settled_clicks(), [])
        plain = self.app.call("act", {"sessionId": self.session, "clientActionId": "plain-enter",
                                      "observationId": observation["id"], "kind": "press",
                                      "key": "Enter"})
        self.assertNotEqual(plain["state"], "quoted", plain)


class BoundTargetTests(PermBase):
    """Allow once holds for every path to a sensitive effect: a target that turns sensitive after
    the check, a key whose default action is a sensitive submit, and a key aimed at the focus."""

    start_page = "bound.html"

    def effects(self):
        return self.devtools("Runtime.evaluate", {"expression": "effects", "returnByValue": True}
                             )["result"]["value"]

    def page(self, expression):
        return self.devtools("Runtime.evaluate", {"expression": expression,
                                                  "returnByValue": True})["result"].get("value")

    def press(self, client_id, observation, ref=None):
        params = {"sessionId": self.session, "clientActionId": client_id,
                  "observationId": observation["id"], "kind": "press", "key": "Enter"}
        if ref is not None:
            params["ref"] = ref
        return self.app.call("act", params)

    def test_an_input_that_becomes_a_password_field_on_focus_is_quoted_before_any_text_lands(self):
        self.grant()
        observation = self.observe()
        self.assertFalse(next(e for e in observation["elements"] if e["name"] == "Nickname")
                         ["sensitive"])
        row = self.act("morph", observation, "type", "Nickname", text="hunter2")
        self.assertEqual(row["state"], "quoted", row)
        self.assertEqual(self.page("nick.value"), "")
        self.assertEqual(self.settled_inputs(), [])
        self.assertEqual(self.approval_of(row)["text"], 'Type "hunter2" into "Nickname"')
        self.decide(row, True)
        self.assertEqual(self.settled(row)["state"], "confirmed")
        self.assertEqual(self.settled_inputs(1), [("nick", "hunter2")])

    def test_enter_in_a_field_whose_form_submits_through_delete_account_is_quoted(self):
        self.grant()
        observation = self.observe()
        typed = self.act("name", observation, "type", "Type the account name", text="acme")
        self.assertEqual(self.settled(typed)["state"], "confirmed", typed)
        row = self.press("enter-ref", observation, self.ref(observation, "Type the account name"))
        self.assertEqual(row["state"], "quoted", row)
        self.assertIn("Delete account", self.approval_of(row)["text"])
        self.assertEqual(self.effects()["submits"], 0)
        self.decide(row, True)
        self.settled(row)
        self.assertEqual(self.effects()["submits"], 1)

    def test_enter_with_no_target_in_that_field_is_quoted_the_same_way(self):
        self.grant()
        observation = self.observe()
        self.page("document.getElementById('typed').focus()")
        row = self.press("enter-blind", observation)
        self.assertEqual(row["state"], "quoted", row)
        self.assertIn("Delete account", self.approval_of(row)["text"])
        self.assertEqual(self.effects()["submits"], 0)
        self.decide(row, True)
        self.settled(row)
        self.assertEqual(self.effects()["submits"], 1)

    def test_enter_in_a_field_inside_a_shadow_root_is_quoted_by_its_own_form(self):
        self.grant()
        observation = self.observe()
        self.page("host.shadowRoot.getElementById('innerField').focus()")
        row = self.press("enter-shadow", observation)
        self.assertEqual(row["state"], "quoted", row)
        self.assertIn("Delete account", self.approval_of(row)["text"])
        self.assertEqual(self.effects()["inner"], 0)
        self.decide(row, True)
        self.settled(row)
        self.assertEqual(self.effects()["inner"], 1)

    def test_a_focus_handler_that_joins_a_form_is_run_before_enter_is_judged(self):
        self.grant()
        observation = self.observe()
        self.page("document.getElementById('late').focus()")
        row = self.press("enter-late", observation)
        self.assertEqual(row["state"], "quoted", row)
        self.assertEqual(self.effects()["submits"], 0)

    def test_enter_in_a_field_with_no_form_is_not_quoted(self):
        self.grant()
        observation = self.observe()
        row = self.press("enter-plain", observation, self.ref(observation, "Name"))
        self.assertNotEqual(row["state"], "quoted", row)

    def test_allow_after_the_focus_moved_to_an_identical_control_does_nothing_to_either(self):
        self.grant()
        observation = self.observe()
        self.page("document.getElementById('item1').focus()")
        row = self.press("twin", observation)
        self.assertEqual(row["state"], "quoted", row)
        self.page("document.getElementById('item2').focus()")
        self.decide(row, True)
        final = self.settled(row)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "stale: target"))
        self.assertEqual(self.effects()["items"], [])
        self.assertEqual(self.settled_clicks(), [])


class UnreadableTargetTests(PermBase):
    """A frame or a closed shadow root shows the classifier only its host, so a write that lands on
    one is quoted (a click, typed text, a key that enters text); arrows and Tab are not."""

    start_page = "frames.html"

    def page(self, expression):
        return self.devtools("Runtime.evaluate", {"expression": expression,
                                                  "returnByValue": True})["result"].get("value")

    def press(self, client_id, observation, key, ref=None):
        params = {"sessionId": self.session, "clientActionId": client_id,
                  "observationId": observation["id"], "kind": "press", "key": key}
        if ref is not None:
            params["ref"] = ref
        return self.app.call("act", params)

    def count(self, name):
        self.fence()
        return sum(len(b[name]) for b in self.beacons(self.mark) if name in b)

    def focus_same_origin_field(self):
        self.page("document.getElementById('same').contentDocument.getElementById('card').focus()")
        self.assertEqual(self.page("document.activeElement.id"), "same")

    def test_enter_with_the_focus_in_a_same_origin_frame_is_quoted_then_lands_once(self):
        self.grant()
        observation = self.observe()
        self.focus_same_origin_field()
        row = self.press("frame-enter", observation, "Enter")
        self.assertEqual(row["state"], "quoted", row)
        self.assertEqual(self.approval_of(row)["text"], 'Press "Enter" on "Same-origin frame"')
        self.assertEqual(self.count("submit"), 0)
        self.decide(row, True)
        self.settled(row)
        self.assertEqual(self.count("submit"), 1)

    def test_enter_with_the_focus_in_a_cross_origin_frame_is_quoted_then_lands_once(self):
        if self.page("document.getElementById('cross').contentDocument") is not None:
            self.skipTest("the cross-origin host name did not give a second origin")
        self.grant()
        observation = self.observe()
        box = self.page("(r => ({x: r.x, y: r.y}))(document.getElementById('cross')"
                        ".getBoundingClientRect())")
        for kind in ("mousePressed", "mouseReleased"):  # a click into the field puts the focus there
            self.devtools("Input.dispatchMouseEvent", {
                "type": kind, "x": box["x"] + 20, "y": box["y"] + 15, "button": "left",
                "clickCount": 1})
        bs.wait_until(lambda: self.page("document.activeElement.id") == "cross",
                      what="the focus to enter the cross-origin frame")
        row = self.press("cross-enter", observation, "Enter")
        self.assertEqual(row["state"], "quoted", row)
        self.assertEqual(self.approval_of(row)["text"], 'Press "Enter" on "Cross-origin frame"')
        self.assertEqual(self.count("submit"), 0)
        self.decide(row, True)
        self.settled(row)
        self.assertEqual(self.count("submit"), 1)

    def test_space_on_a_button_inside_a_closed_shadow_root_is_quoted_then_clicks_once(self):
        self.grant()
        observation = self.observe()
        self.page("focusClosed()")
        row = self.press("closed-space", observation, "Space")
        self.assertEqual(row["state"], "quoted", row)
        self.assertEqual(self.approval_of(row)["text"], 'Press "Space" on "Closed widget"')
        self.assertEqual(self.count("closed"), 0)
        self.decide(row, True)
        self.settled(row)
        self.assertEqual(self.count("closed"), 1)

    def test_a_click_by_ref_on_a_closed_shadow_host_or_a_frame_is_quoted(self):
        self.grant()
        observation = self.observe()
        host = self.act("host-click", observation, "click", "Closed widget")
        self.assertEqual(host["state"], "quoted", host)
        frame = self.act("frame-click", observation, "click", "Roled frame")
        self.assertEqual(frame["state"], "quoted", frame)
        self.assertEqual(self.approval_of(frame)["text"], 'Click "Roled frame"')
        self.assertEqual(self.settled_clicks(), [])
        self.assertEqual(self.count("closed"), 0)

    def test_keys_that_enter_no_text_are_not_quoted_inside_a_frame(self):
        self.grant()
        observation = self.observe()
        self.focus_same_origin_field()
        for key in ("ArrowDown", "Tab"):
            row = self.press(f"frame-{key}", observation, key)
            self.assertNotEqual(row["state"], "quoted", row)
            self.settled(row)
        self.assertEqual(self.count("submit"), 0)

    def typed_into_the_frame_field(self):
        return self.page("document.getElementById('same').contentDocument"
                         ".getElementById('card').value")

    def test_a_letter_with_the_focus_in_a_frame_is_quoted_then_lands_one_keystroke(self):
        self.grant()
        observation = self.observe()
        self.focus_same_origin_field()
        before = self.typed_into_the_frame_field()
        row = self.press("frame-letter", observation, "q")
        self.assertEqual(row["state"], "quoted", row)
        self.assertEqual(self.approval_of(row)["text"], 'Press "q" on "Same-origin frame"')
        self.assertEqual(self.typed_into_the_frame_field(), before)
        self.decide(row, True)
        self.settled(row)
        self.assertEqual(self.typed_into_the_frame_field(), before + "q")

    def test_a_letter_quoted_in_a_frame_is_cancelled_when_the_focus_moves(self):
        self.grant()
        observation = self.observe()
        self.focus_same_origin_field()
        before = self.typed_into_the_frame_field()
        row = self.press("frame-letter-moved", observation, "q")
        self.assertEqual(row["state"], "quoted", row)
        self.page("document.getElementById('host').focus()")
        self.decide(row, True)
        final = self.settled(row)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "stale: target"))
        self.assertEqual(self.typed_into_the_frame_field(), before)

    def test_allow_after_the_focus_left_the_frame_does_nothing(self):
        self.grant()
        observation = self.observe()
        self.focus_same_origin_field()
        row = self.press("frame-moved", observation, "Enter")
        self.assertEqual(row["state"], "quoted", row)
        self.page("document.getElementById('host').focus()")
        self.decide(row, True)
        final = self.settled(row)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "stale: target"))
        self.assertEqual(self.count("submit"), 0)


    def quote_letter_on_the_notes_widget(self, client_id, focused):
        self.grant()
        observation = self.observe()
        if focused:
            self.page("focusField()")
            self.assertEqual(self.page("document.activeElement.id"), "field")
        row = self.press(client_id, observation, "q", ref=self.ref(observation, "Notes widget"))
        self.assertEqual(row["state"], "quoted", row)
        self.assertEqual(self.page("fieldValue()"), "")
        return observation, row

    def test_a_letter_by_ref_on_a_focused_closed_host_lands_once(self):
        _, row = self.quote_letter_on_the_notes_widget("host-q", focused=True)
        self.decide(row, True)
        self.settled(row)
        self.assertEqual(self.page("fieldValue()"), "q")

    def test_a_letter_by_ref_on_a_closed_host_that_was_not_focused_lands_once(self):
        _, row = self.quote_letter_on_the_notes_widget("host-q-cold", focused=False)
        self.decide(row, True)
        self.settled(row)
        self.assertEqual(self.page("fieldValue()"), "q")

    def test_a_letter_by_ref_on_a_closed_host_is_cancelled_when_the_focus_left_it(self):
        observation, row = self.quote_letter_on_the_notes_widget("host-q-moved", focused=True)
        tab = self.press("host-tab", observation, "Tab")
        self.settled(tab)
        self.assertEqual(self.page("document.activeElement.id"), "plain")
        self.decide(row, True)
        final = self.settled(row)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "stale: target"))
        self.assertEqual(self.page("fieldValue()"), "")
        self.assertEqual(self.page("document.getElementById('plain').value"), "")


class AllowTests(PermBase):
    # VAL-PERM-002
    def test_allow_once_dispatches_exactly_once_under_the_bound_token(self):
        self.grant()
        observation, row = self.quote("allow", "Delete draft")
        approval = self.approval_of(row)
        ui_epoch = self.ui_tab()["epoch"]

        answer = self.app.call("approval.decide", {"approvalId": approval["approvalId"],
                                                   "allow": True})
        self.assertEqual((answer["state"], answer["actionId"]), ("allowed", row["id"]))
        final = self.settled(row)
        self.assertEqual(final["state"], "confirmed", final)
        self.assertEqual(self.settled_clicks(1), ["delete"])
        self.assertEqual(self.status_text(), "Draft deleted")

        ref = self.ref(observation, "Delete draft")
        stored, text_hash, dom, model = self.db(
            "select approval_token_hash, text_hash, dom_verdict, model_verdict from actions "
            "where id = ?", (row["id"],))[0]
        self.assertEqual(stored, token(self.tab, ui_epoch, observation["documentKey"], ref,
                                       "click", text_hash))
        self.assertTrue(dom, "the page read-back verdict is stored")
        self.assertTrue(model.startswith("success"), model)

        again = [self.app.call("approval.decide", {"approvalId": approval["approvalId"],
                                                   "allow": True}) for _ in range(2)]
        self.assertEqual(again, [answer, answer])
        flipped = self.app.call("approval.decide", {"approvalId": approval["approvalId"],
                                                    "allow": False})
        self.assertEqual(flipped, answer)
        self.assertEqual(self.settled_clicks(1), ["delete"])
        self.assertEqual(self.pending(), [])
        with self.assertRaises(bs.RpcError):
            self.app.call("approval.decide", {"approvalId": "a9999", "allow": True})
        self.assertEqual(self.db("select count(*) from actions where client_action_id = 'allow'"),
                         [(1,)])

    def test_allowed_typing_into_a_password_field_lands_once_and_is_read_back_exactly(self):
        self.grant()
        _, row = self.quote("secret", "Password", "type", "hunter2")
        self.decide(row, True)
        final = self.settled(row)
        self.assertEqual(final["state"], "confirmed", final)
        self.assertEqual(self.settled_inputs(1), [("secret", "hunter2")])
        stored, text_hash = self.db("select approval_token_hash, text_hash from actions "
                                    "where id = ?", (row["id"],))[0]
        self.assertTrue(stored and text_hash)

    # VAL-TASK-010 (the card is the same decision as the socket's)
    def test_the_card_buttons_allow_and_deny(self):
        self.grant()
        _, deny = self.quote("card-deny", "Delete draft")
        self.wait_card()
        card = self.ui()["approval"]
        self.assertEqual(card["text"], 'Click "Delete draft"')
        self.assertEqual((card["allow"]["label"], card["deny"]["label"]), ("Allow once", "Deny"))
        self.app.call("test.click", {"target": "approvalDeny"})
        final = self.settled(deny)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "denied"))
        bs.wait_until(lambda: not self.ui()["approval"]["visible"], what="the card to leave")

        _, allow = self.quote("card-allow", "Delete draft")
        self.wait_card()
        self.app.call("test.click", {"target": "approvalAllow"})
        self.app.call("test.click", {"target": "approvalAllow"})  # a decided card does nothing
        self.assertEqual(self.settled(allow)["state"], "confirmed")
        self.assertEqual(self.settled_clicks(1), ["delete"])
        self.assertEqual(self.pending(), [])


class CardMotionTests(PermBase):
    """The card's two animations (animation plan row 9): both short, ease out, bound to the card."""

    def recent(self, kind):
        return [m for m in self.app.call("test.motion")["recent"]
                if m["kind"] == kind and m["target"].startswith("a")]

    def newest(self, kind, after):
        found = bs.wait_until(lambda: [m for m in self.recent(kind) if m["id"] > after] or None,
                              what=f"a {kind}")
        return max(found, key=lambda m: m["id"])

    def last_id(self):
        return max([m["id"] for m in self.app.call("test.motion")["recent"]] or [0])

    def test_the_card_enters_and_leaves_with_its_short_ease_out_animations(self):
        self.grant()
        mark = self.last_id()
        _, first = self.quote("motion-in", "Delete draft")
        entered = self.newest("approvalIn", mark)
        self.assertEqual((entered["purpose"], entered["curve"], entered["reduced"]),
                         ("approval-entrance", "easeOut", False))
        self.assertLessEqual(entered["durationMs"], 200)
        self.assertEqual(set(entered["keyPaths"]), {"opacity", "transform"})
        self.wait_card()
        self.decide(first, False)
        left = self.newest("approvalOut", mark)
        self.assertLessEqual(left["durationMs"], 140)
        bs.wait_until(lambda: not self.ui()["approval"]["visible"], what="the card to leave")

    def test_reduce_motion_fades_the_card_without_travel(self):
        self.grant()
        self.app.call("test.reduceMotion", {"on": True})
        self.addCleanup(self.app.call, "test.reduceMotion", {"on": False})
        mark = self.last_id()
        self.quote("motion-reduced", "Delete draft")
        entered = self.newest("approvalIn", mark)
        self.assertTrue(entered["reduced"])
        self.assertEqual(entered["keyPaths"], ["opacity"])
        self.assertLessEqual(entered["durationMs"], 120)
        self.assertTrue(self.wait_card()["allow"]["hittable"])


class DenyAndStaleTests(PermBase):
    # VAL-PERM-003
    def test_deny_cancels_and_nothing_reaches_the_page(self):
        self.grant()
        _, row = self.quote("deny", "Delete draft")
        answer = self.decide(row, False)
        self.assertEqual(answer["state"], "denied")
        final = self.settled(row)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "denied"))
        self.assertEqual(self.settled_clicks(), [])
        self.assertEqual(self.status_text(), "Nothing deleted")
        self.assertEqual(self.pending(), [])

    # VAL-PERM-004
    def test_a_takeover_withdraws_the_approval_and_a_late_allow_does_nothing(self):
        self.grant()
        _, row = self.quote("takeover", "Delete draft")
        approval = self.approval_of(row)
        self.app.call("test.click", {"tabId": self.tab})
        final = self.settled(row)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "stale: epoch"))
        self.assertEqual(self.pending(), [])
        late = self.app.call("approval.decide", {"approvalId": approval["approvalId"],
                                                 "allow": True})
        self.assertEqual(late["state"], "cancelled")
        self.assertEqual(self.settled_clicks(1), ["pad"])
        self.assertEqual(self.status_text(), "Nothing deleted")

    def test_a_new_document_cancels_an_approved_action(self):
        self.grant()
        _, row = self.quote("moved", "Delete draft")
        self.navigate(f"perm.html?other={next(self.loads)}")
        self.decide(row, True)
        final = self.settled(row)
        self.assertEqual((final["state"], final["reason"]), ("cancelled", "stale: documentKey"))
        self.assertEqual(self.settled_clicks(), [])
        self.assertEqual(self.status_text(), "Nothing deleted")
        self.assertEqual(self.db("select approval_token_hash is not null from actions "
                                 "where id = ?", (row["id"],)), [(1,)])


class VerdictTests(PermBase):
    """The verdict table (architecture §5.7) through the stand-in for the model's reading."""

    def verdict(self, mode, name, client_id):
        self.grant()
        self.app.call("test.verifier", {"mode": mode})
        row = self.settled(self.act(client_id, self.observe(), "click", name))
        stored = self.db("select dom_verdict, model_verdict from actions where id = ?", (row["id"],))
        return row, stored[0]

    # VAL-PERM-005
    def test_both_verdicts_agreeing_confirm_or_fail(self):
        row, (dom, model) = self.verdict("agree", "Count", "agree-yes")
        self.assertEqual(row["state"], "confirmed", row)
        self.assertTrue(dom and model.startswith("success"), (dom, model))
        row, (dom, model) = self.verdict("agree", "Inert", "agree-no")
        self.assertEqual(row["state"], "failed", row)
        self.assertTrue(dom and model.startswith("failure"), (dom, model))
        self.assertIn("read-back", row["reason"])

    def test_disagreement_is_outcome_unknown_whichever_side_is_wrong(self):
        row, (dom, model) = self.verdict("failure", "Count", "model-no")
        self.assertEqual(row["state"], "outcome-unknown", row)
        self.assertIn("disagree", row["reason"])
        self.assertTrue(dom and model.startswith("failure"))
        row, (dom, model) = self.verdict("success", "Inert", "dom-no")
        self.assertEqual(row["state"], "outcome-unknown", row)
        self.assertIn("disagree", row["reason"])
        self.assertTrue(dom and model.startswith("success"))
        self.assertEqual(self.settled_clicks(2), ["count", "inert"])

    def test_an_unavailable_model_after_a_landed_write_is_outcome_unknown_and_never_retried(self):
        self.grant()
        self.app.call("test.verifier", {"mode": "live"})
        self.app.call("test.modelOffline", {"on": True})
        self.addCleanup(self.app.call, "test.modelOffline", {"on": False})
        row = self.settled(self.act("offline", self.observe(), "click", "Count"))
        self.assertEqual(row["state"], "outcome-unknown", row)
        self.assertIn("model unavailable", row["reason"])
        self.assertIn("unreachable", row["reason"])
        dom, model = self.db("select dom_verdict, model_verdict from actions where id = ?",
                             (row["id"],))[0]
        self.assertTrue(dom)
        self.assertTrue(model.startswith("unavailable"), model)
        time.sleep(1)
        self.assertEqual(self.settled_clicks(1), ["count"])
        self.assertEqual(self.db("select count(*), max(state) from actions "
                                 "where client_action_id = 'offline'"), [(1, "outcome-unknown")])

    def test_click_read_back_names_what_changed(self):
        self.grant()
        for name, effect in (("Count", "page-changed"), ("Dismiss item", "element-gone"),
                             ("Name", "focused"), ("Inert", "unchanged")):
            observation = self.observe()
            row = self.settled(self.act(f"effect-{name}", observation, "click", name))
            dom = self.db("select dom_verdict from actions where id = ?", (row["id"],))[0][0]
            self.assertEqual(dom, effect, name)

    # VAL-PERM-005 against the real model; needs BARESTATE_LIVE_META=1 and a spend ledger
    @unittest.skipUnless(LIVE, "live Meta call: not run (no BARESTATE_LIVE_META/BARESTATE_SPEND_LOG)")
    def test_a_live_verification_stores_both_verdicts_and_keeps_the_pictures(self):
        self.grant()
        self.app.call("test.verifier", {"mode": "live"})
        self.act("live", self.observe(), "click", "Count")
        row = bs.wait_until(lambda: (lambda r: r if r["state"] != "pending" else None)(
            self.app.call("action_status", {"sessionId": self.session, "clientActionId": "live"})),
            timeout=60, what="the live verdict")
        dom, model = self.db("select dom_verdict, model_verdict from actions where id = ?",
                             (row["id"],))[0]
        self.assertTrue(dom and model.startswith(("success", "failure")), (dom, model))
        self.assertIn(row["state"], {"confirmed", "outcome-unknown"}, row)
        pictures = os.path.join(self.app.data_dir, "tmp")
        self.assertTrue(os.path.exists(os.path.join(pictures, f"verify-{row['id']}-before.jpg")))
        self.assertTrue(os.path.exists(os.path.join(pictures, f"verify-{row['id']}-after.jpg")))
        save("perm-live-verdict.json", {"row": row, "dom": dom, "model": model})

    def live_inert_click(self, page=None):
        if page:
            before = len(self.fixtures.log())
            self.navigate(page)
            self.wait_input_ready(before)
            self.mark = len(self.fixtures.log())
        self.grant()
        self.app.call("test.verifier", {"mode": "live"})
        row = self.settled(self.act("live-inert", self.observe(), "click", "Inert"), timeout=60)
        save(f"perm-live-inert{'-tagged' if page else ''}.json", row)
        self.assertEqual(self.settled_clicks(1), ["inert"])
        return row

    # The model sees only the two pictures: it must not confirm what they do not show.
    @unittest.skipUnless(LIVE, "live Meta call: not run (no BARESTATE_LIVE_META/BARESTATE_SPEND_LOG)")
    def test_a_live_click_that_changes_nothing_is_failed_by_both_readings(self):
        row = self.live_inert_click()
        self.assertEqual(row["domVerdict"], "unchanged", row)
        self.assertTrue(row["modelVerdict"].startswith("failure:"), row)
        self.assertEqual(row["state"], "failed", row)

    @unittest.skipUnless(LIVE, "live Meta call: not run (no BARESTATE_LIVE_META/BARESTATE_SPEND_LOG)")
    def test_a_live_click_that_only_sets_an_invisible_attribute_is_outcome_unknown(self):
        row = self.live_inert_click(f"perm.html?load={next(self.loads)}&tagInert")
        self.assertEqual(row["domVerdict"], "element-changed", row)
        self.assertTrue(row["modelVerdict"].startswith("failure:"), row)
        self.assertEqual(row["state"], "outcome-unknown", row)
        self.assertIn("disagree", row["reason"])


class RestartTests(unittest.TestCase):
    # VAL-PERM-006
    def test_a_crash_while_actions_are_held_reconciles_without_re_dispatch(self):
        data_dir = f"/tmp/bs-perm-{os.getpid()}"
        fixtures = bs.Fixtures(LOG_DIR).start()
        app = bs.App(data_dir, LOG_DIR, label="perm-crash", url=url("perm.html")).start()
        restarted = None
        try:
            tab = bs.wait_until(lambda: next((t for t in app.call("tabs")["tabs"]
                                              if t["url"] == url("perm.html") and not t["loading"]),
                                             None), what="the page")["id"]
            app.call("test.verifier", {"mode": "agree"})
            request = app.call("request_control", {"sessionId": "crash", "tabId": tab})
            app.call("control.decide", {"requestId": request["requestId"], "allow": True})
            observation = app.call("observe", {"tabId": tab})

            def ref(name):
                return next(e["ref"] for e in observation["elements"] if e["name"] == name)

            def act(client_id, kind, name):
                return app.call("act", {"sessionId": "crash", "clientActionId": client_id,
                                        "observationId": observation["id"], "kind": kind,
                                        "ref": ref(name)})

            quoted = act("held-quote", "click", "Delete draft")
            self.assertEqual(quoted["state"], "quoted")
            app.call("test.holdDispatch", {"on": True})
            pending = act("held-pending", "click", "Count")
            self.assertEqual(pending["state"], "pending")
            mark = len(fixtures.log())

            app.allow_exit(-signal.SIGKILL)
            os.kill(app.proc.pid, signal.SIGKILL)
            app.proc.wait(timeout=20)
            app.stop(remove_data=False)

            restarted = bs.App(data_dir, LOG_DIR, label="perm-restart", url=url("perm.html")).start(
                fresh=False)
            rows = {}
            with sqlite3.connect(f"file:{data_dir}/barestate.sqlite?mode=ro", uri=True) as db:
                for client_id, state, reason in db.execute(
                        "select client_action_id, state, reason from actions"):
                    rows[client_id] = (state, reason)
            self.assertEqual(rows["held-pending"][0], "outcome-unknown", rows)
            self.assertIn("never retried", rows["held-pending"][1])
            self.assertEqual(rows["held-quote"][0], "cancelled", rows)
            self.assertNotIn("pending", {s for s, _ in rows.values()})
            self.assertNotIn("quoted", {s for s, _ in rows.values()})
            self.assertEqual(restarted.call("approval.list")["approvals"], [])
            row = restarted.call("action_status", {"sessionId": "crash",
                                                   "clientActionId": "held-pending"})
            self.assertEqual(row["state"], "outcome-unknown")
            time.sleep(1.5)
            clicks = [line for line in fixtures.log(mark) if "click=" in line]
            self.assertEqual(clicks, [])
            save("perm-reconciled.json", rows)
        finally:
            if restarted:
                restarted.stop()
            else:
                app.stop()
            fixtures.stop()


if __name__ == "__main__":
    unittest.main()
