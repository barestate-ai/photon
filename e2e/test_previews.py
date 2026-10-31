"""The bounded preview cache: stamped captures, stale rejection, LRU bounds and memory-only
(VAL-PREVIEW-002..004)."""
import os
import subprocess
import tempfile
import unittest

import bs
from test_graph import GraphCase, titled

CARD = (440, 300)
MIB = 1 << 20
IMAGE_MAGICS = (b"\xff\xd8\xff", b"\x89PNG", b"RIFF", b"\x00\x00\x00\x18ftyp", b"\x00\x00\x00\x1cftyp")


class PreviewCase(GraphCase):
    """Captures here are requested by hand; the overview's own triggers are tested in test_canvas."""

    def launch(self, fresh=True):
        super().launch(fresh)
        self.call("test.previews", {"auto": False})

    def previews(self):
        return self.call("test.previews")

    def capture(self, tab_id, **size):
        params = {"tabId": tab_id}
        if size:
            params.update(size)
        return self.call("test.previewCapture", params)["outcome"]

    def observed_key(self, tab_id):
        return self.call("observe", {"tabId": tab_id})["documentKey"]

    def preview_of(self, tab_id):
        node = self.node_of(tab_id)
        return node["previewState"], node["documentKey"]

    def wait_state(self, tab_id, state):
        return bs.wait_until(lambda: self.preview_of(tab_id)[0] == state and self.preview_of(tab_id),
                             what=f"{tab_id} preview {state}")

    def reload(self, tab_id):
        self.call("test.devtools", {"tabId": tab_id, "method": "Page.reload", "params": {}})


class CaptureTests(PreviewCase):
    def test_a_visible_page_is_captured_as_a_card_sized_jpeg_decoded_off_the_main_thread(self):
        tab = self.open_page("shot")
        self.assertEqual(self.preview_of(tab), ("none", None))
        self.assertEqual(self.capture(tab), "stored")
        state = self.previews()
        self.assertEqual((state["count"], state["captures"], state["rejectedStale"]), (1, 1, 0))
        record = state["log"][-1]
        self.assertEqual((record["outcome"], record["magic"], record["decodedOnMain"]),
                         ("stored", "ffd8ff", False))
        self.assertLessEqual(abs(record["width"] - CARD[0]), 2)
        self.assertLessEqual(abs(record["height"] - CARD[1]), 2)
        self.assertEqual(state["bytes"], record["width"] * record["height"] * 4)
        self.assertEqual(self.preview_of(tab), ("fresh", self.observed_key(tab)))

    def test_a_hidden_page_is_never_captured(self):
        self.open_page("front")
        hidden = self.open_page("back", activate=False)
        self.assertEqual(self.capture(hidden), "notVisible")
        state = self.previews()
        self.assertEqual((state["count"], state["captures"]), (0, 0))
        self.assertEqual(self.preview_of(hidden), ("none", None))

    def test_the_capture_size_follows_the_card(self):
        tab = self.open_page("wide")
        self.assertEqual(self.capture(tab, width=600, height=200), "stored")
        record = self.previews()["log"][-1]
        self.assertLessEqual(abs(record["width"] - 600), 2)
        self.assertLessEqual(abs(record["height"] - 200), 2)


class StaleTests(PreviewCase):
    def test_navigating_marks_the_node_stale_and_a_new_capture_makes_it_fresh(self):
        tab = self.open_page("one")
        self.capture(tab)
        first = self.observed_key(tab)
        self.assertEqual(self.preview_of(tab), ("fresh", first))
        self.navigate(tab, titled("two"))
        _, stored = self.wait_state(tab, "stale")
        self.assertEqual(stored, first)
        self.assertNotEqual(self.observed_key(tab), first)
        self.assertEqual(self.capture(tab), "stored")
        self.assertEqual(self.preview_of(tab), ("fresh", self.observed_key(tab)))
        self.assertEqual(self.previews()["count"], 1)

    def test_a_reload_marks_the_node_stale(self):
        tab = self.open_page("reload")
        self.capture(tab)
        self.reload(tab)
        _, stored = self.wait_state(tab, "stale")
        bs.wait_until(lambda: self.observed_key(tab) != stored, what="a new document key")

    def test_a_same_document_navigation_keeps_the_preview_fresh(self):
        tab = self.open_page("hash")
        self.capture(tab)
        key = self.preview_of(tab)
        self.evaluate("history.pushState({}, '', '#next'); location.hash = 'again'", tab)
        bs.wait_until(lambda: self.evaluate("location.hash", tab) == "#again", what="the hash")
        self.assertEqual(self.observed_key(tab), key[1])
        self.assertEqual(self.preview_of(tab), key)

    def test_a_hidden_page_that_navigates_stays_stale_with_no_capture(self):
        hidden = self.open_page("hidden")
        self.capture(hidden)
        self.open_page("front")
        self.navigate(hidden, titled("hidden-two"))
        self.wait_state(hidden, "stale")
        self.assertEqual(self.previews()["captures"], 1)

    def test_a_new_page_has_no_preview_and_a_navigation_makes_that_stale_without_an_image(self):
        tab = self.open_page("plain")
        self.assertEqual(self.preview_of(tab), ("none", None))
        self.navigate(tab, titled("plain-two"))
        self.wait_state(tab, "stale")
        self.assertEqual((self.preview_of(tab)[1], self.previews()["count"]), (None, 0))

    def test_a_capture_held_across_a_navigation_is_discarded_and_counted(self):
        tab = self.open_page("held")
        self.capture(tab)
        before = self.previews()
        self.call("test.previewHold", {"on": True})
        self.assertEqual(self.capture(tab), "held")
        self.assertTrue(self.previews()["held"])
        self.navigate(tab, titled("held-two"))
        self.wait_state(tab, "stale")
        self.call("test.previewRelease")
        after = bs.wait_until(
            lambda: (lambda s: s if s["log"] and s["log"][-1]["outcome"] == "rejectedStale" else None)(
                self.previews()),
            what="the held capture decided")
        self.assertEqual(after["rejectedStale"], before["rejectedStale"] + 1)
        self.assertEqual((after["count"], after["bytes"], after["captures"]),
                         (before["count"], before["bytes"], before["captures"]))
        self.assertEqual(self.preview_of(tab)[0], "stale")
        self.assertEqual(self.preview_of(tab)[1], before["log"][-1]["documentKey"])

    def test_a_capture_decided_after_a_navigation_does_not_roll_the_tracked_document_back(self):
        tab = self.open_page("rollback")
        self.capture(tab)
        tracked = lambda: next(t for t in self.call("test.ui")["tabs"] if t["id"] == tab)["documentKey"]
        self.call("test.previewHold", {"on": True})
        self.assertEqual(self.capture(tab), "held")
        self.navigate(tab, titled("rollback-two"))
        current = bs.wait_until(lambda: (lambda k: k if k != self.preview_of(tab)[1] else None)(tracked()),
                                what="the tracked key to follow the navigation")
        self.assertEqual(current, self.observed_key(tab))
        self.call("test.previewRelease")
        bs.wait_until(lambda: self.previews()["log"][-1]["outcome"] == "rejectedStale",
                      what="the held capture decided")
        self.assertEqual(tracked(), self.observed_key(tab))

    def test_a_held_capture_of_the_same_document_is_accepted(self):
        tab = self.open_page("same")
        self.call("test.previewHold", {"on": True})
        self.assertEqual(self.capture(tab), "held")
        self.call("test.previewRelease")
        state = bs.wait_until(lambda: (lambda s: s if s["count"] == 1 else None)(self.previews()),
                              what="the held capture stored")
        self.assertEqual((state["captures"], state["rejectedStale"]), (1, 0))
        self.assertEqual(self.preview_of(tab)[0], "fresh")

    def test_a_capture_for_a_page_closed_meanwhile_creates_no_preview(self):
        keep = self.open_page("keep")
        gone = self.open_page("gone")
        node = self.node_of(gone)["id"]
        self.call("test.previewHold", {"on": True})
        self.assertEqual(self.capture(gone), "held")
        self.call("test.closeTab", {"tabId": gone})
        bs.wait_until(lambda: gone not in self.tab_ids(), what="the tab closed")
        self.call("test.previewRelease")
        state = bs.wait_until(
            lambda: (lambda s: s if s["log"] and s["log"][-1]["outcome"] == "rejectedStale" else None)(
                self.previews()),
            what="the held capture decided")
        self.assertEqual((state["count"], state["bytes"], state["rejectedStale"]), (0, 0, 1))
        archived = next(n for n in self.nodes() if n["id"] == node)
        self.assertEqual((archived["kind"], archived["previewState"]), ("archived", "none"))
        self.assertIn(keep, self.tab_ids())


class BoundTests(PreviewCase):
    def test_lowered_limits_bound_count_and_bytes_after_every_insertion(self):
        limits = self.call("test.previews", {"limits": {"count": 4, "bytes": 2 * MIB}})["limits"]
        self.assertEqual(limits, {"count": 4, "bytes": 2 * MIB})
        tabs = [self.open_page(f"p{n}") for n in range(6)]
        for tab in tabs:
            self.focus(tab)
            self.assertEqual(self.capture(tab, width=300, height=200), "stored")
            state = self.previews()
            self.assertLessEqual(state["count"], 4)
            self.assertLessEqual(state["bytes"], 2 * MIB)
        state = self.previews()
        self.assertEqual((state["count"], state["evictions"]), (4, 2))
        # Least recently used first: the two oldest captures are gone.
        self.assertEqual([self.preview_of(t)[0] for t in tabs], ["none"] * 2 + ["fresh"] * 4)
        sizes = [(r["width"], r["height"]) for r in state["log"] if r["outcome"] == "stored"]
        self.assertEqual(state["bytes"], sum(w * h * 4 for w, h in sizes[2:]))

    def test_a_card_larger_than_the_byte_limit_is_refused(self):
        self.call("test.previews", {"limits": {"count": 4, "bytes": 100_000}})
        tab = self.open_page("big")
        self.assertEqual(self.capture(tab), "tooLarge")
        self.assertEqual((self.previews()["count"], self.previews()["bytes"]), (0, 0))

    def test_the_shipped_limits_are_64_previews_and_48_mib(self):
        self.assertEqual(self.previews()["limits"], {"count": 64, "bytes": 48 * MIB})

    def test_an_archived_page_keeps_its_preview(self):
        tab = self.open_page("archived")
        self.capture(tab)
        self.call("test.closeTab", {"tabId": tab})
        bs.wait_until(lambda: self.nodes()[0]["kind"] == "archived", what="archived")
        self.assertEqual(self.previews()["count"], 1)
        self.assertEqual(self.nodes()[0]["previewState"], "fresh")


class MemoryOnlyTests(PreviewCase):
    def scan(self, root, skip):
        found = []
        walk = [(os.path.dirname(root), [], [os.path.basename(root)])] if os.path.isfile(root) \
            else os.walk(root)
        for base, dirs, files in walk:
            dirs[:] = [d for d in dirs if os.path.join(base, d) not in skip]
            for name in files:
                path = os.path.join(base, name)
                try:
                    with open(path, "rb") as handle:
                        head = handle.read(12)
                except OSError:
                    continue
                if any(head.startswith(m) for m in IMAGE_MAGICS) or head[4:8] == b"ftyp" \
                        or head[8:12] == b"WEBP":
                    found.append(path)
        return found

    def test_previews_are_never_written_to_disk(self):
        tmp = tempfile.gettempdir()
        before = set(os.listdir(tmp))
        tabs = [self.open_page(f"disk-{n}") for n in range(10)]
        for tab in tabs:
            self.focus(tab)
            self.assertEqual(self.capture(tab), "stored")
        self.assertEqual(self.previews()["count"], 10)
        bs.wait_until(lambda: self.db("SELECT count(*) FROM canvas_nodes") == [(10,)],
                      what="the graph saved")
        for table in ("canvas_nodes", "canvas_edges", "canvas_meta"):
            schema = self.db(f"SELECT type FROM pragma_table_info('{table}')")
            self.assertFalse(any("BLOB" in t[0].upper() for t in schema), table)
        self.assertEqual(self.db("SELECT count(*) FROM canvas_nodes WHERE length(url) > 1024 "
                                 "OR length(title) > 1024 OR typeof(url) = 'blob' "
                                 "OR typeof(title) = 'blob'"), [(0,)])
        self.assertEqual(self.db("SELECT count(*) FROM canvas_meta WHERE length(value) > 1024 "
                                 "OR typeof(value) = 'blob'"), [(0,)])
        listing = subprocess.run(["lsof", "-p", str(self.app.proc.pid), "-Fn"],
                                 capture_output=True, text=True)
        self.assertEqual(listing.returncode, 0)
        lsof = listing.stdout
        profile = os.path.join(self.data_dir, "profile")
        opened = [line[1:] for line in lsof.splitlines() if line.startswith("n/")]
        images = [p for p in opened if p.lower().endswith((".jpg", ".jpeg", ".png", ".webp", ".heic"))
                  and not p.startswith(profile)]
        self.assertEqual(images, [])
        app = self.app
        type(self).app = None
        app.stop(remove_data=False)
        self.assertEqual(self.scan(self.data_dir, {profile}), [])
        fresh = [os.path.join(tmp, n) for n in set(os.listdir(tmp)) - before]
        self.assertEqual([p for root in fresh for p in self.scan(root, set())], [])


if __name__ == "__main__":
    unittest.main()
