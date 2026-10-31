"""Accessibility tree, the 720 x 600 window, larger text and keyboard-only use (VAL-TABS-011,
VAL-CROSS-004, VAL-CROSS-007). VoiceOver itself is not run: `test.ax` reads the same
NSAccessibility attributes VoiceOver does."""
import os
import shutil
import unittest

import bs
from appcase import LOG_DIR, save, url
from test_canvas import COLOURS, CanvasCase, band

KYOTO = "Find a quiet hotel in Kyoto under $200 a night"


def flatten(nodes):
    for node in nodes:
        yield node
        yield from flatten(node.get("children", []))


def inside(frame, outer, slack=0):
    """Whether `frame` lies in `outer`; both are window-coordinate rects."""
    return (frame["x"] >= outer.get("x", 0) - slack and frame["y"] >= outer.get("y", 0) - slack
            and frame["x"] + frame["w"] <= outer.get("x", 0) + outer["w"] + slack
            and frame["y"] + frame["h"] <= outer.get("y", 0) + outer["h"] + slack)


class AccessCase(CanvasCase):
    def ax(self, name=None):
        tree = list(flatten(self.call("test.ax")))
        if name:
            save(f"ax-{name}.json", tree)
        return tree

    def named(self, tree, label, role=None):
        found = [n for n in tree if n.get("label", "").startswith(label)
                 and (role is None or n.get("role") == role)]
        self.assertTrue(found, f"{label!r} ({role}) in {[n.get('label') for n in tree]}")
        return found[0]

    def open_launcher(self, text=None):
        self.key("t", "cmd")
        bs.wait_until(lambda: self.ui()["launcher"]["open"]
                      and self.ui()["firstResponder"].get("chromeId") == "launcherField",
                      what="the launcher open")
        if text:
            self.key("a", "cmd")
            self.key("Backspace")
            self.call("test.type", {"text": text})
            bs.wait_until(lambda: (lambda s: s["current"] and s["query"] == text)(
                self.ui()["launcher"]), what=f"rows for {text!r}")
        return self.ui()["launcher"]

    def close_launcher(self):
        if self.ui()["launcher"]["open"]:
            self.key("Escape")
            bs.wait_until(lambda: not self.ui()["launcher"]["open"], what="the launcher closed")

    def responder(self):
        return self.ui()["firstResponder"].get("chromeId")

    def show_page(self):
        if self.presentation() != "focused":
            self.key("\\", "cmd", "shift")
            self.wait_presentation("focused")


class TreeTests(AccessCase):
    def test_overview_tree_names_kinds_current_selection_and_press(self):
        """VAL-TABS-011: command button, canvas group, nodes, legend, traffic lights."""
        first = self.band("First", COLOURS[0])
        before = self.tab_ids()
        self.show_page()
        self.commit_launcher(band("Second", COLOURS[1]), kind="openURL")
        second = self.new_tab_after(before, "Second")["id"]
        self.call("test.closeTab", {"tabId": first})
        self.show_overview()
        tree = self.ax("overview")

        group = self.named(tree, "Your pages", "AXGroup")
        self.assertTrue(group["enabled"])
        self.assertIn("AXTextField", {n["role"] for n in tree if n["label"] == "Canvas title"})

        nodes = [n for n in tree if n.get("role") == "AXButton"
                 and ("live page" in n["label"] or "closed page" in n["label"])]
        self.assertEqual(len(nodes), 2, [n["label"] for n in nodes])
        closed = next(n for n in nodes if n["label"].startswith("First"))
        live = next(n for n in nodes if n["label"].startswith("Second"))
        self.assertIn("closed page", closed["label"])
        self.assertIn("live page", live["label"])
        self.assertIn("127.0.0.1", live["label"])
        self.assertNotIn("Current page", closed["label"])
        self.assertIn("Current page", live["label"])
        for node in nodes:
            self.assertEqual(node["actions"], ["AXPress"], node["label"])
            self.assertTrue(node["enabled"])
        selection = self.overview()["selection"]
        selected = [n for n in self.overview()["nodes"] if n["id"] == selection]
        self.assertEqual(len(selected), 1)
        self.assertEqual([n["label"].split(",")[0] for n in nodes if n["selected"]],
                         [selected[0]["title"]])
        self.assertNotIn("Muse", " ".join(n["label"] for n in nodes))

        legend = self.named(tree, "Legend", "AXGroup")
        self.assertIn("Your trail", legend["value"])
        button = self.named(tree, "Search or do anything", "AXButton")
        self.assertEqual((button["actions"], button["description"]), (["AXPress"], "⌘T"))
        self.assert_traffic_lights(tree)
        self.assertIn(second, self.tab_ids())

    def assert_traffic_lights(self, tree):
        lights = {n["subrole"]: n for n in tree if "subrole" in n}
        self.assertEqual(set(lights), {"AXCloseButton", "AXMinimizeButton", "AXFullScreenButton"})
        for light in lights.values():
            self.assertEqual(light["role"], "AXButton")
            self.assertIn("AXPress", light["actions"])

    def test_focused_caption_and_find_field(self):
        """VAL-TABS-011: caption group, find field with its buttons."""
        self.open_page("Caption page")
        self.show_page()
        tree = self.ax("focused")
        caption = self.named(tree, "Caption page", "AXGroup")
        self.assertTrue(caption["enabled"])
        self.assertIn("127.0.0.1", caption["value"])
        self.assertIn("Not secure", caption["value"])
        self.key("f", "cmd")
        bs.wait_until(lambda: self.ui()["chrome"]["find"]["open"], what="the find bar")
        tree = self.ax("find")
        self.named(tree, "Find in page", "AXTextField")
        for label in ("Previous match", "Next match", "Close find bar"):
            self.assertEqual(self.named(tree, label, "AXButton")["actions"], ["AXPress"], label)
        self.key("Escape")

    def test_launcher_tree_rows_selected_and_disabled_explanation(self):
        """VAL-TABS-011: launcher group, input, rows, disabled rows with their explanation."""
        self.open_page("Alpha page")
        self.call("test.modelOffline", {"on": True})
        state = self.open_launcher(KYOTO)
        tree = self.ax("launcher")
        group = self.named(tree, "Command launcher", "AXGroup")
        self.assertTrue(group["enabled"])
        self.named(tree, "Search, visit a website, or start a task", "AXTextField")
        labels = {f"{r['title']}, {r['subtitle']}" for r in state["rows"]}
        rows = [n for n in tree if n.get("role") == "AXButton" and n["label"] in labels]
        self.assertEqual(len(rows), len(state["rows"]), [n["label"] for n in tree])
        active = next(r for r in state["rows"] if r["id"] == state["active"])
        self.assertEqual(sum(n["selected"] for n in rows), 1)
        self.assertTrue(next(n for n in rows if n["selected"])["label"].startswith(active["title"]))
        disabled = [r for r in state["rows"] if not r["enabled"]]
        self.assertTrue(disabled, "model offline disables Start task")
        for row in disabled:
            node = self.named(tree, row["title"], "AXButton")
            self.assertFalse(node["enabled"])
            self.assertEqual(node["description"], row["subtitle"])
            self.assertTrue(node["description"])
        for node in rows:
            if node["enabled"]:
                self.assertEqual(node["actions"], ["AXPress"], node["label"])
        self.call("test.modelOffline", {"on": False})
        self.close_launcher()


class NarrowTests(AccessCase):
    def test_720_by_600_and_larger_text_keep_every_control_inside(self):
        """VAL-CROSS-007: frames per scale and presentation, collapsed focused layout."""
        self.open_page("Narrow page")
        self.open_page("Second narrow page")
        self.addCleanup(self.call, "test.textScale", {"scale": 1})
        self.assertEqual(self.ui()["window"]["minContentSize"], {"w": 720, "h": 600})
        self.call("test.windowSize", {"w": 720, "h": 600})
        window = {"w": 720, "h": 600}
        report = {}
        row_heights = {}
        for scale in (1.0, 1.5, 2.0):
            self.call("test.textScale", {"scale": scale})
            for presentation in ("overview", "focused"):
                if presentation == "overview":
                    self.show_overview()
                else:
                    self.show_page()
                ui = self.ui()
                button = ui["commandButton"]
                where = (scale, presentation)
                self.assertTrue(inside(button["frame"], window, 2), (where, button["frame"]))
                if presentation == "focused":
                    caption = ui["caption"]
                    self.assertTrue(inside(caption["frame"], window, 2), (where, caption))
                    self.assertTrue(caption["fits"], where)
                    self.assertLessEqual(caption["frame"]["y"] + caption["frame"]["h"],
                                         button["frame"]["y"] + 2, where)
                    self.assertFalse(ui["focus"]["columns"], where)
                    live = ui["focus"]["liveFrame"]
                    self.assertGreaterEqual(live["w"], 720 - 2 * 24 - 2, where)
                    self.key("f", "cmd")
                    bs.wait_until(lambda: self.ui()["chrome"]["find"]["open"], what="find bar")
                    find = self.ui()["chrome"]["find"]
                    self.assertTrue(inside(find["frame"], window, 2), (where, find))
                    self.assertTrue(inside(find["frame"], live, 2), (where, find, live))
                    self.key("Escape")
                launcher = self.open_launcher()
                frame = launcher["frame"]
                self.assertAlmostEqual(frame["x"], 24, delta=2, msg=where)
                self.assertAlmostEqual(720 - frame["x"] - frame["w"], 24, delta=2, msg=where)
                self.assertGreaterEqual(frame["y"], 22, where)
                self.assertLessEqual(frame["y"] + frame["h"], 600 - 22, where)
                for row in launcher["rows"]:
                    if row["frame"] and row["visible"]:
                        self.assertTrue(inside(row["frame"], frame, 2), (where, row["title"]))
                row_heights[where] = launcher["rows"][0]["frame"]["h"]
                report[f"{scale}/{presentation}"] = {"command": button["frame"], "launcher": frame}
                self.close_launcher()
        save("narrow-frames.json", report)
        for presentation in ("overview", "focused"):
            self.assertGreater(row_heights[(2.0, presentation)], row_heights[(1.0, presentation)])
            self.assertGreater(row_heights[(1.5, presentation)], row_heights[(1.0, presentation)])

    def test_long_text_wraps_in_launcher_rows_at_double_size(self):
        """VAL-CROSS-007: rows grow in height and the text wraps instead of truncating."""
        long_title = "A very long page title " * 6
        self.open_page(long_title.strip())
        self.call("test.windowSize", {"w": 720, "h": 600})
        self.addCleanup(self.call, "test.textScale", {"scale": 1})
        heights = {}
        for scale in (1.0, 2.0):
            self.call("test.textScale", {"scale": scale})
            state = self.open_launcher()
            row = next(r for r in state["rows"] if r["kind"] == "switchTab")
            heights[scale] = row["frame"]["h"]
            self.close_launcher()
        self.assertGreater(heights[2.0], 2 * heights[1.0] - 1)


class ApprovalCardTests(AccessCase):
    """VAL-TASK-010 (the card's fit, Tab order and names) and VAL-TABS-009 (its fonts)."""

    def quoted(self, title="Approval page", tab=None):
        tab = tab or self.open_page(title, page="perm.html")
        request = self.call("request_control", {"sessionId": "s-card", "tabId": tab})
        self.call("control.decide", {"requestId": request["requestId"], "allow": True})
        observation = self.call("observe", {"tabId": tab})
        ref = next(e["ref"] for e in observation["elements"] if e["name"] == "Delete draft")
        row = self.call("act", {"sessionId": "s-card", "clientActionId": f"card-{title}",
                                "observationId": observation["id"], "kind": "click", "ref": ref})
        self.assertEqual(row["state"], "quoted", row)
        return tab, row

    def card(self):
        return bs.wait_until(
            lambda: (lambda c: c if c.get("visible") and c["allow"]["hittable"]
                     and not self.call("test.motion")["inFlight"] else None)(self.ui()["approval"]),
            what="the approval card at rest")

    def test_the_card_fits_at_720_by_600_and_larger_text_in_both_presentations(self):
        self.quoted()
        self.call("test.windowSize", {"w": 720, "h": 600})
        self.addCleanup(self.call, "test.textScale", {"scale": 1})
        window = {"w": 720, "h": 600}
        report = {}
        for scale in (1.0, 1.5, 2.0):
            self.call("test.textScale", {"scale": scale})
            for presentation in ("overview", "focused"):
                self.show_overview() if presentation == "overview" else self.show_page()
                card = self.card()
                where = (scale, presentation)
                self.assertTrue(inside(card["frame"], window, 1), (where, card["frame"]))
                self.assertTrue(card["fits"], where)
                self.assertEqual(card["text"], 'Click "Delete draft"', where)
                for control in ("allow", "deny"):
                    self.assertTrue(inside(card[control]["frame"], card["frame"], 1),
                                    (where, control, card[control]["frame"], card["frame"]))
                    self.assertTrue(card[control]["enabled"], (where, control))
                self.assertFalse(card["allow"]["frame"]["y"] < card["frame"]["y"] - 1, where)
                if presentation == "focused":
                    self.assertFalse(card["overlapsPage"], (where, card["frame"], card["pageFrame"]))
                button = self.ui()["commandButton"]
                self.assertFalse(
                    button["visible"]
                    and card["frame"]["x"] < button["frame"]["x"] + button["frame"]["w"]
                    and card["frame"]["x"] + card["frame"]["w"] > button["frame"]["x"]
                    and card["frame"]["y"] < button["frame"]["y"] + button["frame"]["h"]
                    and card["frame"]["y"] + card["frame"]["h"] > button["frame"]["y"],
                    (where, "the command button is covered", card["frame"], button["frame"]))
                launcher = self.open_launcher()
                self.assertFalse(self.ui()["approval"]["visible"], (where, "over the launcher"))
                self.assertTrue(launcher["open"])
                self.close_launcher()
                self.card()
                report[f"{scale}/{presentation}"] = {"card": card["frame"], "page": card["pageFrame"]}
        save("approval-card-frames.json", report)

    def test_a_very_long_quote_keeps_both_buttons_in_view_and_off_the_page(self):
        tab = self.open_page("Long quote", page="perm.html")
        request = self.call("request_control", {"sessionId": "s-long", "tabId": tab})
        self.call("control.decide", {"requestId": request["requestId"], "allow": True})
        observation = self.call("observe", {"tabId": tab})
        ref = next(e["ref"] for e in observation["elements"] if e["name"] == "Password")
        row = self.call("act", {"sessionId": "s-long", "clientActionId": "long", "kind": "type",
                                "observationId": observation["id"], "ref": ref,
                                "text": "long secret " * 120})
        self.assertEqual(row["state"], "quoted", row)
        self.call("test.windowSize", {"w": 720, "h": 600})
        self.addCleanup(self.call, "test.textScale", {"scale": 1})
        window = {"w": 720, "h": 600}
        for scale in (1.0, 2.0):
            self.call("test.textScale", {"scale": scale})
            for presentation in ("overview", "focused"):
                self.show_overview() if presentation == "overview" else self.show_page()
                card = self.card()
                where = (scale, presentation)
                self.assertTrue(inside(card["frame"], window, 1), (where, card["frame"]))
                for control in ("allow", "deny"):
                    self.assertTrue(inside(card[control]["frame"], card["frame"], 1), (where, control))
                    self.assertTrue(card[control]["hittable"], (where, control))
                if presentation == "focused":
                    self.assertFalse(card["overlapsPage"], (where, card["frame"], card["pageFrame"]))
        listed = self.call("approval.list")["approvals"]
        self.assertIn("long secret " * 120, listed[-1]["text"])

    def test_allow_once_and_deny_are_reached_by_tab_and_named_with_a_press_action(self):
        tab, row = self.quoted()
        self.call("test.windowSize", {"w": 720, "h": 600})
        self.addCleanup(self.call, "test.textScale", {"scale": 1})
        reached = {}
        for scale in (1.5, 2.0):
            self.call("test.textScale", {"scale": scale})
            for presentation in ("overview", "focused"):
                self.show_overview() if presentation == "overview" else self.show_page()
                self.card()
                tree = self.ax(f"approval-{scale}-{presentation}")
                for label in ("Allow once", "Deny"):
                    node = self.named(tree, label, "AXButton")
                    self.assertEqual(node["actions"], ["AXPress"], (scale, presentation, label))
                    self.assertTrue(node["enabled"], (scale, presentation, label))
                self.named(tree, 'Click "Delete draft"')
                visited = []
                if presentation == "focused":
                    # The page hands focus on one control at a time, so each Tab is awaited.
                    self.evaluate("document.getElementById('secret').focus()", tab)
                    bs.wait_until(lambda: self.ui()["firstResponder"]["tabId"] == tab,
                                  what="the page focused")
                    for _ in range(2):
                        self.key("Tab")
                        before = visited[-1:]
                        visited.append(bs.wait_until(
                            lambda: (lambda r: r if r and [r] != before else None)(self.responder()),
                            what="the next control"))
                else:
                    self.key("Tab")
                    for _ in range(12):
                        visited.append(self.responder())
                        self.key("Tab")
                reached[f"{scale}/{presentation}"] = visited
                for chrome_id in ("approvalAllow", "approvalDeny"):
                    self.assertIn(chrome_id, visited, (scale, presentation))
        save("tab-approval.json", reached)
        self.show_page()
        self.card()
        for label in ("Deny", "Allow once"):
            self.wait_focus(label)
            self.key("Tab", "shift")
        self.in_page(tab)
        self.evaluate("document.getElementById('secret').focus()", tab)
        for label in ("Allow once", "Deny"):
            self.key("Tab")
            self.wait_focus(label)
        self.key("Enter")
        decided = bs.wait_until(
            lambda: (lambda r: r if r["state"] == "cancelled" else None)(self.call(
                "action_status", {"sessionId": "s-card", "clientActionId": row["clientActionId"]})),
            what="Enter on Deny")
        self.assertEqual(decided["reason"], "denied")
        bs.wait_until(lambda: not self.ui()["approval"]["visible"], what="the card to leave")

    def focused_label(self):
        return next((n["label"] for n in self.ax() if n.get("focused")), None)

    def wait_focus(self, label):
        bs.wait_until(lambda: self.focused_label() == label, what=f"focus on {label!r}")

    def in_page(self, tab):
        bs.wait_until(lambda: self.ui()["firstResponder"]["tabId"] == tab, what="the page focused")
        bs.wait_until(lambda: self.evaluate("document.hasFocus()", tab), what="document focus")

    def click_into_page(self, tab):
        """Real click into the page's last focusable element, so Tab leaves the page at once."""
        self.show_page()
        x, y = self.evaluate("(r => [r.x + r.width / 2, r.y + r.height / 2])("
                             "document.getElementById('secret').getBoundingClientRect())", tab)
        self.call("test.click", {"target": tab, "x": x, "y": y})
        bs.wait_until(lambda: self.evaluate("document.activeElement.id", tab) == "secret"
                      and self.ui()["firstResponder"]["tabId"] == tab, what="the page input focused")

    def test_tab_leaves_the_page_for_the_card_and_shift_tab_comes_back(self):
        """VAL-TASK-010: keyboard reach from inside the page (synthetic keys, locked screen)."""
        tab = self.open_page("Tab out", page="perm.html")
        self.click_into_page(tab)
        _, row = self.quoted(tab=tab)
        self.card()
        self.key("Tab")
        self.wait_focus("Allow once")
        self.key("Tab")
        self.wait_focus("Deny")
        self.key("Tab", "shift")
        self.wait_focus("Allow once")
        self.key("Tab", "shift")
        self.in_page(tab)
        self.assertIsNone(self.focused_label())

        # A click would take over and withdraw the card; the page's script puts focus back.
        self.evaluate("document.getElementById('secret').focus()", tab)
        self.key("Tab")
        self.wait_focus("Allow once")
        self.key("Tab")
        self.wait_focus("Deny")
        self.key("Tab")
        self.wait_focus("Search or do anything")
        self.key("Tab")
        self.in_page(tab)

        self.evaluate("document.getElementById('secret').focus()", tab)
        self.key("Tab")
        self.wait_focus("Allow once")
        self.key("Tab")
        self.wait_focus("Deny")
        self.key("Space")
        decided = bs.wait_until(
            lambda: (lambda r: r if r["state"] == "cancelled" else None)(self.call(
                "action_status", {"sessionId": "s-card", "clientActionId": row["clientActionId"]})),
            what="Space on Deny")
        self.assertEqual(decided["reason"], "denied")
        bs.wait_until(lambda: not self.ui()["approval"]["visible"], what="the card to leave")
        self.assertEqual(self.db("SELECT state, reason FROM actions WHERE session_id = 's-card' "
                                 "AND state IN ('cancelled', 'confirmed')"),
                         [("cancelled", "denied")])

    def test_tab_withdraws_a_press_approval_that_is_for_whatever_has_the_focus(self):
        tab = self.open_page("Tab press", page="perm.html")
        self.show_page()
        bs.wait_until(lambda: self.ui()["firstResponder"]["tabId"] == tab, what="the page focused")
        request = self.call("request_control", {"sessionId": "s-card", "tabId": tab})
        self.call("control.decide", {"requestId": request["requestId"], "allow": True})
        observation = self.call("observe", {"tabId": tab})
        self.evaluate("document.getElementById('delete').focus()", tab)
        row = self.call("act", {"sessionId": "s-card", "clientActionId": "tab-press", "kind": "press",
                                "observationId": observation["id"], "key": "Enter"})
        self.assertEqual(row["state"], "quoted", row)
        self.card()
        self.key("Tab")
        bs.wait_until(lambda: not self.ui()["approval"]["visible"], what="the card withdrawn")
        status = self.call("action_status", {"sessionId": "s-card", "clientActionId": "tab-press"})
        self.assertEqual(status["state"], "cancelled", status)

    def test_tab_out_of_the_page_reaches_the_command_button_when_no_card_is_shown(self):
        tab = self.open_page("Tab out bare", page="perm.html")
        self.click_into_page(tab)
        self.assertFalse(self.ui()["approval"]["visible"])
        self.key("Tab")
        self.wait_focus("Search or do anything")
        self.key("Return")
        self.wait_launcher(True)
        self.close_launcher()

    def test_the_card_is_manrope_and_waits_on_the_page_it_is_for(self):
        """VAL-TABS-009: Manrope on the card; the card sits under the page card, off the page."""
        tab, _ = self.quoted()
        self.show_page()
        card = self.card()
        for font in (card["font"], card["allow"]["font"], card["deny"]["font"]):
            self.assertIn("Manrope", font)
        self.assertFalse(card["overlapsPage"])
        self.assertGreaterEqual(card["frame"]["y"], card["pageFrame"]["y"] + card["pageFrame"]["h"] - 1)
        path = f"/tmp/bs-shot-{os.getpid()}-approval.png"
        self.call("test.screenshot", {"path": path})
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        shutil.copyfile(path, os.path.join(LOG_DIR, "approval-card.png"))
        self.show_overview()
        card = self.card()
        node = self.frame(self.node_of(tab)["id"])
        self.assertFalse(card["focusedPresentation"])
        self.assertTrue(inside(card["frame"], {"x": 0, "y": 0, "w": 1440, "h": 900}, 1))
        self.assertGreaterEqual(card["frame"]["y"] + card["frame"]["h"], node["y"] - 1)


class KeyboardTests(AccessCase):
    def test_tab_reaches_the_command_button_and_the_find_controls(self):
        """VAL-CROSS-007: Tab traversal list; every chrome button exposes a press action."""
        self.open_page("Reach page")
        self.show_overview()
        visited = []
        for _ in range(4):
            self.key("Tab")
            visited.append(self.responder())
        save("tab-overview.json", visited)
        self.assertIn("commandButton", visited)
        self.show_page()
        self.key("f", "cmd")
        bs.wait_until(lambda: self.ui()["chrome"]["find"]["open"], what="find bar")
        self.assertEqual(self.responder(), "findField")
        visited = []
        for _ in range(3):
            self.key("Tab")
            visited.append(self.responder())
        save("tab-find.json", visited)
        self.assertEqual(visited, ["findPrevious", "findNext", "findClose"])
        self.key("Escape")
        buttons = [n for n in self.ax() if n.get("role") == "AXButton"]
        self.assertTrue(buttons)
        self.assertEqual([n["label"] for n in buttons if "AXPress" not in n["actions"]], [],
                         "hover-only or press-less control")

    def test_keyboard_only_flow_at_720_and_larger_text(self):
        """VAL-CROSS-007: launcher, page row, overview, arrows, focus, zoom and back."""
        alpha = self.open_page("Alpha keys")
        beta = self.open_page("Beta keys")
        self.call("test.windowSize", {"w": 720, "h": 600})
        self.addCleanup(self.call, "test.textScale", {"scale": 1})
        self.call("test.textScale", {"scale": 1.5})
        self.assertEqual(self.active_id(), beta)

        self.open_launcher("Alpha keys")
        row = next(r for r in self.ui()["launcher"]["rows"] if r["kind"] == "switchTab")
        for _ in self.ui()["launcher"]["rows"]:
            if self.ui()["launcher"]["active"] == row["id"]:
                break
            self.key("ArrowDown")
        self.key("Enter")
        bs.wait_until(lambda: self.active_id() == alpha and not self.ui()["launcher"]["open"],
                      what="Alpha active through the launcher")

        self.key("\\", "cmd", "shift")
        self.wait_presentation("overview")
        start = self.overview()["selection"]
        for arrow in ("ArrowRight", "ArrowLeft", "ArrowDown", "ArrowUp"):
            self.key(arrow)
            if self.overview()["selection"] != start:
                break
        self.assertNotEqual(self.overview()["selection"], start)
        self.key("Enter")
        self.wait_presentation("focused")
        self.assertEqual(self.active_id(), beta)

        self.key("l", "cmd")
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="Cmd-L launcher")
        self.assertTrue(self.ui()["launcher"]["location"])
        self.key("Escape")
        bs.wait_until(lambda: not self.ui()["launcher"]["open"], what="launcher closed")

        self.key("\\", "cmd", "shift")
        self.wait_presentation("overview")
        zoom = self.viewport()["zoom"]
        self.key("-", "cmd")
        bs.wait_until(lambda: self.viewport()["zoom"] < zoom, what="Cmd-- to zoom out")
        self.key("=", "cmd")
        self.key("0", "cmd")
        bs.wait_until(lambda: not self.call("test.motion")["inFlight"], what="motion at rest")
        self.key("Enter")
        self.wait_presentation("focused")


class ReachabilityTests(AccessCase):
    CAPABILITIES = {
        "About Photon": "about", "Settings…": "settings", "New Tab": "launcher",
        "Open Location…": "launcher", "Close Tab": "closed", "Reopen Closed Tab": "reopened",
        "Bookmark This Page": "bookmark", "Find in Page…": "find", "Reload Page": "reload",
        "Show Overview": "overview", "Zoom In": "zoom", "Zoom Out": "zoom",
        "Zoom to Fit": "zoom", "Back": "history", "Forward": "history",
    }

    def menu_items(self):
        titles = {}
        for menu in self.call("test.menu"):
            for item in menu.get("items", []):
                if "title" in item:
                    titles[item["title"]] = item
        return titles

    def test_every_capability_has_a_route_and_launcher_rows_for_the_typed_ones(self):
        """VAL-CROSS-004: menu dump and launcher rows on a fresh data dir; Stop task and
        Show Muse activity are not run (no model key)."""
        items = self.menu_items()
        save("menu-titles.json", sorted(items))
        for title in self.CAPABILITIES:
            self.assertIn(title if title != "Show Overview" else "Show Page", items, title)
        self.assertIn("History", [m["title"] for m in self.call("test.menu")])

        self.open_page("Route page")
        state = self.open_launcher()
        commands = {r["title"] for r in state["rows"] if r["kind"] == "command"}
        self.assertTrue({"History", "Settings"} <= commands, commands)
        self.close_launcher()
        kinds = {}
        for query in ("example.com", "kyoto weather", KYOTO, "Route page"):
            state = self.open_launcher(query)
            kinds[query] = sorted({r["kind"] for r in state["rows"]})
            self.close_launcher()
        save("launcher-kinds.json", kinds)
        self.assertIn("openURL", kinds["example.com"])
        self.assertIn("search", kinds["kyoto weather"])
        self.assertIn("startTask", kinds[KYOTO])
        self.assertIn("switchTab", kinds["Route page"])

    def test_each_menu_route_has_its_effect_once(self):
        """VAL-CROSS-004: one execution per menu capability with the observed effect."""
        def invoke(title):
            self.call("test.menu", {"invoke": title})

        article = self.open_page("Article route", page="article.html")
        # Bookmark.
        invoke("Bookmark This Page")
        bs.wait_until(lambda: self.db("SELECT count(*) FROM bookmarks")[0][0] == 1,
                      what="a bookmark")
        # Reload: one more request for the page.
        requests = len(self.fixtures.log())
        invoke("Reload Page")
        bs.wait_until(lambda: len(self.fixtures.log()) > requests, what="a reload request")
        # Back and Forward.
        second = url("launcher.html?t=Second%20route")
        self.navigate(article, second)
        bs.wait_until(lambda: self.menu_items()["Back"]["enabled"], what="Back enabled")
        invoke("Back")
        self.wait_loaded(url("article.html?t=Article%20route"), article)
        bs.wait_until(lambda: self.menu_items()["Forward"]["enabled"], what="Forward enabled")
        invoke("Forward")
        self.wait_loaded(second, article)
        # Find.
        invoke("Find in Page…")
        bs.wait_until(lambda: self.ui()["chrome"]["find"]["open"], what="the find bar")
        self.key("Escape")
        # Close and reopen.
        count = len(self.tab_ids())
        invoke("Close Tab")
        bs.wait_until(lambda: len(self.tab_ids()) == count - 1, what="the tab closed")
        self.assertTrue(bs.wait_until(lambda: self.menu_items()["Reopen Closed Tab"]["enabled"],
                                      what="Reopen enabled"))
        invoke("Reopen Closed Tab")
        bs.wait_until(lambda: len(self.tab_ids()) == count, what="the tab reopened")
        self.wait_loaded(second, self.active_id())
        # Overview, page, zoom.
        self.show_page()
        invoke("Show Overview")
        self.wait_presentation("overview")
        zoom = self.viewport()["zoom"]
        invoke("Zoom Out")
        bs.wait_until(lambda: self.viewport()["zoom"] < zoom, what="zoom out")
        invoke("Zoom In")
        bs.wait_until(lambda: self.viewport()["zoom"] >= zoom - 1e-6, what="zoom in")
        invoke("Zoom to Fit")
        invoke("Show Page")
        self.wait_presentation("focused")
        # Launcher routes.
        invoke("New Tab")
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="New Tab opens the launcher")
        self.close_launcher()
        invoke("Open Location…")
        bs.wait_until(lambda: self.ui()["launcher"]["location"], what="Open Location")
        self.close_launcher()
        # Settings and About.
        invoke("Settings…")
        bs.wait_until(lambda: self.ui()["settings"]["open"], what="Settings")
        invoke("About Photon")
        bs.wait_until(lambda: self.ui()["about"]["open"], what="About")


if __name__ == "__main__":
    unittest.main()
