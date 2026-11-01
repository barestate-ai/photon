"""The Open pages scope of the launcher: every live page, filtered locally, chosen by mouse or keys,
focused on the main screen without a reload (VAL-PAGES-001, VAL-PAGES-002).

The scope value in `test.ui` is `launcher.scope == "pages"`; its rows are `switchTab` rows in the
section "Open pages", with the page title as title and the host as subtitle."""
import os
from urllib.parse import quote, urlsplit

import bs
from appcase import LOG_DIR, save, url
from test_focus import FocusCase

TITLES = ["Alpha harbour", "Bravo market", "Charlie garden", "Delta bridge", "Echo valley",
          "Foxtrot tower", "Golf station"]
SLUGS = ["zq-amber", "zq-birch", "zq-cedar", "zq-dune", "zq-elm", "zq-fir", "zq-gum"]
ENTRY = "command:openPages"
ROUTES = ("cmd+t", "command button")


class PagesCase(FocusCase):
    """Seven live pages and the blank tab the app starts with; page 1 is active."""

    def setUp(self):
        super().setUp()
        self.blank = self.tab_ids()[0]
        self.urls = [url(f"launcher.html?t={quote(title)}&slug={slug}")
                     for title, slug in zip(TITLES, SLUGS)]
        self.pages_ = []
        for page_url in self.urls:
            tab = self.call("open_tab", {"url": page_url, "activate": True})["id"]
            self.wait_loaded(page_url, tab)
            self.wait_node(tab)
            self.pages_.append(tab)
        self.focus(self.pages_[0])
        self.seed(self.pages_[0], "keep-me", 400)
        self.seed(self.pages_[1], "two-typed", 250)
        self.show_page()

    def seed(self, tab, value, y):
        self.evaluate(f"document.getElementById('box').value = {value!r}; window.scrollTo(0, {y})", tab)
        bs.wait_until(lambda: self.evaluate("window.scrollY", tab) == y, what="scrolled")

    # The launcher.

    def launcher(self):
        return self.ui()["launcher"]

    def open_launcher(self, route):
        if route == "cmd+t":
            self.key("t", "cmd")
        else:
            self.call("test.click", {"target": "commandButton"})
        self.wait_launcher(True)
        return bs.wait_until(lambda: self.launcher()["current"] and self.launcher(), what="rows")

    def click_row(self, row_id):
        """A row below the fold is scrolled into view first (the keys do that), then clicked."""
        if not next(r for r in self.launcher()["rows"] if r["id"] == row_id)["visible"]:
            self.walk_to(row_id)
        self.assertEqual(self.call("test.click", {"target": f"launcherRow:{row_id}"})["hit"],
                         "LauncherRowView")

    def walk_to(self, row_id):
        for _ in self.launcher()["rows"]:
            if self.launcher()["active"] == row_id:
                return
            self.key("ArrowDown")
        self.assertEqual(self.launcher()["active"], row_id)

    def enter_pages(self, how):
        """From the open launcher, activates the Open pages entry by `how` (click or keys)."""
        entry = next(r for r in self.launcher()["rows"] if r["id"] == ENTRY)
        self.assertEqual((entry["title"], entry["section"]), ("Open pages", "Browser"))
        if how == "click":
            self.click_row(ENTRY)
        else:
            self.walk_to(ENTRY)
            self.key("Return")
        return bs.wait_until(
            lambda: (lambda s: s if s["open"] and s["scope"] == "pages" and s["current"] and s["rows"]
                     else None)(self.launcher()), what="the Open pages scope")

    def type_text(self, text):
        self.call("test.type", {"text": text})
        return bs.wait_until(
            lambda: (lambda s: s if s["current"] and s["query"] == text else None)(self.launcher()),
            what=f"rows for {text!r}")

    def clear_field(self):
        self.key("a", "cmd")
        self.key("Backspace")
        return bs.wait_until(
            lambda: (lambda s: s if s["current"] and s["query"] == "" else None)(self.launcher()),
            what="an empty query")

    def wait_closed(self):
        bs.wait_until(lambda: not self.launcher_open(), what="the launcher closed")

    # What must not change.

    def world(self):
        return {"tabs": self.tab_ids(), "browsers": self.ui()["cefBrowserCount"],
                "requests": self.requests(), "runs": self.call("run.list")["runs"]}

    def documents(self):
        return {tab: self.document(tab) for tab in self.pages_[:2]}

    def assert_focused_on(self, index, before_world, before_docs, step):
        tab = self.pages_[index]
        bs.wait_until(lambda: self.active_id() == tab and self.presentation() == "focused",
                      what=f"{step}: {TITLES[index]} focused")
        caption = self.ui()["caption"]
        self.assertEqual((caption["title"], caption["host"]),
                         (TITLES[index], urlsplit(self.urls[index]).netloc), step)
        self.assertEqual(self.world(), before_world, step)
        self.assertEqual(self.documents(), before_docs, step)
        self.assert_card_is_page()


class ListAndFilterTests(PagesCase):
    def test_the_entry_lists_every_live_page_filters_and_is_reachable_by_keys_and_mouse(self):
        """VAL-PAGES-001"""
        report = {}
        for route, how in zip(ROUTES, ("keys", "click")):
            tabs, active = self.tab_ids(), self.active_id()
            requests = self.requests()
            state = self.open_launcher(route)
            self.assertEqual(state["scope"], "all", route)
            self.assertIn(ENTRY, [r["id"] for r in state["rows"]], route)
            state = self.enter_pages(how)
            self.assertEqual((self.tab_ids(), self.active_id(), self.presentation()),
                             (tabs, active, "focused"), route)
            self.assertEqual(state["placeholder"], "Search your open pages")
            report[route] = {"rows": [(r["title"], r["subtitle"]) for r in state["rows"]]}

            rows = state["rows"]
            self.assertEqual(len(rows), 7, route)
            self.assertEqual({r["target"] for r in rows}, set(self.pages_), route)
            self.assertNotIn(self.blank, [r["target"] for r in rows])
            self.assertTrue(all(r["kind"] == "switchTab" and r["section"] == "Open pages"
                                for r in rows))
            titles = {t["id"]: t["title"] for t in self.tabs()}
            self.assertEqual([r["title"] for r in rows], [titles[r["target"]] for r in rows])
            self.assertEqual({r["subtitle"] for r in rows}, {"127.0.0.1"})
            self.assertEqual(rows[0]["target"], active)
            self.assertEqual([r["id"] for r in rows if r["hint"]], [state["active"]])

            for query, expected in (("BRIDGE", "Delta bridge"), ("zq-cedar", "Charlie garden")):
                found = self.type_text(query)["rows"]
                self.assertEqual([r["title"] for r in found], [expected], query)
                self.clear_field()
            self.assertEqual(len(self.launcher()["rows"]), 7)
            self.assertEqual(self.requests(), requests, "filtering needs no network")

            self.walk_to(rows[-1]["id"])
            last = self.launcher()
            self.assertTrue(next(r for r in last["rows"] if r["id"] == rows[-1]["id"])["visible"])
            self.key("ArrowDown")
            self.assertEqual(self.launcher()["active"], rows[-1]["id"], "arrows clamp")
            for _ in rows:
                self.key("ArrowUp")
            self.key("ArrowUp")
            self.assertEqual(self.launcher()["active"], rows[0]["id"], "arrows clamp")
            self.call("test.screenshot", {"path": os.path.join(LOG_DIR, f"pages-scope-{route[:3]}.png")})
            self.key("Escape")
            self.wait_closed()
            self.assertEqual(self.launcher()["scope"], "all")
            self.assertEqual(self.world()["requests"], requests)
        save("pages-001.json", report)

    def test_every_row_is_chosen_by_a_click_on_it(self):
        """VAL-PAGES-001"""
        for index, tab in enumerate(self.pages_):
            self.activate(self.pages_[(index + 1) % 7], "overview")
            self.open_launcher("command button")
            row = next(r for r in self.enter_pages("click")["rows"] if r["target"] == tab)
            self.click_row(row["id"])
            self.wait_closed()
            bs.wait_until(lambda: self.active_id() == tab and self.presentation() == "focused",
                          what=f"{TITLES[index]} focused")


class ChooseTests(PagesCase):
    def test_choosing_a_page_focuses_the_existing_one_from_both_presentations_by_mouse_and_keys(self):
        """VAL-PAGES-002"""
        report = []
        combos = [("overview", "click"), ("overview", "keys"), ("focused", "click"),
                  ("focused", "keys")]
        for index, (presentation, how) in enumerate(combos):
            self.activate(self.pages_[0], presentation)
            self.assertEqual(self.presentation(), presentation)
            world, docs = self.world(), self.documents()
            route = ROUTES[index % 2]
            self.open_launcher(route)
            entry = self.enter_pages("click" if how == "click" else "keys")
            row = next(r for r in entry["rows"] if r["target"] == self.pages_[1])
            if how == "click":
                self.click_row(row["id"])
            else:
                self.walk_to(row["id"])
                self.key("Return")
            self.wait_closed()
            self.assert_focused_on(1, world, docs, f"{presentation}/{how}")
            self.assertEqual(docs[self.pages_[0]]["value"], "keep-me")
            self.assertEqual(docs[self.pages_[0]]["scrollY"], 400)
            report.append({"from": presentation, "by": how, "after": self.documents()[self.pages_[1]]})
        self.call("test.screenshot", {"path": os.path.join(LOG_DIR, "pages-002-page-2-focused.png")})
        save("pages-002.json", report)

    def test_choosing_the_active_page_focuses_it_from_the_overview_and_keeps_it_focused(self):
        """VAL-PAGES-002"""
        for presentation, how in (("overview", "keys"), ("overview", "click"), ("focused", "keys"),
                                  ("focused", "click")):
            self.activate(self.pages_[0], presentation)
            world, docs = self.world(), self.documents()
            self.open_launcher("cmd+t")
            entry = self.enter_pages("click")
            row = next(r for r in entry["rows"] if r["target"] == self.pages_[0])
            if how == "click":
                self.click_row(row["id"])
            else:
                self.walk_to(row["id"])
                self.key("Return")
            self.wait_closed()
            self.assert_focused_on(0, world, docs, f"active {presentation}/{how}")

    def test_escape_cancels_from_both_presentations_without_any_change(self):
        """VAL-PAGES-002"""
        for presentation in ("overview", "focused"):
            self.activate(self.pages_[0], presentation)
            world, docs = self.world(), self.documents()
            active = self.active_id()
            self.open_launcher("command button")
            self.enter_pages("click")
            self.type_text("bravo")
            self.key("Escape")
            self.wait_closed()
            self.assertEqual((self.active_id(), self.presentation()), (active, presentation))
            self.assertEqual(self.world(), world)
            self.assertEqual(self.documents(), docs)
            self.assertEqual(self.launcher()["scope"], "all")
