"""The running app against the Spatial Daylight compositions: the overview's trails and framing
(frame 777:24), the dotted trails of the focused page in context (777:642) and the launcher
field's single weight (777:182, 777:422)."""
import bs
import png
from appcase import LOG_DIR
from test_focus import FocusCase

TRAIL = png.hex_rgb("c0c4b9")
WINDOW = (1440, 900)


def contains(rect, x, y, slack=0.0):
    return (rect["x"] - slack <= x <= rect["x"] + rect["w"] + slack
            and rect["y"] - slack <= y <= rect["y"] + rect["h"] + slack)


def curve(trail, steps=24):
    s, c, e = trail["start"], trail["control"], trail["end"]
    for i in range(steps + 1):
        t = i / steps
        yield tuple((1 - t) ** 2 * s[a] + 2 * (1 - t) * t * c[a] + t * t * e[a] for a in "xy")


class FidelityCase(FocusCase):
    def shot(self, name):
        bs.wait_until(lambda: not self.call("test.motion")["inFlight"], what="motion at rest")
        path = f"{LOG_DIR}/{name}.png"
        self.call("test.screenshot", {"path": path})
        image = png.Image(path)
        return image, image.width / self.ui()["windowFrame"]["w"]

    def sample(self, shot, x, y):
        image, scale = shot
        return image.pixel(int(x * scale), int(y * scale))

    def count(self, shot, x0, y0, x1, y1, wanted, tolerance=10):
        """Pixels in the box (window points) within `tolerance` of `wanted`."""
        return sum(png.close(self.sample(shot, x, y), wanted, tolerance)
                   for x in range(int(x0), int(x1)) for y in range(int(y0), int(y1)))

    def linked_group(self, count):
        opener = self.open_page("Opener", "popups.html")
        self.popups(opener, count)
        return opener

    def cards(self):
        def settled():
            nodes = self.ui()["overview"]["nodes"]
            return nodes if len(nodes) == len(self.nodes()) else None
        return {n["id"]: n["frame"] for n in bs.wait_until(settled, what="every card drawn")}


class OverviewTests(FidelityCase):
    def assert_centred(self, cards):
        boxes = list(cards.values())
        left = min(f["x"] for f in boxes)
        right = max(f["x"] + f["w"] for f in boxes)
        top = min(f["y"] for f in boxes)
        bottom = max(f["y"] + f["h"] for f in boxes)
        self.assertAlmostEqual((left + right) / 2, WINDOW[0] / 2, delta=24, msg=(left, right))
        self.assertAlmostEqual((top + bottom) / 2, WINDOW[1] / 2, delta=70, msg=(top, bottom))
        self.assertGreaterEqual(left, 0)
        self.assertLessEqual(right, WINDOW[0])
        self.assertGreaterEqual(top, 0)
        self.assertLessEqual(bottom, WINDOW[1])

    def test_linked_pages_are_centred_with_trails_between_the_cards(self):
        opener = self.linked_group(5)
        self.show_overview()
        cards = self.cards()
        self.assertEqual(len(cards), 6)
        self.assert_centred(cards)
        zoom = self.canvas()["viewport"]["zoom"]
        hub = self.node_of(opener)["id"]
        shot = self.shot("fidelity-overview")
        beside = [(i, f) for i, f in cards.items() if i != hub
                  and abs(f["y"] - cards[hub]["y"]) < 40 and f["x"] > cards[hub]["x"]]
        self.assertTrue(beside, "a neighbour in the hub's row")
        other = min(beside, key=lambda item: item[1]["x"])[1]
        left, right = cards[hub]["x"] + cards[hub]["w"], other["x"]
        self.assertGreaterEqual(right - left, 80 * zoom - 1, "room for the trail between cards")
        dots = self.count(shot, left + 2, cards[hub]["y"], right - 2,
                          cards[hub]["y"] + cards[hub]["h"], TRAIL, tolerance=24)
        self.assertGreaterEqual(dots, 12, f"{dots} trail pixels between the two cards")
        for edge in self.ui()["overview"]["edges"]:
            self.assertEqual((edge["color"], edge["width"], edge["dash"], edge["cap"]),
                             ("c0c4b9", 1.25, [1, 7], "round"))

    def test_zoom_to_fit_centres_the_group_again(self):
        self.linked_group(5)
        self.show_overview()
        self.assert_centred(self.cards())
        self.call("test.scroll", {"dx": 420, "dy": 260})
        bs.wait_until(lambda: self.canvas()["viewport"]["cx"] < -100, what="the camera moved")
        with self.assertRaises(AssertionError):
            self.assert_centred(self.cards())
        self.key("0", "cmd")
        bs.wait_until(lambda: abs(self.canvas()["viewport"]["cx"]) < 400, what="the camera fitted")
        self.assert_centred(self.cards())

    def test_a_lone_page_stays_card_sized_and_centred(self):
        self.open_page("Only page")
        self.show_overview()
        cards = self.cards()
        self.assert_centred(cards)
        (frame,) = cards.values()
        self.assertAlmostEqual(frame["w"], 220, delta=1)


class FocusTrailTests(FidelityCase):
    def test_side_column_cards_are_joined_to_the_page_by_dotted_trails(self):
        self.linked_group(3)
        self.show_page()
        focus = self.focus_state()
        card = focus["card"]
        columns = {c["id"]: c for c in focus["left"] + focus["right"]}
        trails = focus["trails"]
        self.assertEqual(sorted(t["node"] for t in trails), sorted(columns))
        shot = self.shot("fidelity-focus")
        for trail in trails:
            self.assertEqual((trail["color"], trail["width"], trail["dash"], trail["cap"]),
                             ("c0c4b9", 1.25, [1, 7], "round"), trail)
            column = columns[trail["node"]]["frame"]
            left_side = column["x"] < card["x"]
            edge = column["x"] + column["w"] if left_side else column["x"]
            self.assertAlmostEqual(trail["start"]["x"], edge, delta=1)
            self.assertTrue(contains(column, trail["start"]["x"], trail["start"]["y"], slack=1))
            self.assertTrue(card["y"] <= trail["end"]["y"] <= card["y"] + card["h"])
            for x, y in curve(trail):
                self.assertFalse(contains(card, x, y), f"trail enters the live page at {x:.0f},{y:.0f}")
            gap = (card["x"] - edge, edge - card["x"] - card["w"])[not left_side]
            self.assertGreater(gap, 40)
            x0, x1 = sorted((trail["start"]["x"], trail["end"]["x"]))
            y0, y1 = sorted((trail["start"]["y"], trail["end"]["y"]))
            dots = self.count(shot, x0, y0 - 16, x1, y1 + 16, TRAIL, tolerance=24)
            self.assertGreaterEqual(dots, 8, f"{dots} trail pixels for {trail['node']}")
        # Along the live page's border, inside it, nothing of a trail shows.
        inside = self.count(shot, card["x"] + 3, card["y"] + 3, card["x"] + 12,
                            card["y"] + card["h"] - 3, TRAIL, tolerance=6)
        self.assertEqual(inside, 0)
        inside = self.count(shot, card["x"] + card["w"] - 12, card["y"] + 3,
                            card["x"] + card["w"] - 3, card["y"] + card["h"] - 3, TRAIL, tolerance=6)
        self.assertEqual(inside, 0)

    def test_a_page_without_connections_draws_no_trails(self):
        self.open_page("No edges")
        self.show_page()
        self.assertEqual(self.focus_state()["trails"], [])


class LauncherFieldTests(FidelityCase):
    def editor(self):
        return self.ui()["chrome"]["text"]["launcherEditor"]

    def test_typed_text_has_one_font_one_weight_and_the_fonts_own_spacing(self):
        self.key("t", "cmd")
        bs.wait_until(lambda: self.ui()["firstResponder"].get("chromeId") == "launcherField",
                      what="the field focused")
        for text in ("Find a quiet hotel in Kyoto under $200 a night", "night under quiet hotel"):
            self.fill_launcher(text)
            editor = self.editor()
            self.assertEqual(len(editor["runs"]), 1, editor)
            (run,) = editor["runs"]
            self.assertEqual((run["size"], run["weight"]), (18, 400), run)
            self.assertIn("Manrope", run["name"])
            self.assertEqual(editor["typing"], run)
            self.assertTrue(editor["idealMetrics"])

    def test_replacing_a_long_query_leaves_no_trace_of_it(self):
        self.key("t", "cmd")
        bs.wait_until(lambda: self.ui()["firstResponder"].get("chromeId") == "launcherField",
                      what="the field focused")
        self.fill_launcher("Find a quiet hotel in Kyoto under $200 a night")
        self.fill_launcher("Hi")
        panel = png.hex_rgb("fffefa")
        shot = self.shot("fidelity-launcher-replaced")
        stale = [(x, y) for x in range(480, 1030) for y in range(150, 210)
                 if not png.close(self.sample(shot, x, y), panel, 6)]
        self.assertEqual(stale, [])
