"""The ⌘T launcher: entry points, focus, ranking, keyboard, background lock, actions, visuals."""
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import time
import unittest
from urllib.parse import parse_qs, quote, urlsplit

import bs
from appcase import LOG_DIR, AppCase, save, url

KYOTO = "Find a quiet hotel in Kyoto under $200 a night"
SEARCH_ENGINE = f"{bs.FIXTURE_URL}/index.html?q=%s"


def titled(title):
    return url(f"launcher.html?t={quote(title)}")


class LauncherCase(AppCase):
    """One app per class. Search goes to the fixture server, so choosing it needs no network.

    The app has a placeholder key and its Muse provider is a local server that answers 404, so
    Start task commits a run and no request reaches the real provider (`app_env` is what a class
    changes to test the unavailable cases)."""

    start_url = None

    @classmethod
    def setUpClass(cls):
        cls.fixtures = bs.Fixtures(LOG_DIR).start()
        cls.data_dir = f"/tmp/bs-lau-{os.getpid()}-{cls.__name__[:10]}"
        os.makedirs(cls.data_dir, exist_ok=True)
        with open(os.path.join(cls.data_dir, "settings.json"), "w") as out:
            json.dump({"searchEngine": SEARCH_ENGINE}, out)
        cls.provider = bs.DeadHost().start()
        cls.app = bs.App(
            cls.data_dir, LOG_DIR, label=cls.__name__, env=cls.app_env()).start(fresh=False)

    @classmethod
    def app_env(cls):
        # A live session keeps its real key, as the live tests need.
        return {} if os.environ.get("BARESTATE_LIVE_META") == "1" else bs.provider_env(cls.provider.url)

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        cls.provider.stop()

    def setUp(self):
        self.fresh()

    # State and navigation.

    def launcher(self):
        return self.ui()["launcher"]

    def responder(self):
        return self.ui()["firstResponder"].get("chromeId")

    def signature(self, rows=None):
        rows = self.launcher()["rows"] if rows is None else rows
        return [(r["kind"], r["title"], r["subtitle"], r["actionLabel"]) for r in rows]

    def ids(self):
        return [r["id"] for r in self.launcher()["rows"]]

    def active(self):
        return self.launcher()["active"]

    def open_launcher(self):
        self.key("t", "cmd")
        return bs.wait_until(lambda: (lambda s: s if s["launcher"]["open"]
                                      and s["firstResponder"].get("chromeId") == "launcherField"
                                      else None)(self.ui()), what="the launcher open").get("launcher")

    def close_launcher(self):
        if self.launcher()["open"]:
            self.key("Escape")
            bs.wait_until(lambda: not self.launcher()["open"], what="the launcher closed")

    def type_text(self, text):
        self.call("test.type", {"text": text})
        return bs.wait_until(
            lambda: (lambda s: s if s["current"] and s["query"] == text else None)(self.launcher()),
            what=f"rows for {text!r}")

    def clear_field(self):
        self.key("a", "cmd")
        self.key("Backspace")
        bs.wait_until(lambda: (lambda s: s["current"] and s["query"] == "")(self.launcher()),
                      what="an empty query")

    def retype(self, text):
        self.clear_field()
        return self.type_text(text) if text else self.launcher()

    def fresh(self):
        self.close_launcher()
        self.call("test.modelOffline", {"on": False})
        self.call("test.windowSize", {"w": 1440, "h": 900})
        blank = self.call("open_tab", {"url": "about:blank"})["id"]
        for tab_id in self.tab_ids():
            if tab_id != blank:
                self.call("test.closeTab", {"tabId": tab_id})
        self.call("test.activateTab", {"tabId": blank})
        self.clear_field_text()
        self.runs_before = len(self.runs())

    def clear_field_text(self):
        self.open_launcher()
        self.clear_field()
        self.close_launcher()

    def seed(self, tabs=(), history=(), bookmarks=()):
        """Tabs are fixture pages titled by the first element of each pair."""
        ids = self.call("test.seed", {
            "tabs": [titled(title) for title in tabs],
            "history": [{"url": u, "title": t} for u, t in history],
            "bookmarks": [{"url": u, "title": t} for u, t in bookmarks],
        })["tabIds"]
        for tab_id, title in zip(ids, tabs):
            bs.wait_until(lambda: any(t["id"] == tab_id and t["title"] == title
                                      for t in self.tabs()), what=f"tab {title!r}")
        return ids

    def move_to(self, row):
        for _ in self.ids():
            if self.active() == row["id"]:
                return
            self.key("ArrowDown")
        self.assertEqual(self.active(), row["id"])

    def requests(self):
        return len(self.fixtures.log())

    def snapshot(self):
        return {"tabs": [(t["id"], t["url"]) for t in self.tabs()], "active": self.active_id(),
                "requests": self.requests()}

    def db(self, sql):
        with sqlite3.connect(os.path.join(self.data_dir, "barestate.sqlite")) as conn:
            return conn.execute(sql).fetchall()

    def runs(self):
        return self.call("run.list")["runs"]

    def new_runs(self):
        return self.runs()[self.runs_before:]


class EntryPointTests(LauncherCase):
    def test_every_entry_point_opens_one_launcher_without_making_a_tab(self):
        """VAL-LAUNCH-001, VAL-TABS-004"""
        report = {}

        def check(name, act):
            before = self.tab_ids()
            act()
            state = bs.wait_until(
                lambda: (lambda s: s if s["launcher"]["open"]
                         and s["firstResponder"].get("chromeId") == "launcherField" else None)(self.ui()),
                what=f"{name}: launcher open")
            report[name] = {"launcher": state["launcher"]["frame"], "tabs": len(self.tab_ids())}
            self.assertEqual(self.tab_ids(), before, name)
            self.assertEqual(self.launcher()["frame"]["w"], 760)
            self.close_launcher()

        check("cmd+t on an empty New Tab", lambda: self.key("t", "cmd"))
        check("command button", lambda: self.call("test.click", {"target": "commandButton"}))
        check("cmd+l", lambda: self.key("l", "cmd"))
        self.call("test.closeTab", {"tabId": self.tab_ids()[0]})
        only = self.call("open_tab", {"url": "about:blank"})["id"]
        for tab_id in self.tab_ids():
            if tab_id != only:
                self.call("test.closeTab", {"tabId": tab_id})
        self.key("w", "cmd")
        bs.wait_until(lambda: len(self.tab_ids()) == 1 and self.tab_ids() != [only],
                      what="the replacement blank tab")
        check("cmd+t with every tab closed", lambda: self.key("t", "cmd"))
        save("launcher-entry-points.json", report)
        self.assertEqual(len(report), 4)

    def test_cmd_t_on_a_loaded_page_keeps_the_page(self):
        """VAL-LAUNCH-001"""
        self.open_page("launcher.html")
        before = self.snapshot()
        self.open_launcher()
        self.assertEqual(self.snapshot(), before)
        self.close_launcher()

    def test_a_second_cmd_t_keeps_one_launcher(self):
        """VAL-LAUNCH-010"""
        self.open_launcher()
        self.type_text("abc")
        frame = self.launcher()["frame"]
        self.key("t", "cmd")
        state = self.launcher()
        self.assertTrue(state["open"])
        self.assertEqual((state["query"], state["frame"]), ("abc", frame))
        self.assertEqual(self.responder(), "launcherField")


class FocusTests(LauncherCase):
    def test_escape_returns_focus_to_the_page(self):
        """VAL-LAUNCH-002"""
        page = self.open_page("launcher.html")
        bs.wait_until(lambda: self.ui()["firstResponder"].get("tabId") == page["id"],
                      what="the page to hold focus")
        before = self.snapshot()
        self.open_launcher()
        self.type_text("partial")
        self.key("Escape")
        bs.wait_until(lambda: not self.launcher()["open"], what="closed")
        self.assertEqual(self.ui()["firstResponder"].get("tabId"), page["id"])
        self.assertEqual(self.snapshot(), before)

    def test_unfinished_input_survives_escape_and_a_commit_clears_it(self):
        """VAL-LAUNCH-003"""
        self.open_launcher()
        self.type_text("partial que")
        self.key("Escape")
        bs.wait_until(lambda: not self.launcher()["open"], what="closed")
        state = self.open_launcher()
        self.assertEqual((state["query"], state["fieldText"]), ("partial que", "partial que"))
        bs.wait_until(lambda: self.launcher()["current"], what="rows")
        self.assertEqual(self.launcher()["rows"][0]["kind"], "search")
        self.key("Return")
        bs.wait_until(lambda: not self.launcher()["open"], what="closed after a commit")
        state = self.open_launcher()
        self.assertEqual((state["query"], state["fieldText"]), ("", ""))

    def test_a_click_outside_dismisses_and_keeps_the_query(self):
        """VAL-LAUNCH-010"""
        page = self.open_page("launcher.html")
        self.open_launcher()
        self.type_text("keepme")
        counters = self.evaluate("[window.__keys, window.__pointer]")
        requests = self.requests()
        reply = self.call("test.click", {"target": page["id"], "x": 20, "y": 500})
        self.assertEqual(reply["hit"], "LauncherView")
        bs.wait_until(lambda: not self.launcher()["open"], what="dismissed")
        self.assertEqual(self.requests(), requests)
        self.assertEqual(self.evaluate("[window.__keys, window.__pointer]"), counters)
        self.assertEqual(self.open_launcher()["query"], "keepme")


class RankingTests(LauncherCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.sites = [
            (url("index.html?s=h1"), "Kyoto temples guide"),
            (url("index.html?s=h2"), "Osaka street food"),
            (url("index.html?s=h3"), "Hotel prices in Kyoto"),
        ]
        cls.marks = [(url("index.html?s=b1"), "Kyoto bookmark"), (url("index.html?s=b2"), "Taxes")]

    def seeded(self):
        self.seed(tabs=("Kyoto trip", "Places to stay", "Weekend reading"),
                  history=self.sites, bookmarks=self.marks)

    def test_empty_query_shows_continue_suggested_and_browser_and_never_runs_a_task(self):
        """VAL-LAUNCH-004"""
        self.seeded()
        self.open_launcher()
        state = bs.wait_until(lambda: self.launcher()["current"] and len(self.launcher()["rows"]) > 3
                              and self.launcher(), what="empty-query rows")
        save("launcher-empty-rows.json", state["rows"])
        self.assertEqual([(s["title"], len(s["rows"])) for s in state["sections"]],
                         [("Continue", 3), ("Suggested", 3), ("Browser", 2)])
        rows = state["rows"]
        self.assertEqual({r["title"] for r in rows[:3]},
                         {"Kyoto trip", "Places to stay", "Weekend reading"})
        self.assertEqual({r["subtitle"] for r in rows[:3]}, {"Switch to open page"})
        self.assertEqual({r["kind"] for r in rows[:3]}, {"switchTab"})
        current = rows[0]["title"]
        self.assertEqual([(r["title"], r["subtitle"]) for r in rows[3:]], [
            (f"Summarize {current}", "Start a task with Muse"),
            ("Compare the pages I have open", "Start a task with Muse"),
            ("Find something on the web", "Web search"),
            ("History", "Find a page you visited"),
            ("Settings", "Manage browser preferences")])
        self.assertEqual(state["active"], rows[0]["id"])
        self.assertEqual([r["id"] for r in rows if r["hint"]], [rows[0]["id"]])
        self.assertEqual(state["footer"]["origin"], urlsplit(self.tab_url(self.active_id())).netloc)
        self.assertEqual(self.new_runs(), [])
        self.call("test.screenshot", {"path": os.path.join(LOG_DIR, "launcher-empty.png")})

    def page_title(self, tab_id):
        return next(t["title"] for t in self.tabs() if t["id"] == tab_id)

    def tab_url(self, tab_id):
        return next(t["url"] for t in self.tabs() if t["id"] == tab_id)

    def test_suggestions_follow_the_open_pages(self):
        """VAL-LAUNCH-013"""
        self.open_launcher()
        state = bs.wait_until(lambda: self.launcher()["current"] and self.launcher(), what="rows")
        self.assertEqual([r["title"] for r in state["rows"] if r["kind"] != "run"],
                         ["Find something on the web", "History", "Settings"])
        self.close_launcher()
        self.seed(tabs=("Solo page",))
        self.open_launcher()
        titles = [r["title"] for r in bs.wait_until(
            lambda: self.launcher()["current"] and self.launcher(), what="rows")["rows"]
            if r["kind"] != "run"]
        self.assertEqual(titles, ["Solo page", "Summarize Solo page", "Find something on the web",
                                  "History", "Settings"])
        self.close_launcher()
        self.seed(tabs=("Second page",))
        self.open_launcher()
        rows = self.launcher()["rows"]
        self.assertEqual([r["title"] for r in rows if r["section"] == "Suggested"][1:2],
                         ["Compare the pages I have open"])
        self.assertEqual(self.new_runs(), [])

    def test_summarize_and_compare_start_runs_that_name_the_pages(self):
        """VAL-LAUNCH-013"""
        first, second = self.seed(tabs=("Alpha stays", "Beta stays"))
        self.call("test.activateTab", {"tabId": second})
        self.open_launcher()
        bs.wait_until(lambda: self.launcher()["current"], what="rows")
        summarize = next(r for r in self.launcher()["rows"] if r["title"].startswith("Summarize"))
        self.assertEqual(summarize["title"], "Summarize Beta stays")
        self.call("test.click", {"target": f"launcherRow:{summarize['id']}"})
        bs.wait_until(lambda: len(self.new_runs()) == 1, what="the summarize run")
        run = self.new_runs()[0]
        self.assertIn("Beta stays", run["prompt"])
        self.assertEqual(run["tabId"], second)
        self.open_launcher()
        bs.wait_until(lambda: self.launcher()["current"], what="rows")
        compare = next(r for r in self.launcher()["rows"] if r["title"].startswith("Compare"))
        self.call("test.click", {"target": f"launcherRow:{compare['id']}"})
        bs.wait_until(lambda: len(self.new_runs()) == 2, what="the compare run")
        prompt = self.new_runs()[1]["prompt"]
        self.assertIn("Alpha stays", prompt)
        self.assertIn("Beta stays", prompt)

    def test_find_something_on_the_web_keeps_the_launcher_open_in_web_search_mode(self):
        """VAL-LAUNCH-014"""
        self.seed(tabs=("Alpha",))
        self.open_launcher()
        bs.wait_until(lambda: self.launcher()["current"], what="rows")
        find = next(r for r in self.launcher()["rows"] if r["title"] == "Find something on the web")
        tabs = self.tab_ids()
        self.call("test.click", {"target": f"launcherRow:{find['id']}"})
        state = bs.wait_until(lambda: (lambda s: s if s["open"] and s["scope"] == "web"
                                       and s["current"] else None)(self.launcher()), what="web mode")
        self.assertEqual(state["placeholder"], "Search the web")
        self.assertEqual(self.responder(), "launcherField")
        self.assertEqual(self.new_runs(), [])
        self.type_text("quiet hotels")
        self.assertEqual([r["kind"] for r in self.launcher()["rows"]], ["search"])
        self.key("Return")
        tab = bs.wait_until(lambda: [t for t in self.tabs() if t["id"] not in tabs],
                            what="the search tab")[0]
        self.assertEqual(parse_qs(urlsplit(tab["url"]).query)["q"], ["quiet hotels"])
        self.assertEqual(self.new_runs(), [])

    def test_history_scope_lists_visited_pages_and_escape_closes(self):
        """VAL-LAUNCH-015"""
        self.seed(history=[(url("index.html?s=old"), "Older visit"),
                           (url("index.html?s=new"), "Newer visit")], tabs=("Open page",))
        self.open_launcher()
        bs.wait_until(lambda: self.launcher()["current"], what="rows")
        row = next(r for r in self.launcher()["rows"] if r["title"] == "History")
        self.call("test.click", {"target": f"launcherRow:{row['id']}"})
        state = bs.wait_until(lambda: (lambda s: s if s["open"] and s["scope"] == "history"
                                       and s["current"] else None)(self.launcher()), what="history")
        self.assertEqual((state["fieldText"], state["placeholder"]), ("", "Search your history"))
        titles = [r["title"] for r in state["rows"]]
        self.assertTrue(set(titles) >= {"Older visit", "Newer visit"}, titles)
        self.assertTrue(all(r["kind"] == "history" for r in state["rows"]))
        self.assertLess(titles.index("Newer visit"), titles.index("Older visit"))
        self.type_text("older")
        self.assertEqual([r["title"] for r in self.launcher()["rows"]], ["Older visit"])
        tabs = self.tab_ids()
        self.key("Return")
        tab = bs.wait_until(lambda: [t for t in self.tabs() if t["id"] not in tabs],
                            what="the history tab")[0]
        self.assertTrue(tab["url"].endswith("s=old"))
        self.open_launcher()
        bs.wait_until(lambda: self.launcher()["current"], what="rows")
        row = next(r for r in self.launcher()["rows"] if r["title"] == "History")
        self.call("test.click", {"target": f"launcherRow:{row['id']}"})
        bs.wait_until(lambda: self.launcher()["scope"] == "history", what="history")
        self.key("Escape")
        bs.wait_until(lambda: not self.launcher()["open"], what="closed by one Escape")

    def test_settings_row_opens_one_window(self):
        """VAL-LAUNCH-015"""
        self.open_launcher()
        bs.wait_until(lambda: self.launcher()["current"], what="rows")
        row = next(r for r in self.launcher()["rows"] if r["title"] == "Settings")
        before = self.ui()["settings"].get("closes", 0)
        self.call("test.click", {"target": f"launcherRow:{row['id']}"})
        bs.wait_until(lambda: self.ui()["settings"]["open"], what="Settings")
        self.assertFalse(self.launcher()["open"])
        self.key("w", "cmd")
        bs.wait_until(lambda: self.ui()["settings"].get("closes", 0) == before + 1, what="Settings closed")

    def test_suggestions_come_from_every_local_source_and_need_no_network(self):
        """VAL-LAUNCH-005"""
        self.seeded()
        self.call("test.modelOffline", {"on": True})
        self.open_launcher()
        pid = self.app.proc.pid
        before = self.connections(pid)
        requests = self.requests()
        shown = []
        for prefix in ("k", "ky", "kyo"):
            self.retype(prefix)
            titles = [r["title"] for r in self.launcher()["rows"] if r["kind"] != "search"
                      and r["kind"] != "startTask"]
            shown.append(titles)
            self.assertIn("Kyoto trip", titles, prefix)
            if len(prefix) > 1:
                self.assertNotIn("Places to stay", titles)
                self.assertNotIn("Weekend reading", titles)
        kinds = {r["kind"] for r in self.launcher()["rows"]}
        self.assertTrue({"switchTab", "history", "bookmark"} <= kinds, kinds)
        self.retype("taxes")
        self.assertEqual(self.first_site()["kind"], "bookmark")
        self.retype("osaka")
        self.assertEqual(self.first_site()["kind"], "history")
        self.clear_field()
        empty = self.launcher()
        self.assertEqual([r for r in empty["rows"] if r["kind"] != "run"][0]["kind"], "switchTab")
        self.assertNotIn("For this request", [r["section"] for r in empty["rows"]])
        for _ in range(10):
            self.retype("kyoto hotels in the old town of kyoto and more characters")
        self.assertEqual(self.requests(), requests)
        self.assertEqual(self.new_runs(), [])
        self.assertEqual(self.connections(pid) - before, set())
        save("launcher-local-sources.json", {"shown": shown, "connections": sorted(before)})

    def first_site(self):
        return next(r for r in self.launcher()["rows"]
                    if r["kind"] not in ("search", "startTask", "openURL", "retry"))

    def connections(self, pid):
        out = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-i"], capture_output=True,
                             text=True).stdout
        found = set()
        for line in out.splitlines()[1:]:
            match = re.search(r"->(\S+)", line)
            if match and not match.group(1).startswith(("127.0.0.1", "[::1]", "localhost")):
                found.add(match.group(1))
        self.assertFalse([c for c in found if "meta.ai" in c], found)
        return found

    def test_ranking_is_deterministic_and_late_results_are_dropped(self):
        """VAL-LAUNCH-006"""
        self.seeded()
        queries = ["kyoto", "k", "stay", "weekend", "hotel kyoto", "example.com", "o", "food",
                   "kyoto hotels", KYOTO]
        self.open_launcher()
        first = {}
        for repetition in range(20):
            for query in queries:
                self.retype(query)
                got = self.ids()
                if repetition == 0:
                    first[query] = got
                self.assertEqual(got, first[query], (repetition, query))
        digest = hashlib.sha256(json.dumps(first, sort_keys=True).encode()).hexdigest()
        save("launcher-ranking-hash.json", {"hash": digest, "queries": first})

        self.clear_field()
        self.call("test.type", {"text": "kyo"})
        bs.wait_until(lambda: self.launcher()["current"], what="rows")
        fast = self.ids()
        self.clear_field()
        self.type_text("kyo")
        self.assertEqual(self.ids(), fast)

        self.retype("kyoto")
        self.key("ArrowDown")
        chosen = self.active()
        rows_before = self.ids()
        self.call("test.seed", {"history": [{"url": url("index.html?s=late"),
                                              "title": "Late kyoto arrival"}]})
        bs.wait_until(lambda: len(self.ids()) > len(rows_before), what="the late row")
        self.assertEqual(self.active(), chosen)
        kind = chosen.split(":", 1)[0]
        tabs_before = len(self.tab_ids())
        self.key("Return")
        bs.wait_until(lambda: not self.launcher()["open"], what="closed")
        if kind in ("search", "openURL", "history", "bookmark"):
            self.assertEqual(len(self.tab_ids()), tabs_before + 1)
        elif kind == "startTask":
            self.assertEqual(len(self.new_runs()), 1)

    def test_the_same_seed_ranks_the_same_after_a_relaunch(self):
        """VAL-LAUNCH-006"""
        queries = ["kyoto", "stay", "k", "hotel", KYOTO]

        def run():
            self.seed(history=self.sites, bookmarks=self.marks)
            self.open_launcher()
            got = {}
            for query in queries:
                self.retype(query)
                got[query] = [(r["kind"], r["title"], r["target"]) for r in self.launcher()["rows"]]
            self.close_launcher()
            return got

        def relaunch():
            self.app.stop(remove_data=True)
            os.makedirs(self.data_dir, exist_ok=True)
            with open(os.path.join(self.data_dir, "settings.json"), "w") as out:
                json.dump({"searchEngine": SEARCH_ENGINE}, out)
            self.app.start(fresh=False)
            self.fresh()

        relaunch()
        before = run()
        relaunch()
        self.assertEqual(run(), before)

    def test_row_kinds_labels_and_order_follow_the_design(self):
        """VAL-LAUNCH-007"""
        self.seeded()
        self.open_launcher()
        expected = {
            "example.com": ("Open website", "https://example.com"),
            "https://example.com/a": ("Open website", "https://example.com/a"),
            "localhost:47810": ("Open website", "http://localhost:47810"),
            "127.0.0.1:47810/x.html": ("Open website", "http://127.0.0.1:47810/x.html"),
        }
        for query, (label, target) in expected.items():
            self.retype(query)
            first = self.launcher()["rows"][0]
            self.assertEqual((first["kind"], first["actionLabel"], first["target"]),
                             ("openURL", label, target), query)
        self.retype("kyoto")
        got = {r["kind"]: r["subtitle"] for r in self.launcher()["rows"]}
        self.assertEqual(got["switchTab"], "Switch to open page")
        self.assertEqual(got["history"], "Open website")
        self.assertEqual(got["bookmark"], "Open website")
        self.retype("kyoto hotels")
        rows = self.launcher()["rows"]
        self.assertEqual([r["kind"] for r in rows[:2]], ["search", "startTask"])
        self.assertEqual(rows[0]["actionLabel"], "Search the web")
        self.retype(KYOTO)
        state = self.launcher()
        rows = state["rows"]
        self.assertEqual([(r["kind"], r["title"], r["section"]) for r in rows[:2]], [
            ("startTask", "Start task", "For this request"),
            ("search", "Search the web", "For this request")])
        self.assertEqual(rows[1]["subtitle"], "See search results for this request")
        self.assertEqual(self.active(), rows[0]["id"])
        related = [r for r in rows if r["section"] == "Related open pages"]
        self.assertTrue(related and all(r["subtitle"] == "Switch to open page" for r in related))
        self.assertEqual([s["title"] for s in state["sections"]][:2],
                         ["For this request", "Related open pages"])
        self.call("test.screenshot", {"path": os.path.join(LOG_DIR, "launcher-typed.png")})
        self.retype("javascript:alert(1)")
        self.assertNotEqual(self.launcher()["rows"][0]["kind"], "openURL")


class KeyboardTests(LauncherCase):
    def seeded(self):
        self.seed(tabs=("Kyoto trip", "Kyoto food"),
                  history=[(url("index.html?s=k"), "Kyoto hotels")])
        self.open_launcher()
        self.type_text("kyoto")
        self.assertGreaterEqual(len(self.launcher()["rows"]), 4)

    def hint_rows(self):
        return [r["id"] for r in self.launcher()["rows"] if r["hint"]]

    def test_arrows_clamp_and_show_one_enter_hint(self):
        """VAL-LAUNCH-008"""
        self.seeded()
        before = self.snapshot()
        ids = self.ids()
        self.assertEqual(self.active(), ids[0])
        self.assertEqual(self.hint_rows(), [ids[0]])
        self.key("ArrowUp")
        self.assertEqual(self.active(), ids[0])
        trail = []
        for step in range(len(ids) + 3):
            self.key("ArrowDown")
            trail.append(self.active())
            self.assertEqual(self.hint_rows(), [self.active()])
        self.assertEqual(self.active(), ids[-1])
        self.assertEqual(trail[:len(ids) - 1], ids[1:])
        self.key("ArrowUp")
        self.assertEqual(self.active(), ids[-2])
        self.retype("kyoto")
        self.retype("kyo")
        self.assertEqual(len(self.hint_rows()), 1)
        state = self.launcher()
        self.assertLess(state["escFrame"]["y"], state["frame"]["y"] + 96)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.new_runs(), [])
        save("launcher-arrows.json", trail)

    def test_tab_and_shift_tab_stay_inside_the_launcher(self):
        """VAL-LAUNCH-008"""
        self.seeded()
        before = self.snapshot()
        query = self.launcher()["query"]
        start = self.responder()
        self.assertEqual(start, "launcherField")
        seen = []
        for _ in range(6):
            self.key("Tab")
            seen.append(self.responder())
        for _ in range(6):
            self.key("Tab", "shift")
            seen.append(self.responder())
        for name in seen:
            self.assertTrue(name == "launcherField" or name.startswith("launcherRow:"), seen)
        self.key("Tab")
        self.key("Tab", "shift")
        self.assertEqual(self.responder(), start)
        state = self.launcher()
        self.assertEqual(state["query"], query)
        self.assertTrue(state["open"])
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.new_runs(), [])
        save("launcher-tab-order.json", seen)

    def test_a_focused_row_shows_the_ring_and_return_runs_it(self):
        """VAL-TABS-016"""
        self.seeded()
        self.key("Tab")
        state = self.launcher()
        focused = [r for r in state["rows"] if r["focused"]]
        self.assertEqual(len(focused), 1)
        self.assertEqual(focused[0]["id"], state["active"])
        before = len(self.tab_ids())
        self.key("ArrowDown")
        self.assertTrue(self.launcher()["rows"][1]["focused"])
        self.key("Return")
        bs.wait_until(lambda: not self.launcher()["open"], what="closed")
        self.assertIn(len(self.tab_ids()) - before, (0, 1))

    def test_ime_return_and_escape_are_not_commands(self):
        """VAL-LAUNCH-009"""
        self.open_launcher()
        before = self.snapshot()
        self.call("test.ime", {"marked": "にほん"})
        self.assertTrue(self.launcher()["composing"])
        self.key("Return")
        state = self.launcher()
        self.assertTrue(state["open"])
        self.assertFalse(state["composing"])
        self.assertEqual(state["fieldText"], "にほん")
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.new_runs(), [])
        bs.wait_until(lambda: self.launcher()["current"], what="rows")
        self.key("Return")
        bs.wait_until(lambda: not self.launcher()["open"], what="the second Return ran the row")
        self.assertEqual(len(self.tab_ids()), len(before["tabs"]) + 1)

        self.open_launcher()
        self.call("test.ime", {"marked": "かな"})
        self.assertTrue(self.launcher()["composing"])
        self.key("Escape")
        state = self.launcher()
        self.assertTrue(state["open"])
        self.assertFalse(state["composing"])
        self.key("Escape")
        bs.wait_until(lambda: not self.launcher()["open"], what="the second Escape closed it")


class BackgroundTests(LauncherCase):
    def test_background_controls_and_shortcuts_do_nothing(self):
        """VAL-LAUNCH-010"""
        self.seed(tabs=("One", "Two", "Three"))
        page = self.open_page("launcher.html")
        self.open_launcher()
        self.type_text("abc")
        keys = [("w", ["cmd"]), ("t", ["cmd", "shift"]), ("Tab", ["ctrl"]),
                ("Tab", ["ctrl", "shift"]), ("r", ["cmd"]), ("[", ["cmd"]), ("]", ["cmd"]),
                ("f", ["cmd"]), ("l", ["cmd"]), ("d", ["cmd"])] \
            + [(str(n), ["cmd"]) for n in range(1, 10)]
        before = self.snapshot()
        counters = self.evaluate("[window.__keys, window.__pointer]", page["id"])
        for key, modifiers in keys:
            self.call("test.key", {"key": key, "modifiers": modifiers})
            state = self.launcher()
            self.assertTrue(state["open"], (key, modifiers))
            self.assertEqual(state["query"], "abc", (key, modifiers))
            self.assertEqual(self.snapshot(), before, (key, modifiers))
            self.assertEqual(self.responder(), "launcherField", (key, modifiers))
        self.assertEqual(self.evaluate("[window.__keys, window.__pointer]", page["id"]), counters)
        self.assertFalse(self.chrome()["find"]["open"])

        frame = self.launcher()["frame"]
        self.key("s", "ctrl", "cmd")
        self.assertEqual(self.launcher()["frame"], frame)
        self.assertNotIn("sidebar", self.ui())

        self.key(",", "cmd")
        bs.wait_until(lambda: self.ui()["settings"]["open"] and self.ui()["settings"]["key"],
                      what="Settings")
        self.assertTrue(self.launcher()["open"])
        closes = self.ui()["settings"].get("closes", 0)
        self.key("w", "cmd")
        bs.wait_until(lambda: self.ui()["settings"].get("closes", 0) == closes + 1, what="Settings closed")
        self.assertTrue(self.launcher()["open"])

    def test_pointer_input_does_not_reach_the_page(self):
        """VAL-LAUNCH-010"""
        page = self.open_page("launcher.html")
        self.open_launcher()
        self.retype("zzz")
        requests = self.requests()
        counters = self.evaluate("[window.__keys, window.__pointer]", page["id"])
        reply = self.call("test.click", {"target": page["id"], "x": 20, "y": 500})
        self.assertEqual(reply["hit"], "LauncherView")
        bs.wait_until(lambda: not self.launcher()["open"], what="dismissed by a click outside")
        self.assertEqual(self.requests(), requests)
        self.assertEqual(self.evaluate("[window.__keys, window.__pointer]", page["id"]), counters)


class ActionTests(LauncherCase):
    def test_open_website_opens_a_new_active_tab_with_one_request(self):
        """VAL-CROSS-002"""
        self.open_page("launcher.html")
        before = self.tab_ids()
        target = url("article.html")
        self.open_launcher()
        self.type_text(target)
        self.assertEqual(self.launcher()["rows"][0]["kind"], "openURL")
        requests = self.requests()
        self.key("Return")
        tab = bs.wait_until(lambda: [t for t in self.tabs() if t["id"] not in before
                                     and t["url"] == target and not t["loading"]],
                            what="the new tab")[0]
        self.assertEqual(self.active_id(), tab["id"])
        self.assertEqual(len(self.tab_ids()), len(before) + 1)
        self.assertEqual(len([l for l in self.fixtures.log(requests) if "GET /article.html" in l]), 1)
        self.assertEqual(self.new_runs(), [])

    def test_search_opens_a_new_active_tab_at_the_engine_url(self):
        """VAL-CROSS-002"""
        self.open_page("launcher.html")
        before = self.tab_ids()
        self.open_launcher()
        self.type_text("kyoto hotels")
        row = self.launcher()["rows"][0]
        self.assertEqual((row["kind"], row["actionLabel"]), ("search", "Search the web"))
        self.key("Return")
        tab = bs.wait_until(lambda: [t for t in self.tabs() if t["id"] not in before],
                            what="the search tab")[0]
        self.assertEqual(self.active_id(), tab["id"])
        self.assertEqual(parse_qs(urlsplit(tab["url"]).query)["q"], ["kyoto hotels"])
        self.assertEqual(len(self.tab_ids()), len(before) + 1)
        self.assertEqual(self.new_runs(), [])

    def test_switch_tab_opens_nothing_and_does_not_reload(self):
        """VAL-CROSS-002"""
        first, second = self.seed(tabs=("Tab A", "Tab B"))
        self.wait_loaded(titled("Tab B"), second)
        nonce = self.evaluate("window.__nonce", second)
        tabs, requests = self.tab_ids(), self.requests()
        self.open_launcher()
        self.type_text("Tab B")
        row = next(r for r in self.launcher()["rows"] if r["kind"] == "switchTab")
        self.assertEqual(row["target"], second)
        self.move_to(row)
        self.key("Return")
        bs.wait_until(lambda: self.active_id() == second, what="tab B active")
        self.assertEqual(self.tab_ids(), tabs)
        self.assertEqual(self.requests(), requests)
        self.assertEqual(self.evaluate("window.__nonce", second), nonce)
        self.assertEqual(self.new_runs(), [])

    def test_only_the_active_row_runs_after_arrows(self):
        """VAL-CROSS-002"""
        self.open_page("launcher.html")
        before = self.tab_ids()
        self.open_launcher()
        self.type_text(KYOTO)
        self.assertEqual(self.launcher()["rows"][0]["kind"], "startTask")
        self.key("ArrowDown")
        self.assertEqual(self.launcher()["active"].split(":")[0], "search")
        self.key("Return")
        tab = bs.wait_until(lambda: [t for t in self.tabs() if t["id"] not in before],
                            what="the search tab")[0]
        self.assertEqual(parse_qs(urlsplit(tab["url"]).query)["q"], [KYOTO])
        self.assertEqual(self.new_runs(), [])
        self.assertEqual(len(self.tab_ids()), len(before) + 1)

    def test_start_task_records_a_run_for_the_page_and_acts_on_nothing_without_a_model(self):
        """VAL-LAUNCH-007"""
        self.open_page("launcher.html")
        owner = self.active_id()
        tabs, requests = self.tab_ids(), self.requests()
        self.call("test.holdModel", {"on": True})
        self.addCleanup(self.call, "test.holdModel", {"on": False})
        self.open_launcher()
        self.type_text(KYOTO)
        self.key("Return")
        bs.wait_until(lambda: not self.launcher()["open"], what="closed")
        runs = self.new_runs()
        self.assertEqual(len(runs), 1)
        self.assertEqual((runs[0]["prompt"], runs[0]["origin"], runs[0]["tabId"], runs[0]["state"]),
                         (KYOTO, "mac", owner, "pending"))
        self.assertEqual(self.tab_ids(), tabs)
        self.assertEqual(self.requests(), requests)
        self.assertEqual(self.db("select count(*) from actions"), [(0,)])
        self.call("test.holdModel", {"on": False})
        run = bs.wait_until(lambda: next((r for r in self.new_runs() if r["state"] == "failed"), None),
                            what="the run to end at the provider stand-in")
        self.assertTrue(run["reason"].startswith("model rejected the request (404)"), run["reason"])
        self.assertEqual(run["steps"], [])
        self.assertEqual({path for _, path in self.provider.requests}, {"/v1/responses"})

    def test_run_methods_validate_their_input(self):
        for params in ({"prompt": "go"}, {"prompt": "  ", "origin": "mac"},
                       {"prompt": "go", "origin": "mac", "tabId": "nope"},
                       {"prompt": "go", "origin": "mac", "tabId": 7}):
            with self.assertRaises(bs.RpcError):
                self.call("run.start", params)
        run = self.call("run.start", {"prompt": " do it ", "origin": "phone"})
        self.assertEqual((run["prompt"], run["origin"], run["tabId"]), ("do it", "phone", None))
        self.assertEqual(self.runs()[-1]["runId"], run["runId"])


class EmptyStateTests(LauncherCase):
    def test_with_nothing_local_only_web_search_and_browser_rows_are_offered(self):
        """VAL-LAUNCH-004"""
        self.open_launcher()
        state = bs.wait_until(lambda: self.launcher()["current"] and self.launcher(), what="rows")
        self.assertEqual(self.signature(), [
            ("findWeb", "Find something on the web", "Web search", "Search the web"),
            ("command", "History", "Find a page you visited", "History"),
            ("command", "Settings", "Manage browser preferences", "Settings")])
        self.assertEqual(state["active"], state["rows"][0]["id"])
        self.key("Return")
        state = bs.wait_until(lambda: (lambda s: s if s["scope"] == "web" and s["current"] else None)(
            self.launcher()), what="web search mode")
        self.assertTrue(state["open"])
        self.assertEqual(self.new_runs(), [])
        self.assertEqual(self.db("select count(*) from actions"), [(0,)])


class PageSurvivalTests(LauncherCase):
    def test_the_launcher_leaves_the_page_untouched_and_escape_restores_its_focus(self):
        """VAL-CROSS-001"""
        page = self.open_page("launcher.html")
        tab = page["id"]
        self.evaluate("document.getElementById('box').focus(); window.scrollTo(0, 400)", tab)
        bs.wait_until(lambda: self.evaluate("window.scrollY", tab) == 400, what="scrolled")
        self.evaluate("window.__keys = 0; window.__pointer = 0", tab)

        def page_state():
            return self.evaluate(
                "JSON.stringify([location.href, document.title, scrollY, "
                "document.getElementById('box').value, window.__nonce, window.__keys, "
                "window.__pointer, document.activeElement.id])", tab)

        before = json.loads(page_state())
        requests, tabs = self.requests(), self.tab_ids()
        self.open_launcher()
        self.type_text("kyoto hotels 12345")
        for key in ("ArrowDown", "ArrowDown", "ArrowUp", "ArrowDown"):
            self.key(key)
        rows = self.launcher()["rows"]
        labels = {r["actionLabel"] for r in rows}
        self.assertTrue({"Start task", "Search the web"} & labels, labels)
        shot = os.path.join(LOG_DIR, "cross-001-launcher-over-page.png")
        self.call("test.screenshot", {"path": shot})
        during = json.loads(page_state())
        self.assertEqual(during[:5], before[:5])
        self.assertEqual(during[5:7], [0, 0])
        self.key("Escape")
        bs.wait_until(lambda: not self.launcher()["open"], what="closed")
        bs.wait_until(lambda: json.loads(page_state())[7] == "box", what="focus back in the page")
        restored = json.loads(page_state())
        self.assertEqual(restored[:5], before[:5])
        self.call("test.type", {"text": "x"})
        bs.wait_until(lambda: json.loads(page_state())[3] in ("keepx", "xkeep"),
                      what="typing lands in the input")
        after = json.loads(page_state())
        self.assertEqual(after[0], before[0])
        self.assertEqual(after[4], before[4])
        self.assertEqual(self.tab_ids(), tabs)
        self.assertEqual(self.requests(), requests)
        save("cross-001.json", {"before": before, "during": during, "after": after})


class ErrorStateTests(LauncherCase):
    def test_a_model_that_is_offline_disables_start_task_and_selects_search(self):
        """VAL-TASK-009, VAL-LAUNCH-016"""
        self.call("test.announcements", {"reset": True})
        self.call("test.modelOffline", {"on": True})
        self.open_launcher()
        self.type_text(KYOTO)
        state = self.launcher()
        self.assertTrue(state["error"])
        task = next(r for r in state["rows"] if r["kind"] == "startTask")
        search = next(r for r in state["rows"] if r["kind"] == "search")
        self.assertEqual((task["enabled"], task["subtitle"], task["state"]),
                         (False, "Muse is unavailable. Web search still works.", "disabled"))
        self.assertEqual((state["active"], search["hint"], task["hint"]), (search["id"], True, False))
        self.assertFalse(state["footer"]["pageIncluded"])
        self.assertEqual(state["fieldText"], KYOTO)
        for _ in range(3):
            self.key("ArrowUp")
        self.assertNotEqual(self.active(), task["id"])
        self.assertEqual(self.active().split(":")[0], "retry")
        self.key("ArrowDown")
        self.assertEqual(
            [a for a in self.call("test.announcements")["announcements"]
             if a == "Unable to connect to Muse"], ["Unable to connect to Muse"])
        runs = self.runs()
        self.call("test.modelOffline", {"on": False})
        self.assertTrue(self.launcher()["error"], "Muse coming back leaves the state until Retry")
        retry = next(r for r in self.launcher()["rows"] if r["kind"] == "retry")
        self.call("test.click", {"target": f"launcherRow:{retry['id']}"})
        state = bs.wait_until(lambda: (lambda s: s if not s["error"] and s["current"] else None)(
            self.launcher()), what="the retry row to go")
        self.assertTrue(state["open"])
        self.assertTrue(next(r for r in state["rows"] if r["kind"] == "startTask")["enabled"])
        self.assertEqual(self.runs(), runs)
        self.assertEqual(state["query"], KYOTO)

    def test_retry_while_still_offline_keeps_the_error(self):
        self.call("test.modelOffline", {"on": True})
        self.open_launcher()
        self.type_text(KYOTO)
        retry = next(r for r in self.launcher()["rows"] if r["kind"] == "retry")
        self.call("test.click", {"target": f"launcherRow:{retry['id']}"})
        self.assertTrue(self.launcher()["error"])
        self.assertTrue(self.launcher()["open"])


class FooterAndLocationTests(LauncherCase):
    def test_current_page_included_only_when_the_selected_start_task_passes_it(self):
        """VAL-LAUNCH-013"""
        page = self.open_page("launcher.html")
        self.open_launcher()
        self.assertFalse(self.launcher()["footer"]["pageIncluded"])
        self.type_text(KYOTO)
        footer = self.launcher()["footer"]
        self.assertTrue(footer["pageIncluded"])
        self.assertTrue(footer["text"].endswith("Current page included"), footer)
        self.assertEqual(footer["origin"], "127.0.0.1:47810")
        self.key("ArrowDown")
        self.assertFalse(self.launcher()["footer"]["pageIncluded"])
        self.assertNotIn("Current page included", self.launcher()["footer"]["text"])
        self.key("ArrowUp")
        self.key("Return")
        bs.wait_until(lambda: len(self.new_runs()) == 1, what="the run")
        self.assertEqual(self.new_runs()[0]["tabId"], page["id"])

    def test_cmd_l_prefills_the_selected_url_and_open_website_navigates_the_same_tab(self):
        """VAL-SHELL-006, VAL-CROSS-002"""
        page = self.open_page("launcher.html")
        tab = page["id"]
        tabs = self.tab_ids()
        self.key("l", "cmd")
        state = bs.wait_until(lambda: (lambda s: s if s["open"] and s["location"] else None)(
            self.launcher()), what="the ⌘L launcher")
        self.assertEqual(state["fieldText"], page["url"])
        self.assertEqual(state["selection"]["length"], len(page["url"]))
        self.assertEqual(self.responder(), "launcherField")
        self.assertEqual(self.new_runs(), [])
        target = url("article.html")
        self.type_text(target)
        self.assertEqual(self.launcher()["rows"][0]["kind"], "openURL")
        requests = self.requests()
        self.key("Return")
        self.wait_loaded(target, tab)
        self.assertEqual(self.tab_ids(), tabs)
        self.assertEqual(self.active_id(), tab)
        self.assertEqual(len([l for l in self.fixtures.log(requests) if "GET /article.html" in l]), 1)

    def test_cmd_l_search_navigates_the_current_tab(self):
        """VAL-SHELL-006"""
        page = self.open_page("launcher.html")
        tabs = self.tab_ids()
        self.key("l", "cmd")
        bs.wait_until(lambda: self.launcher()["location"], what="the ⌘L launcher")
        self.type_text("kyoto hotels")
        self.key("Return")
        tab = bs.wait_until(lambda: [t for t in self.tabs() if t["id"] == page["id"]
                                     and "q=kyoto" in t["url"]], what="the search in the same tab")
        self.assertEqual(parse_qs(urlsplit(tab[0]["url"]).query)["q"], ["kyoto hotels"])
        self.assertEqual(self.tab_ids(), tabs)

    def test_cmd_l_with_no_page_opens_the_empty_launcher(self):
        """VAL-SHELL-006"""
        self.key("l", "cmd")
        state = bs.wait_until(lambda: self.launcher()["open"] and self.launcher(), what="launcher")
        self.assertEqual((state["fieldText"], state["selection"]["length"]), ("", 0))


class CommandRowTests(LauncherCase):
    def command_row(self, title):
        return next((r for r in self.launcher()["rows"]
                     if r["kind"] == "command" and r["title"] == title), None)

    def test_commands_are_found_by_title_and_disabled_ones_explain_themselves(self):
        """VAL-SHELL-005"""
        self.open_page("launcher.html")
        self.open_launcher()
        self.type_text("reload")
        row = self.command_row("Reload page")
        self.assertIsNotNone(row)
        self.assertTrue(row["enabled"])
        self.retype("forward")
        row = next(r for r in self.launcher()["rows"] if r["kind"] == "command")
        self.assertFalse(row["enabled"])
        self.assertTrue(row["subtitle"])
        self.assertEqual(row["state"], "disabled")
        before = self.snapshot()
        for _ in self.ids():
            self.key("ArrowDown")
        self.assertNotEqual(self.active(), row["id"])
        self.click_row(row)
        self.assertTrue(self.launcher()["open"])
        self.assertEqual(self.snapshot(), before)

    def click_row(self, row):
        self.call("test.click", {"target": f"launcherRow:{row['id']}"})

    def test_enter_on_reload_reloads_once(self):
        """VAL-SHELL-005"""
        page = self.open_page("launcher.html")
        nonce = self.evaluate("window.__nonce", page["id"])
        requests = self.requests()
        self.open_launcher()
        self.type_text("reload")
        row = self.command_row("Reload page")
        self.move_to(row)
        self.key("Return")
        bs.wait_until(lambda: self.evaluate("window.__nonce", page["id"]) != nonce, what="reloaded")
        self.assertEqual(len([l for l in self.fixtures.log(requests) if "GET /launcher.html" in l]), 1)
        self.assertFalse(self.launcher()["open"])


class VisualTests(LauncherCase):
    def test_a_long_list_keeps_the_figma_panel_and_scrolls_inside_it(self):
        self.seed(tabs=[f"Open page {n}" for n in range(1, 6)])
        self.open_launcher()
        state = self.launcher()
        self.assertGreater(len(state["rows"]), 8)
        panel = state["frame"]
        self.assertEqual((panel["x"], panel["y"], panel["w"], panel["h"]), (340, 122, 760, 630))
        field_y = state["fieldFrame"]["y"]
        for _ in range(len(state["rows"]) - 1):
            self.key("ArrowDown")
            after = self.launcher()
            active = next(r for r in after["rows"] if r["id"] == after["active"])
            self.assertTrue(active["visible"], active["title"])
            self.assertEqual(after["frame"], panel)
            self.assertEqual(after["fieldFrame"]["y"], field_y)
        last = next(r for r in after["rows"] if r["id"] == after["active"])
        self.assertLessEqual(last["frame"]["y"] + last["frame"]["h"], panel["y"] + panel["h"])

    def test_narrow_window_has_the_narrow_geometry(self):
        """VAL-TABS-017"""
        self.call("test.windowSize", {"w": 720, "h": 600})
        self.open_launcher()
        self.type_text(KYOTO)
        panel = self.launcher()["frame"]
        self.assertEqual((panel["x"], panel["w"]), (24, 672))
        self.assertGreaterEqual(panel["y"], 24)
        self.assertLessEqual(panel["y"] + panel["h"], 600 - 24)
        self.assertEqual(self.launcher()["rows"][0]["frame"]["h"], 64)
        self.call("test.windowSize", {"w": 1440, "h": 900})


if __name__ == "__main__":
    unittest.main()
