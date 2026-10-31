"""The phone's session on a real app: app.sock events, the gateway's /api routes and event stream,
the screencast of a tab that is off screen, writes that never block the app, and the Mac's
"Phone connected" chip (VAL-REMOTE-011, 012 and the deterministic part of 008..010).

No model is called: runs are held before their first model call and driven with `test.runTool`.
The gateway runs on 47852 with a made-up public host.
"""
import base64
import http.client
import json
import queue
import socket
import threading
import time
import unittest

import bs
from appcase import url
from test_gateway import Gateway
from test_perm import LIVE, PermBase

PORT = 47852


class Sse:
    """One open /api/events stream, read on a thread."""

    def __init__(self, gateway, token):
        self.conn, self.response = gateway.request("GET", "/api/events", token, stream=True)
        self.status = self.response.status
        self.lines = queue.Queue()
        self.seen = []
        self.closed = threading.Event()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        name = None
        try:
            for raw in self.response.fp:
                line = raw.decode().rstrip("\n")
                if line.startswith("event: "):
                    name = line[7:]
                elif line.startswith("data: "):
                    self.lines.put((name, json.loads(line[6:])))
        except (OSError, ValueError, http.client.HTTPException):
            pass
        self.closed.set()

    def wait(self, name, predicate=lambda data: True, timeout=10):
        deadline = time.time() + timeout
        for event in self.seen:
            if event[0] == name and predicate(event[1]):
                return event[1]
        while time.time() < deadline:
            try:
                event = self.lines.get(timeout=0.2)
            except queue.Empty:
                continue
            self.seen.append(event)
            if event[0] == name and predicate(event[1]):
                return event[1]
        raise AssertionError(f"no {name} event in {timeout}s; saw {[e[0] for e in self.seen]}")

    def frames(self, count, timeout=10):
        found = []
        deadline = time.time() + timeout
        while len(found) < count and time.time() < deadline:
            try:
                event = self.lines.get(timeout=0.2)
            except queue.Empty:
                continue
            self.seen.append(event)
            if event[0] == "screencast.frame":
                found.append(event[1])
        return found

    def close(self):
        # The reader thread keeps a duplicate of the descriptor open; only a shutdown ends it.
        try:
            self.response.fp.raw._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.conn.close()


class Subscriber:
    """A raw app.sock client that has subscribed: notifications arrive between replies."""

    def __init__(self, data_dir, session=None, rcvbuf=None):
        self.rpc = bs.Rpc(data_dir, timeout=15)
        if rcvbuf:
            self.rpc.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
        self.notes = []
        self.call("events.subscribe", {"session": session} if session else {})

    def call(self, method, params=None):
        self.rpc.send_line(json.dumps({"jsonrpc": "2.0", "id": self.rpc.next_id,
                                       "method": method, "params": params or {}}).encode())
        self.rpc.next_id += 1
        while True:
            message = json.loads(self.rpc.read_line())
            if "id" not in message:
                self.notes.append(message)
                continue
            if "error" in message:
                raise bs.RpcError(message["error"]["code"], message["error"]["message"])
            return message["result"]

    def next_note(self, method):
        while True:
            for note in self.notes:
                if note["method"] == method:
                    self.notes.remove(note)
                    return note["params"]
            self.notes.append(json.loads(self.rpc.read_line()))

    def close(self):
        self.rpc.close()


class PhoneBase(PermBase):
    start_page = "perm.html"

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.gateway = Gateway(cls.app.data_dir, port=PORT)
        try:
            cls.gateway.wait_ready()
        except BaseException:
            cls.gateway.stop()
            super().tearDownClass()
            raise
        cls.app.call("test.holdModel", {"on": True})

    @classmethod
    def tearDownClass(cls):
        cls.gateway.stop()
        super().tearDownClass()

    def setUp(self):
        super().setUp()
        self.streams = []
        self.addCleanup(self.drop_streams)

    def drop_streams(self):
        for stream in self.streams:
            stream.close()
        bs.wait_until(lambda: self.app.call("remote.sessions")["sessions"] == [],
                      what="sessions to empty")
        for run in self.app.call("run.list")["runs"]:
            if run["state"] in ("pending", "running", "waiting-approval"):
                self.app.call("run.stop", {"runId": run["runId"]})

    def pair(self):
        return self.app.call("test.pairToken", {"label": "e2e"})["token"]

    def stream(self, token):
        stream = Sse(self.gateway, token)
        self.streams.append(stream)
        self.assertEqual(stream.status, 200)
        stream.wait("tab.update")
        return stream

    def post(self, route, token, body=None):
        raw = json.dumps(body).encode() if body is not None else b""
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
        try:
            status, _, payload = self.gateway.request(
                "POST", f"/api/{route}", token, body=raw, conn=conn)
        finally:
            conn.close()
        return status, (json.loads(payload) if payload else None)

    def phone_run(self, token, prompt="phone e2e task"):
        status, run = self.post("task", token, {"prompt": prompt})
        self.assertEqual(status, 200, run)
        opened = json.loads(self.app.call("test.runTool", {
            "runId": run["runId"], "name": "open_tab",
            "arguments": {"url": url("perm.html")}})["output"])
        self.wait_loaded(url("perm.html"), opened["id"])
        return run, opened["id"]

    def run_of(self, run_id):
        return next(r for r in self.app.call("run.list")["runs"] if r["runId"] == run_id)

    def phone_state(self):
        return self.app.call("test.ui")["phone"]

    def key(self, key, *modifiers):
        self.app.call("test.key", {"key": key, "modifiers": list(modifiers)})

    def wait_motion_rest(self):
        bs.wait_until(lambda: not self.app.call("test.motion")["inFlight"], what="motion at rest")


class SessionRuleTests(PhoneBase):
    # VAL-REMOTE-002 still holds; the session rule only adds 409
    def test_action_routes_need_an_open_stream_for_the_same_token(self):
        mine, other = self.pair(), self.pair()
        for route in ("task", "stop", "approve", "takeover", "disconnect"):
            status, body = self.post(route, mine, {"prompt": "x", "runId": "r1", "approvalId": "a1",
                                                   "allow": True})
            self.assertEqual((status, body), (409, {"error": "no-session"}), route)
        self.stream(other)
        status, body = self.post("task", mine, {"prompt": "x"})
        self.assertEqual((status, body), (409, {"error": "no-session"}))
        status, _ = self.post("task", "0" * 64, {"prompt": "x"})
        self.assertEqual(status, 401)
        self.stream(mine)
        status, run = self.post("task", mine, {"prompt": "x"})
        self.assertEqual((status, run["origin"]), (200, "phone"))

    def test_bad_input_is_refused_before_the_app_hears_of_it(self):
        token = self.pair()
        self.stream(token)
        before = len(self.app.call("run.list")["runs"])
        for route, body in (("task", {"prompt": "  "}), ("task", {"prompt": 5}),
                            ("stop", {}), ("approve", {"approvalId": "a1"}),
                            ("takeover", [])):
            status, payload = self.post(route, token, body)
            self.assertEqual((status, payload), (400, {"error": "bad-request"}), (route, body))
        status, _, _ = self.gateway.request("POST", "/api/task", token, body=b"x" * (70 << 10))
        self.assertEqual(status, 413)
        status, _ = self.post("stop", token, {"runId": "r999"})
        self.assertEqual(status, 404)
        self.assertEqual(len(self.app.call("run.list")["runs"]), before)


class PhoneRunTests(PhoneBase):
    # VAL-REMOTE-011: a phone run works in a tab of its own
    def test_a_phone_run_opens_and_owns_its_own_tab(self):
        token = self.pair()
        self.stream(token)
        self.app.call("test.holdModel", {"on": True})
        mac = self.app.call("run.start", {"prompt": "mac task", "origin": "mac"})
        self.addCleanup(self.app.call, "run.stop", {"runId": mac["runId"]})
        active_before = self.ui()["activeTabId"]
        self.assertEqual(active_before, self.tab)
        self.app.call("test.devtools", {"tabId": self.tab, "method": "Runtime.evaluate", "params": {
            "expression": "document.cookie = 'shared=mac; path=/'"}})

        run, tab_id = self.phone_run(token)
        self.assertNotEqual(tab_id, self.tab)
        ui = self.ui()
        self.assertEqual(ui["activeTabId"], active_before)
        phone_tab = next(t for t in ui["tabs"] if t["id"] == tab_id)
        self.assertFalse(phone_tab["visible"])
        self.assertEqual(phone_tab["controllerSession"], run["sessionId"])
        mine = self.run_of(run["runId"])
        self.assertEqual((mine["origin"], mine["tabId"]), ("phone", tab_id))
        self.assertEqual(sorted(mine), sorted(self.run_of(mac["runId"])))
        cookie = self.devtools("Runtime.evaluate", {
            "expression": "document.cookie", "returnByValue": True}, tab_id)["result"]["value"]
        self.assertIn("shared=mac", cookie)
        self.assertEqual(self.db("select count(*) from actions where tab_id = ?", (self.tab,)),
                         [(0,)])

    def test_a_phone_run_never_falls_through_to_the_macs_tab(self):
        token = self.pair()
        self.stream(token)
        status, run = self.post("task", token, {"prompt": "phone e2e task"})
        self.assertEqual(status, 200, run)
        mac = self.app.call("observe", {"tabId": self.tab})

        def tool(name, **arguments):
            output = self.app.call("test.runTool", {
                "runId": run["runId"], "name": name, "arguments": arguments})["output"]
            return json.loads(output)

        act = dict(clientActionId="mac-seen", observationId=mac["id"], kind="click",
                   ref=self.ref(mac, "Count"))
        self.assertIn("open_tab", tool("observe")["error"])
        self.assertIn("open_tab", tool("act", **act)["error"])
        self.assertIn("not a page", tool("observe", tabId=self.tab)["error"])
        opened = tool("open_tab", url=url("perm.html"))
        self.assertIn("not a page", tool("act", **act, tabId=opened["id"])["error"])
        self.assertIn("not a page", tool("observe", tabId=self.tab)["error"])
        self.assertEqual(tool("observe")["tabId"], opened["id"])
        self.assertEqual(self.ui()["activeTabId"], self.tab)
        self.assertEqual(self.db("select count(*) from actions where tab_id = ?", (self.tab,)),
                         [(0,)])

    def test_the_overview_shows_a_phone_runs_current_state_after_it_changed_unseen(self):
        token = self.pair()
        stream = self.stream(token)
        run, tab_id = self.phone_run(token)
        self.assertEqual(self.ui()["presentation"], "focused")
        self.assertEqual(self.post("stop", token, {"runId": run["runId"]})[0], 200)
        stream.wait("run.update", lambda d: d["runId"] == run["runId"] and d["state"] == "stopped")
        self.key("\\", "cmd", "shift")
        bs.wait_until(lambda: self.ui()["presentation"] == "overview", what="the overview")
        self.wait_motion_rest()
        node = next(n["id"] for n in self.ui()["canvas"]["nodes"] if n["tabId"] == tab_id)
        drawn = next(n for n in self.ui()["overview"]["nodes"] if n["id"] == node)
        self.assertEqual(drawn["muse"], "Muse · stopped")
        self.key("\\", "cmd", "shift")
        bs.wait_until(lambda: self.ui()["presentation"] == "focused", what="focused")
        self.wait_motion_rest()

    # VAL-REMOTE-012 (deterministic half): the phone's decision and the Mac's are one decision
    def test_a_sensitive_phone_action_waits_and_a_replayed_approval_does_nothing(self):
        token = self.pair()
        stream = self.stream(token)
        run, tab_id = self.phone_run(token)
        self.app.call("test.runState", {"runId": run["runId"], "state": "running"})
        output = self.app.call("observe", {"tabId": tab_id})
        ref = self.ref(output, "Delete draft")
        outcome = {}

        def act():
            rpc = bs.Rpc(self.app.data_dir, timeout=60)
            outcome["result"] = json.loads(rpc.call("test.runTool", {
                "runId": run["runId"], "name": "act", "arguments": {
                    "clientActionId": "phone-1", "observationId": output["id"], "kind": "click",
                    "ref": ref, "tabId": tab_id}})["output"])
            rpc.close()
        worker = threading.Thread(target=act)
        worker.start()
        pending = stream.wait("approval.update", lambda d: len(d["approvals"]) == 1)
        approval = pending["approvals"][0]
        self.assertEqual(approval["tabId"], tab_id)
        self.assertEqual(self.clicks(), [])
        stream.wait("run.update", lambda d: d["runId"] == run["runId"]
                    and d["state"] == "waiting-approval")

        status, body = self.post("approve", token, {"approvalId": approval["approvalId"],
                                                    "allow": True})
        self.assertEqual((status, body["state"]), (200, "allowed"))
        worker.join(30)
        stream.wait("approval.update", lambda d: d["approvals"] == [])
        self.assertEqual(self.pending(), [])
        self.assertEqual(outcome["result"]["state"], "confirmed", outcome)
        self.assertEqual(self.settled_clicks(1), ["delete"])
        status, again = self.post("approve", token, {"approvalId": approval["approvalId"],
                                                     "allow": True})
        self.assertEqual((status, again["state"]), (200, "allowed"))
        self.assertEqual(self.settled_clicks(), ["delete"])

    def test_a_decision_on_the_mac_clears_the_phone(self):
        token = self.pair()
        stream = self.stream(token)
        run, tab_id = self.phone_run(token)
        output = self.app.call("observe", {"tabId": tab_id})
        threading.Thread(target=lambda: bs.Rpc(self.app.data_dir, timeout=60).call(
            "test.runTool", {"runId": run["runId"], "name": "act", "arguments": {
                "clientActionId": "phone-2", "observationId": output["id"], "kind": "click",
                "ref": self.ref(output, "Delete draft"), "tabId": tab_id}}), daemon=True).start()
        approval = stream.wait("approval.update", lambda d: len(d["approvals"]) == 1)
        self.app.call("approval.decide", {"approvalId": approval["approvals"][0]["approvalId"],
                                          "allow": False})
        stream.wait("approval.update", lambda d: d["approvals"] == [])
        self.assertEqual(self.settled_clicks(), [])

    # VAL-REMOTE-012: takeover
    def test_takeover_stops_the_run_and_a_stale_act_is_not_dispatched(self):
        token = self.pair()
        stream = self.stream(token)
        run, tab_id = self.phone_run(token)
        output = self.app.call("observe", {"tabId": tab_id})
        epoch = next(t for t in self.ui()["tabs"] if t["id"] == tab_id)["epoch"]
        status, body = self.post("takeover", token, {"runId": run["runId"]})
        self.assertEqual((status, body["state"], body["reason"]), (200, "stopped", "taken-over"))
        tab = next(t for t in self.ui()["tabs"] if t["id"] == tab_id)
        self.assertEqual((tab["controller"], tab["epoch"]), ("human", epoch + 1))
        stream.wait("run.update", lambda d: d["runId"] == run["runId"] and d["state"] == "stopped")
        late = json.loads(self.app.call("test.runTool", {
            "runId": run["runId"], "name": "act", "arguments": {
                "clientActionId": "late", "observationId": output["id"], "kind": "click",
                "ref": self.ref(output, "Count"), "tabId": tab_id}})["output"])
        self.assertNotEqual(late.get("state"), "confirmed", late)
        self.assertEqual(self.settled_clicks(), [])
        status, again = self.post("takeover", token, {"runId": run["runId"]})
        self.assertEqual((status, again["reason"]), (200, "taken-over"))

    # review: a session acts only on its own runs, and a replayed takeover touches nothing
    def test_another_session_cannot_stop_or_take_over_the_run_and_a_replay_leaves_the_tab_alone(self):
        owner, other = self.pair(), self.pair()
        self.stream(owner)
        self.stream(other)
        run, tab_id = self.phone_run(owner)
        for route in ("stop", "takeover"):
            status, body = self.post(route, other, {"runId": run["runId"]})
            self.assertEqual((status, run["runId"] in body["error"]), (404, True), body)
        self.assertEqual(self.run_of(run["runId"])["state"], "pending")
        self.assertEqual(self.post("takeover", owner, {"runId": run["runId"]})[0], 200)
        epoch = next(t for t in self.ui()["tabs"] if t["id"] == tab_id)["epoch"]
        self.assertEqual(self.post("takeover", owner, {"runId": run["runId"]})[0], 200)
        after = next(t for t in self.ui()["tabs"] if t["id"] == tab_id)
        self.assertEqual((after["controller"], after["epoch"]), ("human", epoch))


class ScreencastTests(PhoneBase):
    # VAL-REMOTE-008 (the part that needs no model)
    def test_frames_of_an_off_screen_phone_tab_are_jpeg_and_follow_the_page(self):
        token = self.pair()
        stream = self.stream(token)
        run, tab_id = self.phone_run(token)
        stream.wait("run.update", lambda d: d["runId"] == run["runId"] and d["tabId"] == tab_id)
        self.assertFalse(next(t for t in self.ui()["tabs"] if t["id"] == tab_id)["visible"])
        first = stream.frames(1, timeout=10)
        self.assertEqual(len(first), 1)
        self.assertEqual(first[0]["tabId"], tab_id)
        seen = {first[0]["data"]}
        for color in ("rgb(200,30,30)", "rgb(20,120,200)"):
            self.devtools("Runtime.evaluate", {"expression":
                f"document.body.style.background = '{color}'"}, tab_id)
            seen.update(f["data"] for f in stream.frames(2, timeout=5))
        self.assertGreaterEqual(len(seen), 2)
        for data in seen:
            self.assertEqual(base64.b64decode(data)[:3], b"\xff\xd8\xff")
        status, _ = self.post("stop", token, {"runId": run["runId"]})
        self.assertEqual(status, 200)
        stream.wait("run.update", lambda d: d["runId"] == run["runId"] and d["state"] == "stopped")

    def test_a_screencast_runs_only_while_a_subscriber_wants_the_tab(self):
        tab = self.tab
        watcher = Subscriber(self.app.data_dir)
        self.addCleanup(watcher.close)
        with self.assertRaises(bs.RpcError):
            watcher.call("screencast.start", {})
        watcher.call("screencast.start", {"tabId": tab})
        self.devtools("Runtime.evaluate", {"expression": "document.body.style.outline='3px solid red'"})
        frame = watcher.next_note("screencast.frame")
        self.assertEqual(frame["tabId"], tab)
        self.assertEqual(base64.b64decode(frame["data"])[:3], b"\xff\xd8\xff")
        watcher.call("screencast.stop", {"tabId": tab})
        watcher.notes.clear()
        self.devtools("Runtime.evaluate", {"expression": "document.body.style.outline='3px solid blue'"})
        time.sleep(1)
        self.app.call("tabs")
        watcher.rpc.sock.settimeout(1)
        with self.assertRaises(OSError):
            while True:
                note = json.loads(watcher.rpc.read_line())
                self.assertNotEqual(note.get("method"), "screencast.frame")
        quiet = bs.Rpc(self.app.data_dir)
        self.addCleanup(quiet.close)
        with self.assertRaises(bs.RpcError):
            quiet.call("screencast.start", {"tabId": tab})


class NeverBlockTests(PhoneBase):
    # architecture §8 "AppServer writes": a client that stops reading costs the app nothing
    def test_a_client_that_stops_reading_is_dropped_and_the_app_stays_responsive(self):
        sock = socket.socket(socket.AF_UNIX)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        sock.connect(f"{self.app.data_dir}/app.sock")
        self.addCleanup(sock.close)
        request = b'{"jsonrpc":"2.0","id":1,"method":"approval.list"}\n'
        sock.setblocking(False)
        sent = 0
        deadline = time.time() + 20
        while sent < 60000 and time.time() < deadline:
            try:
                sock.send(request * 100)
                sent += 100
            except BlockingIOError:
                time.sleep(0.01)
            except OSError:
                break
        slowest = 0
        for _ in range(20):
            started = time.time()
            self.app.call("app.status")
            slowest = max(slowest, time.time() - started)
        self.assertLess(slowest, 0.5)
        sock.setblocking(True)
        sock.settimeout(15)
        total = 0
        try:
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                total += len(chunk)
        except OSError:
            pass
        self.assertGreater(total, 0)
        self.assertEqual(self.app.call("app.status")["ready"], True)

    def test_frames_to_a_client_that_stops_reading_are_coalesced_not_queued(self):
        sleeper = Subscriber(self.app.data_dir, rcvbuf=4096)
        self.addCleanup(sleeper.close)
        sleeper.call("screencast.start", {"tabId": self.tab})
        self.devtools("Runtime.evaluate", {"expression":
            "window.spin = setInterval(() => { document.body.style.background = "
            "'hsl(' + (Date.now() % 360) + ',70%,60%)'; }, 30)"})
        self.addCleanup(self.devtools, "Runtime.evaluate", {"expression": "clearInterval(window.spin)"})
        time.sleep(3)
        started = time.time()
        for _ in range(10):
            self.app.call("tabs")
        self.assertLess(time.time() - started, 1.0)
        # Still connected: frames never count against the limit, and the newest one is waiting.
        frame = sleeper.next_note("screencast.frame")
        self.assertEqual(frame["tabId"], self.tab)


class DisconnectTests(PhoneBase):
    # VAL-REMOTE-012: /api/disconnect
    def test_the_phone_can_disconnect_and_is_refused_until_it_reconnects(self):
        token = self.pair()
        stream = self.stream(token)
        run, _ = self.phone_run(token)
        sessions = self.app.call("remote.sessions")["sessions"]
        self.assertEqual(len(sessions), 1)
        self.assertRegex(sessions[0]["session"], r"^phone-[0-9a-f]{8}$")
        status, body = self.post("disconnect", token)
        self.assertEqual((status, body["closed"]), (200, 1))
        stream.wait("disconnected")
        self.assertTrue(stream.closed.wait(5))
        self.assertEqual(self.app.call("remote.sessions")["sessions"], [])
        stopped = self.run_of(run["runId"])
        self.assertEqual((stopped["state"], stopped["reason"]), ("stopped", "disconnected"))
        self.assertEqual(self.post("task", token, {"prompt": "again"})[0], 409)
        self.stream(token)
        self.assertEqual(self.post("task", token, {"prompt": "again"})[0], 200)

    # VAL-REMOTE-013 (the Mac half): chip, Disconnect button and launcher row
    def test_the_chip_shows_while_a_session_is_open_and_disconnect_ends_it(self):
        token = self.pair()
        self.assertFalse(self.phone_state()["visible"])
        stream = self.stream(token)
        for presentation in ("overview", "focused"):
            if self.ui()["presentation"] != presentation:
                self.key("\\", "cmd", "shift")
                bs.wait_until(lambda: self.ui()["presentation"] == presentation, what=presentation)
            self.wait_motion_rest()
            state = bs.wait_until(lambda: (lambda s: s if s["visible"] and s["opacity"] == 1
                                           else None)(self.phone_state()), what="the chip")
            self.assertEqual(state["label"], "Phone connected")
            self.assertTrue(state["insideWindow"])
            self.assertTrue(state["button"]["hittable"], (presentation, state))
            self.assertEqual(state["button"]["label"], "Disconnect")
            self.assertIn("Manrope", state["button"]["font"])
        run, _ = self.phone_run(token)
        self.app.call("test.click", {"target": "phoneDisconnect"})
        self.assertTrue(stream.closed.wait(10))
        bs.wait_until(lambda: not self.phone_state()["visible"], what="the chip to leave")
        self.assertEqual(self.app.call("remote.sessions")["sessions"], [])
        stopped = self.run_of(run["runId"])
        self.assertEqual((stopped["state"], stopped["reason"]), ("stopped", "disconnected"))
        self.assertEqual(self.post("task", token, {"prompt": "x"})[0], 409)

    def test_the_launcher_row_disconnects_the_phone(self):
        token = self.pair()
        stream = self.stream(token)
        self.key("t", "cmd")
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the launcher")
        self.app.call("test.type", {"text": "disconnect"})
        row = bs.wait_until(lambda: next((r for r in self.ui()["launcher"]["rows"]
                                          if r["target"] == "disconnectPhone"), None),
                            what="the Disconnect phone row")
        self.assertEqual((row["title"], row["enabled"]), ("Disconnect phone", True))
        self.key("ArrowDown")
        self.key("ArrowDown")
        rows = self.ui()["launcher"]["rows"]
        self.assertEqual([r["title"] for r in rows if r["active"]], ["Disconnect phone"], rows)
        self.key("Return")
        self.assertTrue(stream.closed.wait(10))
        self.assertEqual(self.app.call("remote.sessions")["sessions"], [])

    def test_disconnect_over_the_socket_names_the_session(self):
        token = self.pair()
        stream = self.stream(token)
        session = self.app.call("remote.sessions")["sessions"][0]["session"]
        self.assertEqual(self.app.call("remote.disconnect", {"session": "phone-00000000"}),
                         {"closed": 0})
        self.assertEqual(self.app.call("remote.disconnect", {"session": session}), {"closed": 1})
        self.assertTrue(stream.closed.wait(10))


@unittest.skipUnless(LIVE, "live Meta call: not run (no BARESTATE_LIVE_META/BARESTATE_SPEND_LOG)")
class LivePhoneTests(PhoneBase):
    """VAL-REMOTE-011 and 012 against the real model."""

    def test_a_phone_task_runs_in_its_own_tab_and_a_sensitive_click_waits_for_approval(self):
        self.app.call("test.modelOffline", {"on": False})
        self.devtools("Runtime.evaluate", {"expression": "document.cookie = 'phone_e2e=1; path=/'"})
        mac_tab = self.app.call("test.ui")["activeTabId"]
        token = self.pair()
        stream = self.stream(token)
        status, run = self.post("task", token, {"prompt": (
            f"Open {url('perm.html')} in a new tab with open_tab, observe it, click the "
            "'Delete draft' button, then say done in one word.")})
        self.assertEqual(status, 200, run)
        self.app.call("test.holdModel", {"on": False})
        update = stream.wait("approval.update", lambda d: len(d["approvals"]) == 1, timeout=120)
        approval_id = update["approvals"][0]["approvalId"]
        self.assertEqual(self.run_of(run["runId"])["origin"], "phone")
        self.assertEqual(self.app.call("test.ui")["activeTabId"], mac_tab)
        tabs = [t for t in self.app.call("test.ui")["tabs"] if t["id"] != mac_tab]
        self.assertEqual(len(tabs), 1, tabs)
        phone_tab = tabs[0]["id"]
        self.assertEqual(self.db("select count(*) from actions where tab_id = ?", (mac_tab,)),
                         [(0,)])
        cookie = self.devtools("Runtime.evaluate", {"expression": "document.cookie"},
                               tab_id=phone_tab)["result"]["value"]
        self.assertIn("phone_e2e=1", cookie)
        self.assertEqual(self.db("select count(*) from actions where state = 'confirmed'"), [(0,)])
        self.assertEqual(self.db("select count(*) from actions where state = 'quoted'"), [(1,)])
        self.assertEqual(self.run_of(run["runId"])["state"], "waiting-approval")
        self.assertEqual(self.post("approve", token, {
            "approvalId": approval_id, "allow": True})[0], 200)
        stream.wait("approval.update", lambda d: d["approvals"] == [])
        ended = bs.wait_until(lambda: (lambda r: r if r["state"] in ("completed", "failed", "stopped")
                                       else None)(self.run_of(run["runId"])), timeout=120,
                              what="the phone run to end")
        self.assertEqual(ended["state"], "completed", ended)
        self.assertEqual(self.db("select count(*) from actions where tab_id = ?", (mac_tab,)),
                         [(0,)])
        self.assertTrue(any(e[0] == "screencast.frame" and e[1]["tabId"] == phone_tab
                            for e in stream.seen))
