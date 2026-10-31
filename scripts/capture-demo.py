#!/usr/bin/env python3
"""Drives the bundled Photon through the demo shot list and saves frames of its own window.

Every frame is `test.screenshot` (the app's window content; nothing else on the screen can appear).
Pages are real public sites opened through the launcher or a real ⌘-click on a link (not on
Wikipedia, whose hover cards would cover the page). Every Muse run uses the real model
(`muse-spark-1.3`). The approval and the takeover run on the harmless permission fixture
(`fixtures/perm.html`, served from 127.0.0.1).

  set -a; . ./.env; set +a; BARESTATE_LIVE_META=1 BARESTATE_SPEND_LOG=$PWD/.logs/spend.json \
    python3 scripts/capture-demo.py --frames /tmp/bs-demo-frames --stills docs/screenshots

Writes <frames>/capture.tsv (UTC time, offset seconds, file, what, seconds to hold in the video) and
the four README stills. scripts/make-video.swift turns the TSV into the video.
"""
import argparse
import json
import os
import shutil
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "e2e"))
import bs  # noqa: E402

PAGES = {
    "kyoto": "https://en.wikipedia.org/wiki/Kyoto",
    "tokyo": "https://en.wikipedia.org/wiki/Tokyo",
    "example": "https://example.com/",
    "python": "https://www.python.org/",
}
REQUEST = ("Compare this Kyoto page with the Tokyo page open in another tab. Read both, then tell me "
           "in two sentences how the cities differ. Do not click or type anything.")
APPROVAL_REQUEST = "Click the Delete draft button on this page, then tell me what the status line says."
ENDED = ("completed", "failed", "stopped")


class Capture:
    def __init__(self, app, frames):
        self.app, self.frames = app, frames
        self.began = time.time()
        self.rows = []
        os.makedirs(frames, exist_ok=True)

    def call(self, method, params=None):
        return self.app.call(method, params)

    def ui(self):
        return self.call("test.ui")

    def key(self, key, *modifiers):
        self.call("test.key", {"key": key, "modifiers": list(modifiers)})

    def shot(self, name, what, hold=2.5):
        path = os.path.join(self.frames, f"{len(self.rows):03d}-{name}.png")
        self.call("test.screenshot", {"path": path})
        now = time.time()
        self.rows.append((datetime.fromtimestamp(now, timezone.utc).isoformat(timespec="milliseconds"),
                          round(now - self.began, 2), path, what, hold))
        return path

    def settle(self):
        bs.wait_until(lambda: not self.call("test.motion")["inFlight"], what="motion at rest")

    def watch(self, name, what, until, every=1.0, hold=0.5, timeout=150):
        """A frame about every `every` seconds until `until()` holds."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.shot(name, what, hold)
            if until():
                return
            time.sleep(every)
        raise SystemExit(f"timed out waiting for: {what}")

    def write_log(self):
        with open(os.path.join(self.frames, "capture.tsv"), "w") as log:
            for row in self.rows:
                log.write("\t".join(str(v) for v in row) + "\n")

    def tab(self, url_part):
        return next((t for t in self.call("tabs")["tabs"] if url_part in t["url"]), None)

    def open_through_launcher(self, address):
        self.key("t", "cmd")
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the launcher")
        self.call("test.type", {"text": address})
        bs.wait_until(lambda: (lambda s: s["current"] and s["query"] == address)(self.ui()["launcher"]),
                      what="launcher rows")
        self.key("Return")
        where = address.split("//")[-1]
        tab = bs.wait_until(lambda: (lambda t: t if t and not t["loading"] and t["title"] else None)(
            self.tab(where)), timeout=60, what=f"{address} loaded")
        bs.wait_until(lambda: not self.ui()["launcher"]["open"], what="the launcher to close")
        self.ensure_preview(tab["id"])
        return tab["id"]

    def ensure_preview(self, tab):
        """The automatic capture runs once the page settles; ask for the same capture if it is late."""
        def fresh():
            return any(n["tabId"] == tab and n["previewState"] == "fresh"
                       for n in self.ui()["canvas"]["nodes"])
        try:
            bs.wait_until(fresh, timeout=15, what="the automatic preview")
        except TimeoutError:
            self.call("test.previewCapture", {"tabId": tab})
            bs.wait_until(fresh, timeout=15, what="a requested preview")

    def evaluate(self, tab, expression):
        return self.call("test.devtools", {"tabId": tab, "method": "Runtime.evaluate", "params": {
            "expression": expression, "returnByValue": True}})["result"]["value"]

    def link_point(self, tab, selector):
        """Centre of the first matching link, scrolled into view, in the page's own coordinates."""
        return self.evaluate(tab, f"""(() => {{ const a = [...document.querySelectorAll({json.dumps(selector)})]
              .find(a => a.getBoundingClientRect().width > 0);
            a.scrollIntoView({{block: 'center'}}); const r = a.getBoundingClientRect();
            return [r.x + r.width / 2, r.y + r.height / 2]; }})()""")

    def open_link_in_background(self, tab, selector):
        """A real ⌘-click on a link: the page opens in a background tab with an openedFrom edge."""
        x, y = self.link_point(tab, selector)
        known = {t["id"] for t in self.call("tabs")["tabs"]}
        self.call("test.click", {"target": tab, "x": x, "y": y, "modifiers": ["cmd"]})
        linked = bs.wait_until(lambda: next((t["id"] for t in self.call("tabs")["tabs"]
                                             if t["id"] not in known and not t["loading"]), None),
                               timeout=60, what="the linked page")
        # A page opened in the background has no preview until it has been shown once.
        self.call("test.activateTab", {"tabId": linked})
        self.settle()
        self.ensure_preview(linked)
        self.call("test.activateTab", {"tabId": tab})
        self.settle()
        return linked

    def grant(self, session, tab):
        request = self.call("request_control", {"sessionId": session, "tabId": tab})
        if request["state"] != "granted":
            self.call("control.decide", {"requestId": request["requestId"], "allow": True})

    def start_task_row(self, query):
        self.key("t", "cmd")
        bs.wait_until(lambda: self.ui()["launcher"]["open"], what="the launcher")
        self.call("test.type", {"text": query})
        bs.wait_until(lambda: (lambda s: s["current"] and s["query"] == query)(self.ui()["launcher"]),
                      what="request rows")
        return next(r for r in self.ui()["launcher"]["rows"] if r["kind"] == "startTask")

    def ask_and_wait_for_card(self, request, name, reset=lambda: None, attempts=3):
        """Starts a task from the launcher on the active page and waits for the approval card.
        The model decides whether to click, so a run that ends without asking is started again."""
        for attempt in range(attempts):
            reset()
            before = len(self.call("run.list")["runs"])
            row = self.start_task_row(request)
            self.call("test.click", {"target": f"launcherRow:{row['id']}"})
            run = bs.wait_until(lambda: (lambda r: r[-1] if len(r) > before else None)(
                self.call("run.list")["runs"]), what="the run")

            def card():
                c = self.ui()["approval"]
                return c.get("visible") and c["allow"]["hittable"] \
                    and not self.call("test.motion")["inFlight"]
            self.watch(name, "the run works, then asks",
                       lambda: card() or self.run_of(run["runId"])["state"] in ENDED, every=0.8, timeout=120)
            if card():
                return run
            ended = self.run_of(run["runId"])
            print(f"run {run['runId']} ended without asking: {ended['state']} {ended.get('reason')}", file=sys.stderr)
        raise SystemExit("no run asked for approval")

    def run_of(self, run_id):
        return next(r for r in self.call("run.list")["runs"] if r["runId"] == run_id)


def spend_total(path):
    if not os.path.exists(path):
        return 0.0
    with open(path) as f:
        return json.load(f)["total_usd"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", default="/tmp/bs-demo-frames")
    parser.add_argument("--stills", default=os.path.join(os.path.dirname(HERE), "docs", "screenshots"))
    parser.add_argument("--data-dir", default="/tmp/bs-demo", help="disposable: the harness deletes it before launch")
    args = parser.parse_args()
    ledger = os.environ.get("BARESTATE_SPEND_LOG")
    if os.environ.get("BARESTATE_LIVE_META") != "1" or not ledger:
        raise SystemExit("needs BARESTATE_LIVE_META=1 and BARESTATE_SPEND_LOG (a live Muse run)")
    spent0 = spend_total(ledger)
    if spent0 >= 40:
        raise SystemExit(f"mission spend is {spent0}: stop")
    os.makedirs(args.stills, exist_ok=True)
    os.makedirs(os.path.dirname(ledger), exist_ok=True)
    fixtures = bs.Fixtures(args.frames + "-fixtures")
    fixtures.start()
    app = bs.App(args.data_dir, args.frames + "-logs", "demo").start()
    cap = Capture(app, args.frames)
    try:
        cap.call("test.windowSize", {"w": 1440, "h": 900})
        cap.shot("empty", "first launch: the empty canvas, before any page", 2)

        # Real pages: typed into the launcher, then a real ⌘-click on a link in example.com.
        kyoto = cap.open_through_launcher(PAGES["kyoto"])
        cap.shot("kyoto", "Kyoto (en.wikipedia.org) opened from the launcher", 1.5)
        tokyo = cap.open_through_launcher(PAGES["tokyo"])
        example = cap.open_through_launcher(PAGES["example"])
        cap.open_link_in_background(example, "a[href]")
        python = cap.open_through_launcher(PAGES["python"])
        cap.open_link_in_background(python, 'a[href^="/downloads/"]')

        # 1. Overview: the pages as cards with their captured previews and the trails between them.
        cap.call("test.activateTab", {"tabId": kyoto})
        cap.settle()
        cap.key("\\", "cmd", "shift")
        bs.wait_until(lambda: cap.ui()["presentation"] == "overview", what="the overview")
        cap.settle()
        live = lambda: [n for n in cap.ui()["overview"]["nodes"] if n["subtitle"].startswith("Live")]
        bs.wait_until(lambda: len(live()) >= 6 and all(n["hasImage"] for n in live()), timeout=60,
                      what="every card's preview")
        cap.settle()
        overview = cap.shot("overview", "overview canvas: six real pages, real previews and trails", 4)

        # 2. ⌘T suggestions from the overview.
        cap.key("t", "cmd")
        bs.wait_until(lambda: cap.ui()["launcher"]["open"] and cap.ui()["launcher"]["current"],
                      what="the launcher")
        cap.settle()
        suggestions = cap.shot("suggestions", "⌘T: Continue, Suggested and Browser rows", 4)
        cap.key("Escape")
        bs.wait_until(lambda: not cap.ui()["launcher"]["open"], what="the launcher to close")

        # 3. A typed request. The model is held until the Tokyo page is granted to the run.
        row = cap.start_task_row(REQUEST)
        cap.settle()
        typed = cap.shot("typed-request", "a typed request: Start task and Search the web", 4)
        cap.call("test.holdModel", {"on": True})
        cap.call("test.click", {"target": f"launcherRow:{row['id']}"})
        run = bs.wait_until(lambda: (cap.call("run.list")["runs"] or [None])[-1], what="the run")
        cap.grant(run["sessionId"], tokyo)
        cap.call("test.holdModel", {"on": False})
        node = next(n["id"] for n in cap.ui()["overview"]["nodes"] if n["title"].startswith("Kyoto -"))
        cap.call("test.click", {"target": f"node:{node}"})

        # 4. The focused page with its Muse label, then the copper trail once Muse read Tokyo.
        label = lambda: cap.ui()["focus"]["museLabel"]["text"]
        cap.watch("muse-run", "focused page: Muse label while the run works",
                  lambda: cap.run_of(run["runId"])["state"] in ENDED or label() == "Muse · working", every=0.4)
        trail = lambda: any(e["runId"] == run["runId"] for e in cap.ui()["canvas"]["edges"])
        cap.watch("muse-run", "focused page: the run reads the Tokyo page", lambda: trail()
                  or cap.run_of(run["runId"])["state"] in ENDED, every=0.8)
        cap.settle()
        cap.watch("muse-run", "the run finishes", lambda: cap.run_of(run["runId"])["state"] in ENDED, every=1.0)
        ended = cap.run_of(run["runId"])
        if ended["state"] != "completed":
            raise SystemExit(f"the Kyoto run did not complete: {ended}")
        cap.settle()
        focused = cap.shot("focused-page", "focused page in context with the Muse label and the trail", 5)
        if cap.ui()["presentation"] != "focused" or not trail():
            raise SystemExit("the focused page or its trail is missing")

        # 5. Approval: a sensitive click waits for Allow once. A fixture page, never a logged-in one.
        perm_url = f"{bs.FIXTURE_URL}/perm.html"
        perm = cap.open_through_launcher(perm_url)
        cap.settle()
        cap.shot("approval-page", "the fixture page before the request", 1.5)
        second = cap.ask_and_wait_for_card(APPROVAL_REQUEST, "approval")
        card = cap.shot("approval", "approval card: Muse waits for Allow once", 4)
        cap.call("test.click", {"target": "approvalAllow"})
        cap.watch("approved", "Allow once: the click lands and the run finishes",
                  lambda: cap.run_of(second["runId"])["state"] in ENDED, every=0.8, timeout=90)
        cap.settle()
        cap.shot("approved", "after Allow once", 2.5)
        if cap.run_of(second["runId"])["state"] != "completed":
            raise SystemExit(f"the approval run did not complete: {cap.run_of(second['runId'])}")

        # 6. Takeover: the person clicks the page while a second request waits for approval.
        def reload_fixture():
            cap.call("test.devtools", {"tabId": perm, "method": "Page.navigate", "params": {"url": perm_url}})
            bs.wait_until(lambda: not cap.tab("127.0.0.1")["loading"], what="the fixture reloaded")
        third = cap.ask_and_wait_for_card(APPROVAL_REQUEST, "takeover", reset=reload_fixture)
        cap.shot("takeover-waiting", "a second request waits for approval", 3)
        cap.call("test.click", {"tabId": perm})
        cap.watch("taken-over", "the person clicked the page: Muse stops",
                  lambda: cap.run_of(third["runId"])["state"] == "stopped", every=0.3, timeout=20)
        cap.settle()
        cap.shot("taken-over", "takeover: the run stopped, the card left, nothing deleted", 4)
        if cap.run_of(third["runId"])["reason"] != "taken-over":
            raise SystemExit(f"not a takeover: {cap.run_of(third['runId'])}")

        for name, source in (("overview", overview), ("suggestions", suggestions),
                             ("typed-request", typed), ("focused-page", focused)):
            shutil.copyfile(source, os.path.join(args.stills, f"{name}.png"))
        cap.write_log()
        print(json.dumps({"frames": len(cap.rows), "spent_usd": round(spend_total(ledger) - spent0, 6),
                          "approval_frame": card}))
    finally:
        cap.write_log()
        app.stop()
        fixtures.stop()


if __name__ == "__main__":
    main()
