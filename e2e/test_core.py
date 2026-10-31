"""Engine core: DevTools transport, observe, extract, human-input epochs, multi-tab."""
import json
import math
import os
import signal
import statistics
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlsplit

import bs

LOG_DIR = os.environ.get("BS_E2E_LOGDIR") or tempfile.mkdtemp(prefix="bs-e2e-logs-")
REPO_LOGS = os.path.join(bs.ROOT, ".logs")


def url(page):
    return f"{bs.FIXTURE_URL}/{page}"


def save(name, value):
    with open(os.path.join(LOG_DIR, name), "w") as out:
        json.dump(value, out, indent=2, sort_keys=True)


def stamped_before_page(app_ms, page_ms):
    """True when the app's fractional epoch ms is not later than the page's Date.now().

    Date.now() floors to whole ms, so a stamp taken earlier in that same millisecond is
    fractionally larger than the page's value yet still earlier; flooring the app stamp compares
    both at the page clock's resolution and still fails if the app stamped in a later millisecond.
    """
    return math.floor(app_ms) <= int(page_ms)


class StampOrderTests(unittest.TestCase):
    def test_a_stamp_earlier_in_the_pages_millisecond_is_not_later(self):
        self.assertTrue(stamped_before_page(1793219386779.2249, 1793219386779.0))

    def test_a_stamp_in_a_later_millisecond_is_later(self):
        self.assertFalse(stamped_before_page(1793219386780.0, 1793219386779.0))
        self.assertFalse(stamped_before_page(1793219386780.4, 1793219386779.0))


class CoreApp(unittest.TestCase):
    """One app per class, started on the observe fixture."""

    start_page = "observe.html"

    @classmethod
    def setUpClass(cls):
        cls.fixtures = bs.Fixtures(LOG_DIR).start()
        cls.log_mark = len(cls.fixtures.log())
        cls.app = bs.App(f"/tmp/bs-core-{os.getpid()}-{cls.__name__[:6]}", LOG_DIR,
                         label=cls.__name__, url=url(cls.start_page)).start()
        cls.tab = cls.wait_loaded(url(cls.start_page))["id"]

    @classmethod
    def tearDownClass(cls):
        cls.app.stop()

    @classmethod
    def wait_loaded(cls, page_url, tab_id=None):
        def ready():
            for tab in cls.app.call("tabs")["tabs"]:
                if (tab_id is None or tab["id"] == tab_id) and tab["url"] == page_url \
                        and not tab["loading"]:
                    return tab
        return bs.wait_until(ready, what=f"{page_url} loaded")

    def navigate(self, page, tab_id=None):
        tab_id = tab_id or self.tab
        self.app.call("test.devtools", {"tabId": tab_id, "method": "Page.navigate",
                                        "params": {"url": url(page)}})
        return self.wait_loaded(url(page), tab_id)

    def devtools(self, method, params=None, tab_id=None):
        return self.app.call("test.devtools", {"tabId": tab_id or self.tab, "method": method,
                                               "params": params or {}})

    def ui_tab(self, tab_id=None):
        tab_id = tab_id or self.tab
        return next(t for t in self.app.call("test.ui")["tabs"] if t["id"] == tab_id)

    def beacons(self, since):
        return [parse_qs(urlsplit(line.split()[1]).query)
                for line in self.fixtures.log(since) if "/__beacon?" in line]

    def wait_input_ready(self, since):
        """Waits for the fixture's beacon sent after load and a frame, before any synthetic input."""
        bs.wait_until(lambda: any(b.get("ready") == ["1"] for b in self.beacons(since)),
                      what="the page to be ready for input")


class DevToolsTransportTests(CoreApp):
    def test_g3_layout_metrics_reply_is_matched_by_id(self):
        metrics = self.devtools("Page.getLayoutMetrics")
        save("g3-getLayoutMetrics.json", metrics)
        for key in ("layoutViewport", "visualViewport", "cssContentSize"):
            self.assertIn(key, metrics)
        self.assertGreater(metrics["layoutViewport"]["clientWidth"], 0)
        self.assertGreater(metrics["visualViewport"]["clientHeight"], 0)
        self.assertGreater(metrics["cssContentSize"]["width"], 0)

    def test_concurrent_commands_each_get_their_own_result(self):
        rpc = self.app.rpc()
        try:
            calls = {
                1: ("Page.getLayoutMetrics", {}),
                2: ("Runtime.evaluate", {"expression": "1+1", "returnByValue": True}),
                3: ("Page.getNavigationHistory", {}),
                4: ("Nope.nope", {}),
                5: ("Runtime.evaluate", {"expression": "'a'+'b'", "returnByValue": True}),
            }
            for number, (method, params) in calls.items():
                rpc.send_line(json.dumps({"jsonrpc": "2.0", "id": number, "method": "test.devtools",
                                          "params": {"tabId": self.tab, "method": method,
                                                     "params": params}}).encode())
            replies = {}
            for _ in calls:
                reply = json.loads(rpc.read_line())
                replies[reply["id"]] = reply
        finally:
            rpc.close()
        save("concurrent-replies.json", replies)
        self.assertIn("cssContentSize", replies[1]["result"])
        self.assertEqual(replies[2]["result"]["result"]["value"], 2)
        self.assertIn("entries", replies[3]["result"])
        self.assertIn("error", replies[4])
        self.assertEqual(replies[5]["result"]["result"]["value"], "ab")
        for number in (1, 2, 3, 5):
            self.assertNotIn("error", replies[number])

    def test_navigation_events_reach_the_subscriber(self):
        self.devtools("Page.enable")
        before = self.app.call("test.events", {"tabId": self.tab})["next"]
        self.navigate("article.html")
        events = self.app.call("test.events", {"tabId": self.tab, "since": before})["events"]
        names = [event["method"] for event in events]
        save("navigation-events.json", names)
        self.assertIn("Page.frameNavigated", names)
        self.assertIn("Page.loadEventFired", names)


class ObserveTests(CoreApp):
    def observe(self, tab_id=None):
        return self.app.call("observe", {"tabId": tab_id or self.tab})

    def wait_viewport_follows_view(self):
        """The page's own viewport equals its live view's frame (points are CSS pixels)."""
        def follows():
            frame = next(t for t in self.app.call("test.ui")["tabs"] if t["id"] == self.tab)["frame"]
            seen = self.devtools("Runtime.evaluate", {"expression": "[innerWidth, innerHeight]",
                                                      "returnByValue": True})
            return seen["result"]["value"] == [frame["w"], frame["h"]]
        bs.wait_until(follows, what="the page viewport to follow its view")

    def named(self, observation, name):
        return next((e for e in observation["elements"] if e["name"] == name), None)

    def test_hostile_pages_cannot_misreport_visibility_or_crash_observe(self):
        self.navigate("edge.html")
        observation = self.observe()
        self.assertFalse(self.named(observation, "Veiled action")["interactive"])
        self.assertTrue(self.named(observation, "Continue")["sensitive"])
        self.assertFalse(self.named(observation, "Plain action")["sensitive"])
        self.assertRegex(observation["viewportKey"], r"@")

    def test_elements_and_keys(self):
        self.navigate("observe.html")
        observation = self.observe()
        save("observe-fixture.json", observation)
        for key in ("id", "tabId", "epoch", "url", "title", "documentKey", "viewportKey"):
            self.assertTrue(observation[key] != "" and observation[key] is not None, key)
        self.assertEqual(observation["tabId"], self.tab)
        self.assertEqual(observation["url"], url("observe.html"))
        self.assertEqual(observation["title"], "Observe fixture")
        self.assertRegex(observation["viewportKey"], r"^\d+,\d+,\d+x\d+@[\d.]+$")
        for name, role in (("Go", "button"), ("Full name", "textbox"), ("More details", "link")):
            element = self.named(observation, name)
            self.assertIsNotNone(element, name)
            self.assertEqual(element["role"], role)
            self.assertTrue(element["interactive"])
            self.assertIsInstance(element["ref"], int)
            self.assertGreater(element["bounds"]["w"], 0)
        self.assertFalse(self.named(observation, "Hidden action")["interactive"])
        self.assertFalse(self.named(observation, "Faded action")["interactive"])
        self.assertTrue(self.named(observation, "Password")["sensitive"])
        self.assertTrue(self.named(observation, "Place order")["sensitive"])
        self.assertFalse(self.named(observation, "Go")["sensitive"])
        refs = [e["ref"] for e in observation["elements"]]
        self.assertEqual(len(refs), len(set(refs)))

    def test_keys_track_navigation_scroll_and_resize(self):
        self.navigate("observe.html")
        self.wait_viewport_follows_view()
        first, again = self.observe(), self.observe()
        self.assertEqual(first["documentKey"], again["documentKey"])
        self.assertEqual(first["viewportKey"], again["viewportKey"])
        self.assertNotEqual(first["id"], again["id"])

        self.devtools("Runtime.evaluate", {"expression": "window.scrollTo(0, 120)"})
        scrolled = bs.wait_until(
            lambda: (o := self.observe())["viewportKey"] != first["viewportKey"] and o,
            what="viewportKey to change after scroll")
        self.assertEqual(scrolled["documentKey"], first["documentKey"])
        go_before, go_after = self.named(first, "Go"), self.named(scrolled, "Go")
        self.assertAlmostEqual(go_before["bounds"]["y"] - go_after["bounds"]["y"], 120, delta=1)

        self.devtools("Runtime.evaluate", {"expression": "window.scrollTo(0, 0)"})
        before_resize = bs.wait_until(
            lambda: (o := self.observe())["viewportKey"] == first["viewportKey"] and o,
            what="viewportKey to return after scrolling back")
        self.app.call("test.windowSize", {"w": 900, "h": 700})
        resized = bs.wait_until(
            lambda: (o := self.observe())["viewportKey"] != before_resize["viewportKey"] and o,
            what="viewportKey to change after resize")
        self.assertEqual(resized["documentKey"], first["documentKey"])
        self.wait_viewport_follows_view()
        self.app.call("test.windowSize", {"w": 1100, "h": 760})
        self.wait_viewport_follows_view()

        self.navigate("article.html")
        navigated = self.observe()
        self.assertNotEqual(navigated["documentKey"], first["documentKey"])
        save("observe-keys.json", {"first": first["documentKey"], "scrolled": scrolled["viewportKey"],
                                   "resized": resized["viewportKey"], "navigated": navigated["documentKey"]})

    def test_p50_under_150ms_on_a_page_with_100_elements(self):
        self.navigate("many.html")
        warm = self.observe()
        self.assertGreaterEqual(len(warm["elements"]), 100)
        samples = []
        for _ in range(30):
            started = time.perf_counter()
            self.observe()
            samples.append((time.perf_counter() - started) * 1000)
        result = {"page": "many.html", "elements": len(warm["elements"]), "samples": 30,
                  "p50_ms": statistics.median(samples),
                  "p95_ms": bs.nearest_rank(samples, 0.95), "max_ms": max(samples),
                  "latencies_ms": [round(s, 2) for s in samples]}
        os.makedirs(REPO_LOGS, exist_ok=True)
        with open(os.path.join(REPO_LOGS, "bench-observe.json"), "w") as out:
            json.dump(result, out, indent=2)
        save("bench-observe.json", result)
        self.assertLess(result["p50_ms"], 150, result)


class ExtractTests(CoreApp):
    def extract(self, **params):
        return self.app.call("extract", {"tabId": self.tab, **params})["content"]

    def ref_of(self, selector):
        root = self.devtools("DOM.getDocument")["root"]["nodeId"]
        node = self.devtools("DOM.querySelector", {"nodeId": root, "selector": selector})["nodeId"]
        return self.devtools("DOM.describeNode", {"nodeId": node})["node"]["backendNodeId"]

    def test_text_markdown_and_ref_scope(self):
        self.navigate("article.html")
        text = self.extract(format="text")
        markdown = self.extract(format="markdown")
        scoped = self.extract(format="text", ref=self.ref_of("#details"))
        save("extract.json", {"text": text, "markdown": markdown, "scoped": scoped})
        self.assertIn("Field Notes", text)
        self.assertIn("The quick brown fox jumps over the lazy dog.", text)
        self.assertNotIn("#", text)
        self.assertIn("# Field Notes", markdown.splitlines())
        self.assertIn(f"[observe fixture]({url('observe.html')})", markdown)
        self.assertIn("## Details", markdown.splitlines())
        self.assertIn("- first item", markdown.splitlines())
        self.assertIn("Only inside details.", scoped)
        self.assertIn("first item", scoped)
        self.assertNotIn("Unrelated footer text", scoped)
        self.assertNotIn("Field Notes", scoped)

    def test_unknown_ref_is_an_error(self):
        self.navigate("article.html")
        with self.assertRaises(bs.RpcError):
            self.extract(format="text", ref=987654)

    def test_bad_format_is_invalid_params(self):
        with self.assertRaises(bs.RpcError) as caught:
            self.extract(format="html")
        self.assertEqual(caught.exception.code, -32602)

    def test_extractor_runs_in_an_isolated_world(self):
        self.navigate("isolated.html")
        start = len(self.fixtures.log())
        self.assertIn("Page text the extractor reads.", self.extract(format="text"))
        # Defined in the extractor's world, so the page must never see it.
        self.app.call("test.isolatedEval", {"tabId": self.tab, "expression": "window.extractorMark = 1"})
        self.assertEqual(self.app.call("test.isolatedEval", {
            "tabId": self.tab, "expression": "typeof window.pageSecret"}), "undefined")
        self.assertEqual(self.app.call("test.isolatedEval", {
            "tabId": self.tab, "expression": "document.querySelector('h1').textContent"}),
            "Isolated world")
        self.devtools("Runtime.evaluate", {"expression": "report()"})
        keys = bs.wait_until(lambda: next(iter(self.beacons(start)), None), what="page-world probe")
        names = keys["keys"][0].split(",")
        save("isolated-world-probe.json", names)
        self.assertIn("pageSecret", names)
        self.assertNotIn("extractorMark", names)
        self.assertEqual(self.devtools("Runtime.evaluate", {
            "expression": "typeof window.extractorMark", "returnByValue": True})["result"]["value"],
            "undefined")


class HumanInputTests(CoreApp):
    start_page = "input.html"

    def setUp(self):
        self.wait_input_ready(self.log_mark)

    def test_click_and_key_bump_the_epoch_before_the_page_sees_them(self):
        start = len(self.fixtures.log())
        before = self.ui_tab()["epoch"]
        self.app.call("test.click", {"target": self.tab, "x": 60, "y": 100})
        click = bs.wait_until(lambda: [b for b in self.beacons(start) if b["ev"] == ["mousedown"]],
                              what="the page to see the mousedown")[0]
        after = self.ui_tab()
        self.assertEqual(after["epoch"], before + 1)
        self.assertEqual(after["controller"], "human")
        self.assertTrue(stamped_before_page(after["lastHumanInputMs"], float(click["t"][0])), (after, click))

        key_start = len(self.fixtures.log())
        self.app.call("test.key", {"key": "a"})
        key = bs.wait_until(lambda: [b for b in self.beacons(key_start) if b["ev"] == ["keydown"]],
                            what="the page to see the keydown")[0]
        after_key = self.ui_tab()
        self.assertEqual(after_key["epoch"], before + 2)
        self.assertTrue(stamped_before_page(after_key["lastHumanInputMs"], float(key["t"][0])), (after_key, key))
        save("epoch.json", {"before": before, "afterClick": after["epoch"], "afterKey": after_key["epoch"]})

    def test_typing_bumps_once_per_key(self):
        self.app.call("test.click", {"target": self.tab, "x": 60, "y": 100})
        before = self.ui_tab()["epoch"]
        self.app.call("test.type", {"text": "hi"})
        self.assertEqual(self.ui_tab()["epoch"], before + 2)

    def test_synthetic_keys_return_once_dispatched_not_after_the_3s_timeout(self):
        # On a locked screen AppKit hands posted events back with their timestamps cut to ns.
        started = time.perf_counter()
        self.app.call("test.key", {"key": "a"})
        self.app.call("test.type", {"text": "hi"})
        self.assertLess(time.perf_counter() - started, 1.5)

    def test_input_outside_a_tab_leaves_the_epoch_alone(self):
        before = self.ui_tab()["epoch"]
        self.app.call("test.click", {"target": "commandButton"})
        self.assertEqual(self.ui_tab()["epoch"], before)
        self.app.call("test.key", {"key": "Escape"})

    def test_hidden_tab_cannot_be_clicked(self):
        other = self.app.call("open_tab", {"url": url("input.html"), "activate": False})["id"]
        with self.assertRaises(bs.RpcError):
            self.app.call("test.click", {"target": other})
        self.app.call("test.closeTab", {"tabId": other})


class MultiTabTests(CoreApp):
    def visible(self):
        return sorted(t["id"] for t in self.app.call("test.ui")["tabs"] if t["visible"])

    def test_only_the_active_tab_is_visible_and_nothing_is_recreated(self):
        second = self.app.call("open_tab", {"url": url("article.html"), "activate": False})["id"]
        third = self.app.call("open_tab", {"url": url("many.html")})["id"]
        self.wait_loaded(url("article.html"), second)
        self.wait_loaded(url("many.html"), third)
        ui = self.app.call("test.ui")
        self.assertEqual(ui["activeTabId"], third)
        self.assertEqual(self.visible(), [third])
        frames = {t["id"]: t["frame"] for t in ui["tabs"]}
        self.assertEqual(len({json.dumps(f, sort_keys=True) for f in frames.values()}), 1)

        self.app.call("test.activateTab", {"tabId": self.tab})
        self.assertEqual(self.visible(), [self.tab])
        self.assertEqual(self.app.call("observe", {"tabId": second})["title"], "Article fixture")
        self.assertEqual(self.app.call("test.ui")["firstResponder"]["tabId"], self.tab)
        for tab_id in (second, third):
            self.app.call("test.closeTab", {"tabId": tab_id})

    def test_closing_tabs_among_several_does_not_hang(self):
        ids = [self.tab] + [self.app.call("open_tab", {"url": url("article.html")})["id"]
                            for _ in range(3)]
        for tab_id in ids[1:]:
            self.wait_loaded(url("article.html"), tab_id)
        started = time.monotonic()
        self.app.call("test.closeTab", {"tabId": ids[2]})
        self.app.call("test.closeTab", {"tabId": ids[3]})
        self.assertEqual(self.app.status()["tabs"], 2)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(self.app.call("test.ui")["activeTabId"], ids[1])
        self.assertEqual(self.visible(), [ids[1]])
        self.assertEqual(self.app.call("observe", {"tabId": ids[1]})["title"], "Article fixture")
        self.app.call("test.closeTab", {"tabId": ids[1]})

    def test_a_tab_the_page_closes_leaves_the_tab_list_and_quit_still_works(self):
        app = bs.App(f"/tmp/bs-core-{os.getpid()}-pageclose", LOG_DIR, label="pageclose",
                     url=url("article.html")).start()
        try:
            second = app.call("open_tab", {"url": url("observe.html")})["id"]
            bs.wait_until(lambda: any(t["id"] == second and not t["loading"]
                                      for t in app.call("tabs")["tabs"]), what="second tab loaded")
            app.call("test.devtools", {"tabId": second, "method": "Page.close"})
            bs.wait_until(lambda: [t["id"] for t in app.call("tabs")["tabs"]] == ["t1"],
                          what="the closed tab to leave the list")
            self.assertEqual(app.call("test.ui")["activeTabId"], "t1")
            os.kill(app.proc.pid, signal.SIGTERM)
            self.assertEqual(app.proc.wait(timeout=15), 0)
        finally:
            app.stop()

    def test_quit_with_several_tabs_exits_cleanly(self):
        app = bs.App(f"/tmp/bs-core-{os.getpid()}-quit", LOG_DIR, label="quit", url=url("article.html")).start()
        try:
            for _ in range(2):
                app.call("open_tab", {"url": url("observe.html")})
            os.kill(app.proc.pid, signal.SIGTERM)
            self.assertEqual(app.proc.wait(timeout=15), 0)
        finally:
            app.stop()

    def test_new_tab_starts_at_epoch_zero_with_human_control(self):
        tab = self.app.call("open_tab", {"url": url("article.html")})["id"]
        ui = next(t for t in self.app.call("test.ui")["tabs"] if t["id"] == tab)
        self.assertEqual((ui["epoch"], ui["controller"]), (0, "human"))
        self.app.call("test.closeTab", {"tabId": tab})


if __name__ == "__main__":
    unittest.main()
