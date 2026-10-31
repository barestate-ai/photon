"""barestate-gateway against a real app: VAL-REMOTE-001, 002, 003, 005, 006, 007 and the token store.

The gateway runs on 47850 (47851 for the one test that points it at a dead socket) with a made-up
public host, so no Funnel and no real tailnet name is involved.
"""
import hashlib
import http.client
import json
import os
import socket
import stat
import subprocess
import time

import bs
from test_core import LOG_DIR, save
from test_mcp import MODERN, TOOLS, data
from test_perm import PermBase

BINARY = os.path.join(bs.ROOT, ".build", "release", "barestate-gateway")
PHONE_DIR = os.path.join(bs.ROOT, "Resources", "phone")
PORT = 47850
PUBLIC_HOST = "phone.example.test:10000"
ROUTES = [("POST", "/mcp"), *[("POST", f"/api/{name}") for name in
                              ("task", "stop", "approve", "takeover", "disconnect")],
          ("GET", "/api/events")]
PING = {"jsonrpc": "2.0", "id": 1, "method": "ping"}
SECRET_FIELD = b"approvalTokenHash"


class Gateway:
    def __init__(self, data_dir, port=PORT, socket_name="app.sock"):
        self.port = port
        self.stderr = open(os.path.join(LOG_DIR, f"gateway-{port}.stderr.log"), "wb")
        self.proc = subprocess.Popen(
            [BINARY, "--port", str(port), "--socket", f"{data_dir}/{socket_name}",
             "--public-host", PUBLIC_HOST, "--phone-dir", PHONE_DIR],
            stdin=subprocess.DEVNULL, stderr=self.stderr)

    def request(self, method, path, token=None, host=None, headers=None, body=None, conn=None,
                timeout=10, stream=False):
        """Returns (status, headers, body); with stream=True the open (connection, response)."""
        conn = conn or http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        conn.putheader("Host", host or f"127.0.0.1:{self.port}")
        if token:
            conn.putheader("Authorization", f"Bearer {token}")
        for name, value in (headers or {}).items():
            conn.putheader(name, value)
        if body is not None:
            conn.putheader("Content-Length", str(len(body)))
        conn.endheaders(body)
        response = conn.getresponse()
        if stream:
            return conn, response
        payload = response.read()
        assert SECRET_FIELD not in payload, "a remote response carried approvalTokenHash"
        return response.status, response, payload

    def wait_ready(self):
        bs.wait_until(lambda: self.request("GET", "/__health")[0] == 200, what="gateway health")

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.stderr.close()


def files_containing(root, needle):
    found = []
    for folder, _, names in os.walk(root):
        for name in names:
            path = os.path.join(folder, name)
            if not os.path.isfile(path) or os.path.islink(path):
                continue
            with open(path, "rb") as source:
                if needle in source.read():
                    found.append(path)
    return found


def rpc(message, **extra):
    return json.dumps({"jsonrpc": "2.0", **message, **extra}).encode()


class GatewayCase(PermBase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.gateway = Gateway(cls.app.data_dir)
        cls.pairing = os.path.join(cls.app.data_dir, "pairing.json")
        try:
            cls.gateway.wait_ready()
        except BaseException:
            cls.gateway.stop()
            super().tearDownClass()
            raise

    @classmethod
    def tearDownClass(cls):
        cls.gateway.stop()
        super().tearDownClass()

    def pair(self, label="e2e"):
        return self.app.call("test.pairToken", {"label": label})["token"]

    def call(self, token, method, params=None, **extra):
        """One JSON-RPC request over POST /mcp; returns the parsed body."""
        message = {"id": 1, "method": method, **({"params": params} if params else {}), **extra}
        status, _, body = self.gateway.request("POST", "/mcp", token, body=rpc(message))
        self.assertEqual(status, 200, body)
        return json.loads(body)

    def tool(self, token, name, **arguments):
        reply = self.call(token, "tools/call", {"name": name, "arguments": arguments})
        self.assertNotIn("error", reply, reply)
        return reply["result"]

    def open_stream(self, token):
        conn, response = self.gateway.request("GET", "/api/events", token, stream=True)
        return conn, response

    # VAL-REMOTE-001
    def test_listens_on_loopback_only(self):
        out = subprocess.run(["lsof", "-nP", f"-iTCP:{PORT}", "-sTCP:LISTEN"],
                             capture_output=True, text=True).stdout.strip().splitlines()
        self.assertEqual(len(out) - 1, 1, out)
        self.assertIn(f"127.0.0.1:{PORT}", out[1])
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("192.0.2.1", 9))  # picks the outbound address; sends nothing
            lan = probe.getsockname()[0]
        except OSError:
            lan = None
        finally:
            probe.close()
        if lan and not lan.startswith("127."):
            with self.assertRaises(OSError):
                socket.create_connection((lan, PORT), timeout=3).close()
        save("gateway-binding.json", {"lsof": out, "lan": bool(lan)})

    # VAL-REMOTE-001
    def test_a_foreign_host_or_origin_is_refused_before_auth(self):
        token = self.pair()
        ping = rpc(PING)
        for host in (f"127.0.0.1:{PORT}", f"localhost:{PORT}", PUBLIC_HOST):
            status, _, body = self.gateway.request("POST", "/mcp", token, host=host, body=ping)
            self.assertEqual(status, 200, host)
        for host in ("evil.example", "127.0.0.1:9999", "127.0.0.1", PUBLIC_HOST.split(":")[0]):
            for credential in (token, None):
                status, _, body = self.gateway.request(
                    "POST", "/mcp", credential, host=host, body=ping)
                self.assertEqual((status, body), (403, b""), host)
        for origin in (f"http://127.0.0.1:{PORT}", f"https://{PUBLIC_HOST}"):
            status, _, _ = self.gateway.request(
                "POST", "/mcp", token, headers={"Origin": origin}, body=ping)
            self.assertEqual(status, 200, origin)
        for method, path in (("POST", "/mcp"), ("POST", "/api/task"), ("GET", "/api/events")):
            for credential in (token, None):
                status, _, body = self.gateway.request(
                    method, path, credential, headers={"Origin": "https://evil.example"},
                    body=ping if method == "POST" else None)
                self.assertEqual((status, body), (403, b""), (method, path))

    # VAL-REMOTE-002
    def test_every_route_wants_a_bearer_token(self):
        token = self.pair()
        credentials = {"none": {}, "bad": {"Authorization": "Bearer " + "0" * 64},
                       "basic": {"Authorization": "Basic dXNlcjpwYXNz"},
                       "bare": {"Authorization": "Bearer"}}
        matrix = {}
        for method, path in ROUTES:
            for name, headers in credentials.items():
                status, _, body = self.gateway.request(
                    method, path, headers=headers, body=b"{}" if method == "POST" else None)
                matrix[f"{method} {path} {name}"] = status
                self.assertEqual(status, 401, (method, path, name))
                self.assertEqual(body, b"")
            if method == "POST":
                status, _, _ = self.gateway.request(method, path, token, body=rpc(PING))
                expected = 200 if path == "/mcp" else 409
            else:
                conn, response = self.open_stream(token)
                status, expected = response.status, 200
                conn.close()
            matrix[f"{method} {path} valid"] = status
            self.assertEqual(status, expected, (method, path))
        save("gateway-auth-matrix.json", matrix)

    # VAL-REMOTE-003
    def test_nothing_private_is_returned_before_authentication(self):
        for page in ("kinds.html", "act.html"):
            opened = self.app.call("open_tab", {"url": f"{bs.FIXTURE_URL}/{page}", "activate": False})
            self.wait_loaded(f"{bs.FIXTURE_URL}/{page}", opened["id"])
        tabs = self.app.call("tabs")["tabs"]
        private = {t["url"] for t in tabs} | {t["title"] for t in tabs if t["title"]}
        private |= {"kinds.html", "act.html", str(bs.FIXTURE_PORT)}
        self.assertGreater(len(private), 3, private)
        self.addCleanup(lambda: [self.app.call("test.closeTab", {"tabId": t["id"]})
                                 for t in self.app.call("tabs")["tabs"] if t["id"] != self.tab])
        seen = []
        for method, path in ROUTES + [("GET", "/"), ("GET", "/__health"), ("GET", "/tabs"),
                                      ("GET", "/mcp"), ("GET", "/api/whatever")]:
            for headers in ({}, {"Authorization": "Bearer nope"}):
                status, response, body = self.gateway.request(
                    method, path, headers=headers, body=b"{}" if method == "POST" else None)
                seen.append((path, status, body, str(response.headers).encode()))
        for path, status, body, head in seen:
            for text in private:
                self.assertNotIn(text.encode(), body + head, (path, status, text))
        shell = next(body for path, status, body, _ in seen if path == "/" and status == 200)
        self.assertIn(b"<title>Photon</title>", shell)
        with open(os.path.join(PHONE_DIR, "index.html"), "rb") as source:
            self.assertEqual(shell, source.read())

    def test_the_phone_page_is_static_relative_and_locked_down(self):
        status, response, shell = self.gateway.request("GET", "/")
        self.assertEqual(status, 200)
        self.assertEqual(response.headers["Content-Type"], "text/html; charset=utf-8")
        policy = response.headers["Content-Security-Policy"]
        self.assertIn("script-src 'self'", policy)
        self.assertIn("connect-src 'self'", policy)
        self.assertEqual(response.headers["Referrer-Policy"], "no-referrer")
        for name, kind in (("app.css", "text/css"), ("app.js", "text/javascript"),
                           ("Manrope-Variable.ttf", "font/ttf")):
            status, response, body = self.gateway.request("GET", "/" + name)
            self.assertEqual((status, response.headers["Content-Type"].split(";")[0]), (200, kind))
            self.assertGreater(len(body), 100, name)
        script = self.gateway.request("GET", "/app.js")[2].decode()
        # EventSource cannot send Authorization; the token never goes into a URL.
        self.assertNotIn("EventSource", script)
        self.assertNotRegex(script, r"""fetch\(\s*["'`]?(/|https?:)""")
        self.assertNotIn("?t=", script)
        self.assertNotRegex(shell.decode(), r"""(src|href)=["'](/|https?:)""")
        for path in ("/Manrope-Variable.ttf/../x", "/..%2f..%2fetc/passwd", "/nope.js",
                     "/.DS_Store"):
            self.assertEqual(self.gateway.request("GET", path)[0], 404, path)
        self.assertEqual(self.gateway.request("POST", "/app.js", body=b"{}")[0], 405)

    # architecture §7, §8: the token store
    def test_pairing_stores_only_the_hash_of_a_32_byte_token(self):
        paired = self.app.call("test.pairToken", {"label": "Kitchen iPad"})
        token = paired["token"]
        self.assertRegex(token, r"^[0-9a-f]{64}$")
        self.assertNotEqual(self.pair(), token)
        self.assertEqual(stat.S_IMODE(os.stat(self.pairing).st_mode), 0o600)
        with open(self.pairing) as source:
            stored = json.load(source)["pairings"]
        mine = next(p for p in stored if p["label"] == "Kitchen iPad")
        self.assertEqual(sorted(mine), ["created", "hash", "label"])
        self.assertRegex(mine["hash"], r"^[0-9a-f]{64}$")
        self.assertEqual(mine["hash"], hashlib.sha256(token.encode()).hexdigest())
        self.assertEqual(mine["hash"], paired["hash"])
        self.call(token, "ping")
        for root in (self.app.data_dir, LOG_DIR):
            self.assertEqual(files_containing(root, token.encode()), [])

    # VAL-REMOTE-005
    def test_body_limit_and_rate_limit(self):
        first, second, burst = self.pair("one"), self.pair("two"), self.pair("three")
        padding = "a" * (1 << 20)
        status, _, body = self.gateway.request(
            "POST", "/mcp", first,
            body=rpc(PING, params={"pad": padding}), timeout=30)
        self.assertEqual(status, 200, body[:200])
        status, _, body = self.gateway.request(
            "POST", "/mcp", first, body=b" " * ((4 << 20) + 1), timeout=30)
        self.assertEqual((status, body), (413, b""))
        exact = rpc(PING, params={"pad": ""})
        exact += b" " * ((4 << 20) - len(exact))
        status, _, body = self.gateway.request("POST", "/mcp", second, body=exact, timeout=30)
        self.assertEqual(status, 200, body[:200])
        # Still alive after the oversized body.
        self.assertEqual(self.gateway.request("GET", "/__health")[0], 200)

        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
        started = time.time()
        codes = [self.gateway.request("POST", "/mcp", burst, body=rpc(PING), conn=conn)[0]
                 for _ in range(100)]
        elapsed = time.time() - started
        accepted, limited = codes.count(200), codes.count(429)
        self.assertEqual(accepted + limited, 100, set(codes))
        self.assertGreaterEqual(limited, 1)
        self.assertLessEqual(accepted, 30 + int(elapsed * 30) + 1, (accepted, elapsed))
        self.assertGreaterEqual(accepted, 30)
        # Another token has its own allowance, and the throttled one comes back.
        self.assertEqual(self.gateway.request("POST", "/mcp", first, body=rpc(PING))[0], 200)
        bs.wait_until(lambda: self.gateway.request(
            "POST", "/mcp", burst, body=rpc(PING))[0] == 200, timeout=5,
            what="the throttled token to recover")
        save("gateway-limits.json", {"accepted": accepted, "limited": limited,
                                     "seconds": round(elapsed, 3)})

    # VAL-REMOTE-006
    def test_eight_event_streams_at_most(self):
        token = self.pair()
        streams = [self.open_stream(token) for _ in range(8)]
        try:
            self.assertEqual([r.status for _, r in streams], [200] * 8)
            self.assertEqual(streams[0][1].getheader("Content-Type"), "text/event-stream")
            self.assertEqual(streams[0][1].fp.readline(), b": connected\n")
            status, _, _ = self.gateway.request("GET", "/api/events", token)
            self.assertEqual(status, 429)
            streams.pop()[0].close()
            conn, response = bs.wait_until(
                lambda: (lambda s: s if s[1].status == 200 else s[0].close())(
                    self.open_stream(token)), what="a freed session slot")
            streams.append((conn, response))
        finally:
            for conn, _ in streams:
                conn.close()

    def test_a_revoked_token_ends_its_stream(self):
        token = self.pair("short-lived")
        conn, response = self.open_stream(token)
        self.addCleanup(conn.close)
        mine = hashlib.sha256(token.encode()).hexdigest()
        with open(self.pairing) as source:
            stored = json.load(source)
        stored["pairings"] = [p for p in stored["pairings"] if p["hash"] != mine]
        with open(self.pairing, "w") as out:
            json.dump(stored, out)
        response.fp.raw._sock.settimeout(20)
        # The stream ends by itself within a keepalive tick or two of the revocation.
        self.assertTrue(response.read().startswith(b": connected"))

    # VAL-REMOTE-007
    def test_mcp_over_http_answers_as_stdio_does(self):
        token = self.pair()
        initialized = self.call(token, "initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "e2e", "version": "1"}})["result"]
        self.assertEqual(initialized["protocolVersion"], "2025-06-18")
        self.assertEqual(initialized["serverInfo"]["name"], "barestate-mcp")
        listed = self.call(token, "tools/list")["result"]["tools"]
        self.assertEqual([t["name"] for t in listed], TOOLS)
        tabs = data(self.tool(token, "tabs"))["tabs"]
        self.assertEqual([t["id"] for t in tabs], [t["id"] for t in self.app.call("tabs")["tabs"]])
        discovered = self.call(token, "server/discover", {"_meta": MODERN})["result"]
        self.assertEqual(discovered["resultType"], "complete")
        self.assertIn("2026-07-28", discovered["supportedVersions"])
        for method in ("GET", "DELETE"):
            status, response, body = self.gateway.request(method, "/mcp", token)
            self.assertEqual((status, body), (405, b""), method)
            self.assertEqual(response.getheader("Allow"), "POST")
        status, _, body = self.gateway.request(
            "POST", "/mcp", token, body=rpc({"method": "notifications/initialized"}))
        self.assertEqual((status, body), (202, b""))
        for method in ("approval.decide", "control.decide", "run.start", "test.click", "tabs"):
            self.assertEqual(self.call(token, method, {})["error"]["code"], -32601, method)
        self.assertEqual(self.call(token, "tools/call", {"name": "nope"})["result"]["isError"], True)
        status, _, body = self.gateway.request("POST", "/mcp", token, body=b"not json")
        self.assertEqual((status, json.loads(body)["error"]["code"]), (200, -32700))
        # Keep-alive: one connection carries several requests.
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
        for _ in range(3):
            self.assertEqual(self.gateway.request(
                "POST", "/mcp", token, body=rpc(PING), conn=conn)[0], 200)
        save("gateway-mcp.json", {"initialize": initialized, "tools": listed, "tabs": tabs})

    def test_the_gateway_names_the_session_not_the_client(self):
        token = self.pair()
        mine = "http-" + hashlib.sha256(token.encode()).hexdigest()[:8]
        opened = data(self.tool(token, "open_tab", url=f"{bs.FIXTURE_URL}/act.html",
                                _meta={"barestate/session": "mcp-spoofed"}))
        self.addCleanup(self.app.call, "test.closeTab", {"tabId": opened["id"]})
        self.assertEqual(self.ui_tab(opened["id"])["controllerSession"], mine)

    def test_a_sensitive_act_over_http_never_shows_the_approval_hash(self):
        token = self.pair()
        asked = data(self.tool(token, "request_control", tabId=self.tab))
        self.assertEqual(asked["state"], "pending", asked)
        self.assertEqual(self.app.call("control.decide", {
            "requestId": asked["requestId"], "allow": True})["state"], "granted")
        observation = data(self.tool(token, "observe", tabId=self.tab))
        quoted = data(self.tool(token, "act", clientActionId="remote-1",
                                observationId=observation["id"], kind="click",
                                ref=self.ref(observation, "Delete draft")))
        self.assertEqual(quoted["state"], "quoted", quoted)
        self.assertEqual(self.status_text(), "Nothing deleted")
        status = data(self.tool(token, "action_status", clientActionId="remote-1"))
        self.assertEqual(status["state"], "quoted")
        # The person's side of the same row: the local socket does not carry the hash either.
        session = self.holder()
        local = self.app.call("action_status", {"sessionId": session, "clientActionId": "remote-1"})
        self.assertNotIn("approvalTokenHash", local)
        pending = [a for a in self.pending() if a.get("actionId") == quoted["id"]]
        self.assertEqual(len(pending), 1)
        self.assertNotIn("approvalTokenHash", json.dumps(pending))
        self.app.call("approval.decide", {"approvalId": pending[0]["approvalId"], "allow": False})
        data(self.tool(token, "handoff", tabId=self.tab))

    def test_an_unreachable_app_is_a_bad_gateway_with_a_json_rpc_error(self):
        token = self.pair()
        lonely = Gateway(self.app.data_dir, port=PORT + 1, socket_name="none.sock")
        self.addCleanup(lonely.stop)
        lonely.wait_ready()
        status, _, body = lonely.request("POST", "/mcp", token, body=rpc(PING))
        self.assertEqual(status, 502)
        error = json.loads(body)
        self.assertEqual((error["id"], error["error"]["code"]), (1, -32603))

    def test_sessions_are_logged_without_secrets(self):
        token = self.pair()
        conn, _ = self.open_stream(token)
        log = os.path.join(self.app.data_dir, "logs", "photon.log")

        def text():
            with open(log) as source:
                return source.read()
        bs.wait_until(lambda: "gateway session open" in text(), what="the open event")
        conn.close()
        bs.wait_until(lambda: "gateway session close" in text(), what="the close event")
        self.assertIn("gateway listening port=47850", text())
        self.assertNotIn(token, text())
        self.assertNotIn("Authorization", text())

    def test_a_request_that_came_through_funnel_is_logged_as_such(self):
        token = self.pair()
        log = os.path.join(self.app.data_dir, "logs", "photon.log")

        def count():
            with open(log) as source:
                return source.read().count("gateway mcp via=funnel")
        self.assertEqual(self.gateway.request("POST", "/mcp", token, body=rpc(PING))[0], 200)
        self.assertEqual(count(), 0)
        self.assertEqual(self.gateway.request(
            "POST", "/mcp", token, body=rpc(PING),
            headers={"Tailscale-Funnel-Request": "?1"})[0], 200)
        bs.wait_until(lambda: count() == 1, what="the funnel line")

    def test_the_gateway_follows_photon_log_when_the_app_rotates_it(self):
        """The app moves photon.log to photon.log.1 and starts a new file; the gateway's next line
        belongs in the new one."""
        log = os.path.join(self.app.data_dir, "logs", "photon.log")
        os.rename(log, log + ".1")
        open(log, "w").close()
        conn, _ = self.open_stream(self.pair())
        self.addCleanup(conn.close)

        def text(path):
            with open(path) as source:
                return source.read()
        bs.wait_until(lambda: "gateway session open" in text(log), what="the line in the new file")
