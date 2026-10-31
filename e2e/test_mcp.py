"""barestate-mcp over stdio against a real app (VAL-MCP-001..008)."""
import glob
import itertools
import json
import os
import queue
import re
import socket
import subprocess
import tempfile
import threading
import time

import bs
from appcase import url
from test_act import ActBase
from test_core import save
from test_perm import PermBase

BINARY = os.path.join(bs.ROOT, ".build", "release", "barestate-mcp")
MODERN = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities": {}}
TOOLS = ["tabs", "observe", "extract", "action_status", "open_tab", "request_control", "handoff",
         "act"]


class Stdio:
    """One barestate-mcp process; every stdout line is kept so hygiene can be checked."""

    def __init__(self, data_dir, args=None, env=None, command=BINARY):
        self.stderr = tempfile.TemporaryFile()
        self.proc = subprocess.Popen(
            [command, *(args if args is not None else ["--socket", f"{data_dir}/app.sock"])],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            env={**os.environ, **(env or {})})
        self.lines = []
        self.replies = queue.Queue()
        self.ids = itertools.count(1)
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.proc.stdout:
            self.lines.append(line)
            self.replies.put(line)

    def send(self, text):
        self.proc.stdin.write(text.encode() + b"\n")
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        self.send(json.dumps({"jsonrpc": "2.0", "method": method, **({"params": params} if params else {})}))

    def request(self, method, params=None, timeout=20):
        number = next(self.ids)
        message = {"jsonrpc": "2.0", "id": number, "method": method}
        if params is not None:
            message["params"] = params
        self.send(json.dumps(message))
        return self.reply(number, timeout)

    def reply(self, number, timeout=20):
        end = time.time() + timeout
        while time.time() < end:
            try:
                reply = json.loads(self.replies.get(timeout=0.2))
            except queue.Empty:
                continue
            if reply.get("id") == number:
                return reply
        raise AssertionError(f"no reply to {number} within {timeout} s")

    def tool(self, name, **arguments):
        reply = self.request("tools/call", {"name": name, "arguments": arguments})
        self.assert_no_protocol_error(reply)
        return reply["result"]

    @staticmethod
    def assert_no_protocol_error(reply):
        assert "error" not in reply, reply

    def next_id(self):
        return next(self.ids)

    def stderr_text(self):
        self.stderr.seek(0)
        return self.stderr.read().decode()

    def close(self):
        self.proc.stdin.close()
        started = time.time()
        code = self.proc.wait(timeout=10)
        return code, time.time() - started

    def stop(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
        self.stderr.close()


def data(result):
    """The structured content, after checking the text block mirrors it."""
    assert json.loads(result["content"][0]["text"]) == result["structuredContent"], result
    return result["structuredContent"]


class McpBase:
    def mcp(self, **kwargs):
        client = Stdio(self.app.data_dir, **kwargs)
        self.addCleanup(client.stop)
        return client

    def take_control(self, client):
        """Asks over MCP and answers as the person on the Mac, through the socket."""
        asked = data(client.tool("request_control", tabId=self.tab))
        self.assertEqual(asked["state"], "pending", asked)
        decided = self.app.call("control.decide", {"requestId": asked["requestId"], "allow": True})
        self.assertEqual(decided["state"], "granted")
        return self.holder()


class McpCase(McpBase, ActBase):
    start_page = "act.html"

    # VAL-MCP-001
    def test_legacy_handshake_answers_with_only_json_on_stdout(self):
        client = self.mcp()
        initialized = client.request("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "e2e", "version": "1"}})["result"]
        self.assertEqual(initialized["protocolVersion"], "2025-06-18")
        self.assertIn("tools", initialized["capabilities"])
        self.assertEqual(initialized["serverInfo"]["name"], "barestate-mcp")
        self.assertNotIn("resultType", initialized)
        client.notify("notifications/initialized")
        self.assertEqual(client.request("ping")["result"], {})
        # The notification got no line: the ping reply was the second line.
        self.assertEqual(len(client.lines), 2, client.lines)
        save("mcp-legacy-handshake.json", [json.loads(line) for line in client.lines])

    # VAL-MCP-002
    def test_discover_and_per_request_meta(self):
        client = self.mcp()
        discovered = client.request("server/discover", {"_meta": MODERN})["result"]
        for key in ("resultType", "supportedVersions", "capabilities", "ttlMs", "cacheScope"):
            self.assertIn(key, discovered)
        self.assertIn("2026-07-28", discovered["supportedVersions"])
        listed = client.request("tools/list", {"_meta": MODERN})["result"]
        self.assertEqual(listed["resultType"], "complete")
        self.assertEqual(
            listed["_meta"]["io.modelcontextprotocol/serverInfo"]["name"], "barestate-mcp")
        missing = client.request("tools/list", {"_meta": {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28"}})["error"]
        self.assertEqual(missing["code"], -32602)
        unsupported = client.request("tools/list", {"_meta": {
            **MODERN, "io.modelcontextprotocol/protocolVersion": "1900-01-01"}})["error"]
        self.assertEqual(unsupported["code"], -32022)
        self.assertIn("2026-07-28", unsupported["data"]["supported"])
        save("mcp-discover.json", {"discover": discovered, "list": listed["_meta"],
                                   "missing": missing, "unsupported": unsupported})

    # VAL-MCP-003
    def test_tools_list_is_the_eight_tools_with_their_annotations(self):
        tools = self.mcp().request("tools/list")["result"]["tools"]
        self.assertEqual([t["name"] for t in tools], TOOLS)
        by_name = {t["name"]: t for t in tools}
        for name in TOOLS[:4]:
            self.assertTrue(by_name[name]["annotations"]["readOnlyHint"], name)
        for name in TOOLS[4:]:
            self.assertFalse(by_name[name]["annotations"]["readOnlyHint"], name)
        self.assertTrue(by_name["act"]["annotations"]["idempotentHint"])
        self.assertIn("clientActionId", by_name["act"]["inputSchema"]["required"])
        for tool in tools:
            self.assertEqual(tool["inputSchema"]["type"], "object", tool["name"])
        save("mcp-tools-list.json", tools)

    # VAL-MCP-004
    def test_read_tools_return_the_page(self):
        client = self.mcp()
        listed = data(client.tool("tabs"))["tabs"]
        mine = next(t for t in listed if t["id"] == self.tab)
        self.assertIn("act.html", mine["url"])
        self.assertEqual(mine["title"], "Act fixture")
        observation = data(client.tool("observe", tabId=self.tab))
        self.assertIn("Count", [e["name"] for e in observation["elements"]])
        self.assertTrue(all("ref" in e for e in observation["elements"]))
        extracted = client.tool("extract", tabId=self.tab)
        self.assertNotIn("isError", extracted)
        self.assertIn("Act fixture", json.dumps(extracted["structuredContent"]))
        missing = client.tool("action_status", clientActionId="nothing-here")
        self.assertTrue(missing.get("isError"), missing)

    # VAL-MCP-005
    def test_act_errors_are_tool_errors_and_act_is_idempotent(self):
        client = self.mcp()
        session = self.take_control(client)
        observation = data(client.tool("observe", tabId=self.tab))
        ref = self.ref(observation, "Count")
        base = {"observationId": observation["id"], "kind": "click", "ref": ref}

        missing = client.tool("act", **base)
        self.assertTrue(missing["isError"])
        self.assertIn("clientActionId", missing["content"][0]["text"])
        self.assertEqual(self.settled_clicks(0), [])

        first = client.tool("act", clientActionId="mcp-1", **base)
        self.assertNotIn("isError", first, first)
        second = client.tool("act", clientActionId="mcp-1", **base)
        row = data(first)
        self.assertEqual(data(second)["id"], row["id"])
        settled = data(client.tool("action_status", clientActionId="mcp-1"))
        self.assertEqual(settled["state"], "confirmed", settled)
        self.assertEqual(self.settled_clicks(1), ["count"])
        self.assertEqual(
            self.db("select count(*) from actions where session_id = ?", (session,)), [(1,)])

        self.assertTrue(client.tool("nope")["isError"])
        self.assertTrue(client.tool("observe", tabId="no-such-tab")["isError"])
        bad_ref = client.tool("act", clientActionId="mcp-ref", **{**base, "ref": 99999})
        self.assertTrue(bad_ref["isError"], bad_ref)
        stale = client.tool("act", clientActionId="mcp-stale", **{**base, "observationId": "old"})
        self.assertTrue(stale["isError"], stale)
        self.assertEqual(client.request("resources/list")["error"]["code"], -32601)
        self.assertIsNone(client.proc.poll())
        self.assertEqual(client.request("ping")["result"], {})
        save("mcp-act-errors.json", {"missing": missing, "bad_ref": bad_ref, "stale": stale})

    # VAL-MCP-007
    def test_stdout_is_only_json_one_line_each_and_stdin_eof_exits(self):
        client = self.mcp()
        observation = client.tool("observe", tabId=self.tab)
        client.send("")
        client.send("   ")
        self.assertEqual(client.request("ping")["result"], {})
        client.send("not json")
        self.assertEqual(json.loads(client.replies.get(timeout=10))["error"]["code"], -32700)
        client.send('[{"jsonrpc":"2.0","id":1,"method":"ping"}]')
        self.assertEqual(json.loads(client.replies.get(timeout=10))["error"]["code"], -32600)
        for line in client.lines:
            self.assertTrue(line.endswith(b"\n") and line.count(b"\n") == 1)
            self.assertEqual(json.loads(line)["jsonrpc"], "2.0")
        self.assertGreater(len(client.lines[0]), 500)
        code, seconds = client.close()
        self.assertEqual(code, 0)
        self.assertLess(seconds, 2)
        save("mcp-stdio-hygiene.json", {"lines": len(client.lines), "exit": code,
                                        "seconds": seconds, "observe": bool(observation)})

    def test_the_socket_and_environment_choose_the_app(self):
        sock = f"{self.app.data_dir}/app.sock"
        via_env = self.mcp(args=["--stdio"], env={"BARESTATE_SOCKET": sock})
        self.assertIn("tabs", via_env.request("tools/call", {"name": "tabs"})["result"]["structuredContent"])
        gone = self.mcp(args=["--socket", "/tmp/bs-no-such.sock"])
        error = gone.request("ping")["error"]
        self.assertIn("not running", error["message"])
        code, _ = gone.close()
        self.assertEqual(code, 0)

    def test_a_closed_app_socket_answers_every_owed_request_and_the_proxy_exits_cleanly(self):
        path = f"/tmp/bs-mcp-fake-{os.getpid()}.sock"
        self.addCleanup(lambda: os.path.exists(path) and os.unlink(path))
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(path)
        listener.listen(1)
        self.addCleanup(listener.close)
        client = self.mcp(args=["--socket", path])
        owed = [client.next_id() for _ in range(3)]
        for number in owed:
            client.send(json.dumps({"jsonrpc": "2.0", "id": number, "method": "tools/call",
                                    "params": {"name": "tabs"}}))
        connection, _ = listener.accept()
        reader = connection.makefile("rb")
        for _ in owed:
            reader.readline()
        reader.close()
        connection.close()  # three requests read, none answered
        errors = [json.loads(client.replies.get(timeout=10)) for _ in owed]
        self.assertEqual(sorted(reply["id"] for reply in errors), owed)
        for reply in errors:
            self.assertEqual(reply["error"]["code"], -32603, reply)
            self.assertIn("closed the connection", reply["error"]["message"])
        self.assertIsNone(client.proc.poll())
        listener.close()
        os.unlink(path)
        gone = client.request("ping")
        self.assertIn("not running", gone["error"]["message"])
        code, seconds = client.close()
        self.assertEqual((code, client.stderr_text()), (0, ""))
        self.assertLess(seconds, 3)

    def test_a_closed_stdout_ends_the_proxy_quietly_without_a_crash_report(self):
        def reports():
            return set(glob.glob(os.path.expanduser(
                "~/Library/Logs/DiagnosticReports/barestate-mcp*")))
        before = reports()
        with tempfile.TemporaryFile() as stderr:
            proc = subprocess.Popen([BINARY, "--socket", f"{self.app.data_dir}/app.sock"],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
            self.addCleanup(lambda: proc.poll() is None and proc.kill())
            proc.stdout.close()  # nobody reads the proxy's replies
            ping = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}).encode() + b"\n"
            proc.stdin.write(ping)
            proc.stdin.flush()
            self.assertEqual(proc.wait(timeout=10), 0)
            stderr.seek(0)
            self.assertEqual(stderr.read(), b"")
        proc.stdin.close()
        self.assertEqual(reports(), before)

    # VAL-MCP-008
    def test_the_documented_snippet_starts_and_answers_initialize(self):
        with open(os.path.join(bs.ROOT, "docs", "muse-code.md")) as source:
            blocks = re.findall(r"```json\n(.*?)```", source.read(), re.S)
        settings = next(json.loads(b) for b in blocks if "mcpServers" in b)
        self.assertEqual(settings["schema_version"], 1)
        server = settings["mcpServers"]["barestate"]
        self.assertEqual(server["type"], "stdio")
        sock = f"{self.app.data_dir}/app.sock"
        # The snippet names where a person puts the app; run the same bundled binary from the build.
        command = server["command"].replace("/Applications/Photon.app", bs.APP_BUNDLE)
        self.assertTrue(os.access(command, os.X_OK), command)
        client = Stdio(self.app.data_dir, args=server["args"], command=command,
                       env={"BARESTATE_SOCKET": sock, **server.get("env", {})})
        self.addCleanup(client.stop)
        answer = client.request("initialize", {"protocolVersion": "2025-06-18"})["result"]
        self.assertEqual(answer["serverInfo"]["name"], "barestate-mcp")
        self.assertEqual(client.close()[0], 0)


class McpControlCase(McpBase, PermBase):
    """VAL-MCP-006 and the sensitive path, on the permission fixture."""

    def test_nothing_lands_on_a_human_tab_until_the_person_allows_on_the_mac(self):
        client = self.mcp()
        observation = data(client.tool("observe", tabId=self.tab))
        base = {"observationId": observation["id"], "kind": "click",
                "ref": self.ref(observation, "Count")}

        refused = client.tool("act", clientActionId="h-1", **base)
        self.assertTrue(refused["isError"], refused)
        self.assertIn("not-in-control", json.dumps(refused))
        before = self.tabs_urls()
        navigated = client.tool("open_tab", tabId=self.tab, url="http://127.0.0.1:1/")
        self.assertTrue(navigated["isError"], navigated)
        self.assertIn("not-in-control", json.dumps(navigated))
        self.assertEqual(self.tabs_urls(), before)

        # Deny keeps the person in control.
        asked = data(client.tool("request_control", tabId=self.tab))
        self.assertEqual(asked["state"], "pending")
        self.assertEqual(self.holder(), None)
        # The socket's own methods are not reachable through the transport.
        for method, params in (("control.decide", {"requestId": asked["requestId"], "allow": True}),
                               ("approval.decide", {"approvalId": "x", "allow": True}),
                               ("open_tab", {"url": "file:///etc/hosts"}),
                               ("test.click", {"target": "approvalAllow"})):
            self.assertEqual(client.request(method, params)["error"]["code"], -32601, method)
        client.notify("control.decide", {"requestId": asked["requestId"], "allow": True})
        self.assertEqual(client.request("ping")["result"], {})
        self.assertIsNone(self.holder())
        self.assertEqual([a["kind"] for a in self.pending()], ["control"])
        self.wait_card()
        self.app.call("test.click", {"target": "approvalDeny"})
        self.assertTrue(client.tool("act", clientActionId="h-2", **base)["isError"])
        self.assertIsNone(self.holder())

        # Allow on the Mac card grants.
        asked = data(client.tool("request_control", tabId=self.tab))
        self.assertEqual(asked["state"], "pending")
        self.wait_card()
        save("mcp-control-card.json", self.ui()["approval"])
        self.app.call("test.click", {"target": "approvalAllow"})
        session = bs.wait_until(self.holder, what="the grant")
        self.assertTrue(session.startswith("mcp-"), session)
        self.assertEqual(data(client.tool("request_control", tabId=self.tab))["state"], "granted")

        # A sensitive act is quoted; the client follows it through action_status.
        sensitive = self.ref(observation, "Delete draft")
        quoted = data(client.tool("act", clientActionId="d-1", observationId=observation["id"],
                                  kind="click", ref=sensitive))
        self.assertEqual(quoted["state"], "quoted", quoted)
        self.assertNotIn("approvalTokenHash", json.dumps(quoted))
        self.assertEqual(self.status_text(), "Nothing deleted")
        self.wait_card()
        self.app.call("test.click", {"target": "approvalAllow"})
        done = bs.wait_until(
            lambda: (lambda s: s if s["state"] == "confirmed" else None)(
                data(client.tool("action_status", clientActionId="d-1"))), what="the delete")
        self.assertEqual(done["id"], quoted["id"])
        self.assertEqual(self.status_text(), "Draft deleted")

        handed = data(client.tool("handoff", tabId=self.tab))
        self.assertIsNone(self.holder(), handed)
        after = client.tool("act", clientActionId="h-3", **base)
        self.assertTrue(after["isError"], after)
        self.assertNotEqual(self.status_text(), "Counted 1")

    def test_a_tab_the_session_opens_is_its_own_to_act_on(self):
        client = self.mcp()
        before = set(self.tab_ids())
        opened = data(client.tool("open_tab", url=url("act.html")))
        self.assertNotIn(opened["id"], before)
        self.addCleanup(self.app.call, "test.activateTab", {"tabId": self.tab})
        self.addCleanup(self.app.call, "test.closeTab", {"tabId": opened["id"]})
        self.assertTrue(self.ui_tab(opened["id"])["controllerSession"].startswith("mcp-"))
        observation = data(client.tool("observe", tabId=opened["id"]))
        clicked = data(client.tool("act", clientActionId="o-1", observationId=observation["id"],
                                   kind="click", ref=self.ref(observation, "Count")))
        self.assertNotEqual(clicked["state"], "failed", clicked)
        self.assertTrue(client.tool("open_tab", url="file:///etc/hosts")["isError"])

    def tab_ids(self):
        return [t["id"] for t in self.app.call("tabs")["tabs"]]

    def tabs_urls(self):
        return {t["id"]: t["url"] for t in self.app.call("tabs")["tabs"]}
