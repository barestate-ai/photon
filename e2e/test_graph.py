"""The page graph: nodes for real pages, edges from real events, placement and persistence
(VAL-SPATIAL-001..004, graph half)."""
import json
import os
import shutil
import sqlite3
import threading
import time
import unittest
from urllib.parse import quote

import bs
from appcase import LOG_DIR, AppCase, url

SEARCH_ENGINE = f"{bs.FIXTURE_URL}/index.html?q=%s"
# Click points (x, y from the page's top left) of the controls in fixtures/popups.html.
CLICKS = {"blank": (60, 35), "open": (60, 85), "cmd": (60, 135), "plain": (60, 185)}
SLOT = (316, 294)


def titled(title, page="launcher.html"):
    return url(f"{page}?t={quote(title)}")


def positions(nodes):
    return [(n["url"], n["x"], n["y"]) for n in nodes]


class GraphCase(AppCase):
    """A fresh app per test, because the graph outlives every tab. Search goes to the fixtures."""

    env = None

    @classmethod
    def setUpClass(cls):
        cls.fixtures = bs.Fixtures(LOG_DIR).start()
        cls.data_dir = f"/tmp/bs-gr-{os.getpid()}-{cls.__name__[:8]}"
        cls.app = None

    @classmethod
    def tearDownClass(cls):
        if cls.app:
            cls.app.stop()

    def setUp(self):
        self.launch()

    def launch(self, fresh=True):
        if self.app:
            self.app.stop(remove_data=fresh)
        if fresh:
            shutil.rmtree(self.data_dir, ignore_errors=True)
            os.makedirs(self.data_dir)
            with open(os.path.join(self.data_dir, "settings.json"), "w") as out:
                json.dump({"searchEngine": SEARCH_ENGINE}, out)
        type(self).app = bs.App(self.data_dir, LOG_DIR, label=self._testMethodName, env=self.env).start(
            fresh=False)
        self.call("test.windowSize", {"w": 1440, "h": 900})

    # State.

    def canvas(self):
        return self.ui()["canvas"]

    def nodes(self):
        return self.canvas()["nodes"]

    def edges(self):
        return self.canvas()["edges"]

    def node_of(self, tab_id):
        return next(n for n in self.nodes() if n["tabId"] == tab_id)

    def edge(self, source_tab, target_tab, kind):
        return {"from": self.node_of(source_tab)["id"], "to": self.node_of(target_tab)["id"],
                "kind": kind, "runId": None}

    def wait_node(self, tab_id):
        return bs.wait_until(lambda: next((n for n in self.nodes() if n["tabId"] == tab_id), None),
                             what=f"a node for {tab_id}")

    def db(self, sql):
        path = os.path.join(self.data_dir, "barestate.sqlite")
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as conn:
            return conn.execute(sql).fetchall()

    def wait_saved(self, sql, expected):
        return bs.wait_until(lambda: self.db(sql) == expected and expected,
                             what=f"{sql} == {expected}")

    def saved_nodes(self):
        return self.db("SELECT id, tab_id, url, title, x, y, archived FROM canvas_nodes "
                       "ORDER BY rowid")

    # Pages.

    def open_page(self, title, page="launcher.html", activate=True):
        mark = len(self.fixtures.log())
        tab = self.call("open_tab", {"url": titled(title, page), "activate": activate})
        self.wait_loaded(titled(title, page), tab["id"])
        self.wait_node(tab["id"])
        if page == "popups.html":
            # A click that lands before the first frame is painted is dropped, not queued.
            ready = f"/__beacon?ready={quote(title)}"
            bs.wait_until(lambda: any(line.split()[1] == ready for line in self.fixtures.log(mark)),
                          what=f"{title} to paint its first frame")
        return tab["id"]

    def focus(self, tab_id):
        self.call("test.activateTab", {"tabId": tab_id})
        bs.wait_until(lambda: self.active_id() == tab_id and not self.ui()["launcher"]["open"],
                      what=f"{tab_id} active")

    def click(self, tab_id, control, *modifiers):
        x, y = CLICKS[control]
        self.call("test.click", {"target": tab_id, "x": x, "y": y, "modifiers": list(modifiers)})

    def new_tab_after(self, before, title):
        """The tab that appeared since `before`, once its page has loaded and become a node."""
        def found():
            fresh = [t for t in self.tabs() if t["id"] not in before and t["title"] == title
                     and not t["loading"]]
            return fresh[0] if fresh else None
        tab = bs.wait_until(found, what=f"a new tab titled {title!r}")
        self.wait_node(tab["id"])
        return tab

    def commit_launcher(self, text, kind=None):
        self.key("t", "cmd")
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the launcher open")
        self.call("test.type", {"text": text})
        bs.wait_until(lambda: (lambda s: s["current"] and s["query"] == text)(self.ui()["launcher"]),
                      what=f"rows for {text!r}")
        launcher = self.ui()["launcher"]
        if kind:
            wanted = next(r["id"] for r in launcher["rows"] if r["kind"] == kind)
            for _ in launcher["rows"]:
                if self.ui()["launcher"]["active"] == wanted:
                    break
                self.key("ArrowDown")
            self.assertEqual(self.ui()["launcher"]["active"], wanted)
        row = self.ui()["launcher"]["active"]
        self.key("Return")
        bs.wait_until(lambda: not self.ui()["launcher"]["open"], what="the launcher closed")
        return row


class NodeTests(GraphCase):
    def test_a_fresh_canvas_has_no_nodes_edges_or_rows(self):
        canvas = self.canvas()
        self.assertEqual((canvas["nodes"], canvas["edges"]), ([], []))
        self.assertEqual((canvas["title"], canvas["viewport"]),
                         ("Your pages", {"cx": 0, "cy": 0, "zoom": 1}))
        self.assertEqual(self.db("SELECT count(*) FROM canvas_nodes"), [(0,)])
        self.assertEqual(self.db("SELECT count(*) FROM canvas_edges"), [(0,)])

    def test_blank_pages_are_not_nodes(self):
        self.call("open_tab", {"url": "about:blank", "activate": False})
        self.open_page("real")
        self.assertEqual(len(self.tabs()), 3)
        self.assertEqual(len(self.nodes()), 1)

    def test_open_pages_are_live_nodes_that_equal_the_tabs(self):
        for n in range(5):
            self.open_page(f"page-{n}")
        nodes = bs.wait_until(lambda: (lambda n: n if len(n) == 5 else None)(self.nodes()),
                              what="five nodes")
        tabs = {t["id"]: t for t in self.tabs()}
        for node in nodes:
            self.assertEqual(node["kind"], "live")
            tab = tabs[node["tabId"]]
            self.assertEqual((node["url"], node["title"]), (tab["url"], tab["title"]))
        rows = self.wait_saved("SELECT count(*) FROM canvas_nodes WHERE archived = 0", [(5,)])
        self.assertEqual(rows, [(5,)])
        self.assertEqual(sorted(r[1] for r in self.saved_nodes()), sorted(tabs[n["tabId"]]["id"]
                                                                          for n in nodes))

    def test_navigating_a_tab_to_a_blank_page_archives_its_node(self):
        root = self.open_page("root")
        self.navigate(root, "about:blank")
        bs.wait_until(lambda: [n["kind"] for n in self.nodes()] == ["archived"],
                      what="the node archived")
        self.assertEqual(self.nodes()[0]["url"], titled("root"))

    def test_navigating_a_page_updates_its_node_without_adding_one(self):
        tab = self.open_page("before")
        self.navigate(tab, titled("after"))
        bs.wait_until(lambda: self.node_of(tab)["title"] == "after", what="the node's new title")
        self.assertEqual(len(self.nodes()), 1)

    def test_closing_archives_the_node_and_reopening_makes_it_live_again(self):
        keep = self.open_page("keep")
        gone = self.open_page("gone")
        before = self.node_of(gone)
        self.call("test.closeTab", {"tabId": gone})
        archived = bs.wait_until(
            lambda: next((n for n in self.nodes() if n["id"] == before["id"]
                          and n["kind"] == "archived"), None), what="an archived node")
        self.assertIsNone(archived["tabId"])
        self.assertEqual((archived["url"], archived["x"], archived["y"]),
                         (before["url"], before["x"], before["y"]))
        self.wait_saved(f"SELECT archived, tab_id IS NULL FROM canvas_nodes WHERE id = '{before['id']}'",
                        [(1, 1)])
        self.call("test.activateTab", {"tabId": keep})
        self.key("t", "cmd", "shift")
        revived = bs.wait_until(
            lambda: next((n for n in self.nodes() if n["id"] == before["id"]
                          and n["kind"] == "live"), None), what="the node live again")
        self.assertEqual((revived["x"], revived["y"]), (before["x"], before["y"]))
        self.assertEqual(len(self.nodes()), 2)

    def test_only_the_forty_most_recently_closed_pages_stay(self):
        for n in range(45):
            tab = self.open_page(f"closed-{n}")
            self.call("test.closeTab", {"tabId": tab})
            bs.wait_until(lambda: not any(t["id"] == tab for t in self.tabs()), what="tab closed")
        nodes = bs.wait_until(lambda: (lambda n: n if len(n) == 40 else None)(self.nodes()),
                              what="forty nodes")
        urls = {n["url"] for n in nodes}
        self.assertTrue(all(n["kind"] == "archived" for n in nodes))
        self.assertTrue(all(titled(f"closed-{n}") not in urls for n in range(5)))
        self.assertTrue(all(titled(f"closed-{n}") in urls for n in range(5, 45)))
        self.wait_saved("SELECT count(*) FROM canvas_nodes", [(40,)])

    def test_history_bookmarks_launcher_rows_and_runs_make_no_node(self):
        self.call("test.seed", {
            "history": [{"url": titled("old"), "title": "old"}],
            "bookmarks": [{"url": titled("marked"), "title": "marked"}]})
        self.key("t", "cmd")
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the launcher open")
        self.key("Escape")
        self.call("run.start", {"prompt": "Summarize this", "origin": "mac"})
        self.assertEqual(self.nodes(), [])
        self.assertEqual(self.db("SELECT count(*) FROM canvas_nodes"), [(0,)])


class EdgeTests(GraphCase):
    def test_target_blank_window_open_and_command_click_each_make_one_edge(self):
        root = self.open_page("root", "popups.html")
        popup_before = set(self.tab_ids())
        self.click(root, "blank")
        blank = self.new_tab_after(popup_before, "blank-popup")
        self.assertEqual(self.edges(), [self.edge(root, blank["id"], "openedFrom")])
        self.assertEqual(self.active_id(), blank["id"])

        self.focus(root)
        before = set(self.tab_ids())
        self.click(root, "open")
        scripted = self.new_tab_after(before, "opener:yes")
        self.assertEqual(self.edges()[-1], self.edge(root, scripted["id"], "openedFrom"))
        bs.wait_until(lambda: self.evaluate("window.__message", root) == "popup-hello",
                      what="the popup's message to its opener")

        self.focus(root)
        before = set(self.tab_ids())
        self.click(root, "cmd", "cmd")
        command = self.new_tab_after(before, "cmd-click")
        self.assertEqual(self.edges()[-1], self.edge(root, command["id"], "openedFrom"))
        self.assertEqual(self.active_id(), root)
        self.assertEqual(len(self.edges()), 3)
        self.assertEqual(len(self.tabs()), 5)  # the blank tab, the root, three popups
        sql = "SELECT from_id, to_id, kind, run_id FROM canvas_edges ORDER BY rowid"
        saved = self.wait_saved(sql, [(e["from"], e["to"], e["kind"], "") for e in self.edges()])
        self.assertEqual(len(saved), 3)

    def test_edges_survive_closing_either_page(self):
        root = self.open_page("root", "popups.html")
        before = set(self.tab_ids())
        self.click(root, "blank")
        popup = self.new_tab_after(before, "blank-popup")["id"]
        edges = self.edges()
        self.call("test.closeTab", {"tabId": popup})
        self.call("test.closeTab", {"tabId": root})
        bs.wait_until(lambda: all(n["kind"] == "archived" for n in self.nodes()), what="archived")
        self.assertEqual(self.edges(), edges)

    def test_launcher_open_and_search_from_a_focused_page_record_navigated_from(self):
        root = self.open_page("root", "popups.html")
        before = set(self.tab_ids())
        self.assertEqual(self.commit_launcher(titled("typed").removeprefix("http://")).split(":")[0],
                         "openURL")
        typed = self.new_tab_after(before, "typed")
        self.assertEqual(self.edges(), [self.edge(root, typed["id"], "navigatedFrom")])

        self.focus(root)
        before = set(self.tab_ids())
        self.assertEqual(self.commit_launcher("kyoto weather").split(":")[0], "search")
        searched = bs.wait_until(
            lambda: next((t for t in self.tabs() if t["id"] not in before and "q=kyoto" in t["url"]
                          and not t["loading"]), None), what="the search tab")
        self.wait_node(searched["id"])
        self.assertEqual(self.edges()[-1], self.edge(root, searched["id"], "navigatedFrom"))
        self.assertEqual(len(self.edges()), 2)

    def test_nothing_else_records_an_edge(self):
        blank = self.tab_ids()[0]
        self.call("test.activateTab", {"tabId": blank})
        before = set(self.tab_ids())
        self.commit_launcher(titled("from-blank").removeprefix("http://"))
        self.new_tab_after(before, "from-blank")
        self.assertEqual(self.edges(), [])

        root = self.open_page("root", "popups.html")
        self.navigate(root, titled("same-host-title", "popups.html"))
        self.click(root, "plain")
        bs.wait_until(lambda: self.evaluate("document.title", root) == "in-tab", what="link nav")
        self.key("[", "cmd")
        bs.wait_until(lambda: self.evaluate("document.title", root) == "same-host-title",
                      what="back")
        self.key("]", "cmd")
        bs.wait_until(lambda: self.evaluate("document.title", root) == "in-tab", what="forward")
        self.key("l", "cmd")
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the location launcher")
        self.call("test.type", {"text": titled("via-location").removeprefix("http://")})
        self.key("Return")
        bs.wait_until(lambda: not self.ui()["launcher"]["open"], what="the launcher closed")
        bs.wait_until(lambda: self.node_of(root)["title"] == "via-location", what="in-tab ⌘L")

        self.call("test.seed", {"history": [{"url": titled("visited"), "title": "visited page"}]})
        self.commit_launcher("visited page", kind="history")
        visited = bs.wait_until(
            lambda: next((t for t in self.tabs() if t["title"] == "visited" and not t["loading"]),
                         None), what="the history tab")
        self.wait_node(visited["id"])
        self.assertEqual(self.edges(), [])
        self.assertEqual(self.db("SELECT count(*) FROM canvas_edges"), [(0,)])


class PlacementTests(GraphCase):
    def build(self):
        roots = [self.open_page(f"root-{n}", "popups.html") for n in range(5)]
        for source, count in ((roots[1], 3), (roots[4], 2)):
            for n in range(count):
                self.focus(source)
                before = set(self.tab_ids())
                self.click(source, "blank")
                self.new_tab_after(before, "blank-popup")
        return positions(self.nodes())

    def test_the_same_sequence_gives_the_same_positions_and_no_overlap(self):
        first = self.build()
        self.assertEqual(len(first), 10)
        for i, a in enumerate(first):
            for b in first[i + 1:]:
                self.assertTrue(abs(a[1] - b[1]) >= SLOT[0] or abs(a[2] - b[2]) >= SLOT[1],
                                f"{a} overlaps {b}")
        self.launch()
        self.assertEqual(self.build(), first)

    def test_a_placed_node_moves_only_when_dragged_and_survives_relaunch(self):
        pages = [self.open_page(f"p-{n}") for n in range(3)]
        placed = positions(self.nodes())
        self.call("test.closeTab", {"tabId": pages[0]})
        self.open_page("more")
        self.call("test.activateTab", {"tabId": pages[1]})
        self.call("test.canvas", {"viewport": {"cx": 500, "cy": -300, "zoom": 0.5}})
        self.assertEqual(positions(self.nodes())[:3], placed)
        dragged = self.nodes()[1]["id"]
        self.call("test.canvas", {"move": {"node": dragged, "x": 7.5, "y": -9.25}})
        expected = positions(self.nodes())
        self.assertEqual(expected[1][1:], (7.5, -9.25))
        self.assertEqual((expected[0], expected[2]), (placed[0], placed[2]))
        self.wait_saved(f"SELECT x, y FROM canvas_nodes WHERE id = '{dragged}'", [(7.5, -9.25)])
        self.launch(fresh=False)
        restored = self.nodes()
        self.assertEqual(positions(restored)[:4], expected)
        self.assertTrue(all(n["kind"] == "archived" and n["tabId"] is None for n in restored))


class PersistenceTests(GraphCase):
    def test_nodes_edges_title_and_viewport_survive_a_relaunch(self):
        root = self.open_page("root", "popups.html")
        before = set(self.tab_ids())
        self.click(root, "blank")
        self.new_tab_after(before, "blank-popup")
        node = self.nodes()[1]["id"]
        self.call("test.canvas", {"move": {"node": node, "x": 1.25, "y": 2.5},
                                  "viewport": {"cx": 12.345678, "cy": -7.5, "zoom": 0.73},
                                  "title": "Trip planning"})
        saved = self.canvas()
        bs.wait_until(lambda: self.db("SELECT value FROM canvas_meta WHERE key='title'")
                      == [("Trip planning",)], what="the title saved")
        self.launch(fresh=False)
        restored = self.canvas()
        self.assertEqual(restored["title"], "Trip planning")
        for key in ("cx", "cy", "zoom"):
            self.assertAlmostEqual(restored["viewport"][key], saved["viewport"][key], delta=1e-6)
        self.assertEqual(restored["edges"], saved["edges"])
        self.assertEqual([(n["id"], n["url"], n["title"], n["x"], n["y"], n["kind"])
                          for n in restored["nodes"]],
                         [(n["id"], n["url"], n["title"], n["x"], n["y"], "archived")
                          for n in saved["nodes"]])

    def test_a_held_gesture_writes_nothing_however_long_it_pauses(self):
        self.open_page("a")
        node = self.nodes()[0]["id"]
        self.wait_saved("SELECT count(*) FROM canvas_nodes", [(1,)])
        x = self.db(f"SELECT x FROM canvas_nodes WHERE id='{node}'")[0][0]
        self.call("test.canvas", {"gesture": True, "move": {"node": node, "x": x + 50, "y": 0}})
        time.sleep(1.5)  # more than twice the save delay, with the pointer still down
        self.assertEqual(self.db(f"SELECT x FROM canvas_nodes WHERE id='{node}'"), [(x,)])
        self.call("test.canvas", {"gesture": False})
        self.wait_saved(f"SELECT x FROM canvas_nodes WHERE id='{node}'", [(x + 50,)])

    def test_a_change_made_just_before_quitting_is_saved(self):
        self.open_page("a")
        node = self.nodes()[0]["id"]
        self.call("test.canvas", {"move": {"node": node, "x": 7, "y": 9}, "title": "Late edit"})
        self.launch(fresh=False)
        self.assertEqual([(n["x"], n["y"]) for n in self.nodes()], [(7, 9)])
        self.assertEqual(self.canvas()["title"], "Late edit")

    def test_a_gesture_writes_nothing_until_it_ends_and_then_once(self):
        self.open_page("a")
        node = self.nodes()[0]["id"]
        self.wait_saved("SELECT count(*) FROM canvas_nodes", [(1,)])
        path = os.path.join(self.data_dir, "barestate.sqlite")
        versions = []
        stop = threading.Event()

        def poll():
            probe = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
            while not stop.is_set():
                versions.append((time.monotonic(), probe.execute("PRAGMA data_version").fetchone()[0]))
                time.sleep(0.02)
            probe.close()

        poller = threading.Thread(target=poll)
        poller.start()
        rpc = self.app.rpc()
        try:
            started = time.monotonic()
            for step in range(120):
                rpc.call("test.canvas", {"move": {"node": node, "x": step, "y": -step},
                                         "viewport": {"cx": step, "cy": 0, "zoom": 1}})
            ended = time.monotonic()
            bs.wait_until(lambda: self.db(f"SELECT x FROM canvas_nodes WHERE id='{node}'")
                          == [(119.0,)], what="the last position saved")
            time.sleep(0.5)
        finally:
            rpc.close()
            stop.set()
            poller.join()
        during = {v for t, v in versions if started <= t <= ended}
        after = {v for t, v in versions if t > ended}
        self.assertEqual(len(during | {versions[0][1]}) if during else 1, 1,
                         "the database changed during the gesture")
        self.assertLessEqual(len(after | during) - 1, 2)
        self.assertGreaterEqual(len(after | during), 2, "the gesture never reached the database")


if __name__ == "__main__":
    unittest.main()
