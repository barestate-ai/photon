#!/usr/bin/env python3
"""Startup and memory budgets, measured on the real bundle (make bundle first).

  python3 scripts/bench.py [cold-start|cefclient-baseline|footprint|footprint-20|launcher|overview|frontend|all] [--runs 10] [--first-launch-runs 3]
                           [--footprint-runs 3] [--out .logs/bench-startup.json]

cold-start: harness wall clock before spawn -> the fixture page's first paint (fixtures/fp.html
reports performance.timeOrigin + first-paint in epoch ms). "first_launch" re-bundles (re-signs)
before every launch; "warm" is the launches after that, each with a fresh data dir.

cefclient-baseline: the same measurement for the vendored Vendor/cefclient.app, cloned and ad-hoc
re-signed before each first launch (temp --root-cache-path, same fixture page). It shows how much
of a first launch is the OS assessing a new signature rather than this app. Not part of `all`.

footprint: one fixture tab, settled 3 s, summed `footprint` of the app and every descendant,
against Chrome on its own temp --user-data-dir loading the same page. Only PIDs this script
started are measured or killed. Raw `footprint -j` output lands in <out dir>/bench-startup/.

launcher: Cmd-T to a usable launcher (key-down at sendEvent to a laid-out panel with the field
focused) and each keystroke to the rows of its generation, read from the app's own clock through
test.launcherTimings. Dataset: 12 loaded pages with previews, 10,000 history rows (the newest 50
are the recents), 1,000 bookmarks, model offline, 1440x900; 20 + 200 opens alternating a focused
page and the overview, 30 + 300 suggestion updates. Needs the test-hooks bundle and is not part
of `all`.

frontend: with exactly 20 live pages (the app's blank tab is closed once they are open) holding
previews at 1440x900, the overview toggle (Cmd-Shift-\\
key-down to a settled presentation, Reduce Motion on, 20 + 100 alternating toggles, test.toggleTimings)
and the pan frame interval (5 x 2 s of overview scrolling, one test.scroll-sized step per
display-link tick in its own transaction, the interval being the time between the commits of
consecutive steps from test.frameProbe, at least 500 intervals), and for every leaving toggle the
capture's duration and whether it finished after the camera or swap began (it must not, and the
deadline must not be hit); then the 20-page footprint with a full preview cache,
overview showing and settled 3 s, against Chrome on the same 20 URLs (--footprint-runs, 5 for the
contract). The cefclient figures are never re-measured here. Not part of `all`.

footprint-20: only the 20-page footprint of `frontend`. With --real-pages the 20 pages are public
sites fetched over the network (REAL_PAGES) instead of fixtures. Photon waits for each page's load
flag, Chrome (no load hook here) for a fixed 30 s after launch; then both sit 30 s, then the usual
3 s settle.

Chromium leaves a ~650 MB `<bundle id>.code_sign_clone` copy of a re-signed bundle on any exit
that is not clean, so every run deletes the clone entries of the bundle it launches (cefclient
for cefclient-baseline, Barestate otherwise) that appeared during it. e2e/test_bench.py runs
the real cefclient only with BARESTATE_BENCH_CEFCLIENT=1.

Percentiles are nearest-rank (ceil(0.95 * n)). Exits 1 when a budget is missed; the report is
written either way.
"""
import argparse
import contextlib
import glob
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "e2e"))
import bs  # noqa: E402

PAGE_URL = f"{bs.FIXTURE_URL}/fp.html"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CEFCLIENT = os.path.join(bs.ROOT, "Vendor", "cefclient.app")
CLONE_ROOT = os.path.join(
    subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip(), "..", "X")
CEFCLIENT_ID = "org.cef.cefclient"
MIB = 1024 * 1024
COLD_START_BUDGET_MS = 1500
MIN_WARM_RUNS = 10
FOOTPRINT_BUDGET_MIB = 400
SETTLE_SECONDS = 3
LAUNCHER_BUDGET_MS = 50
LAUNCHER_OPENS = (20, 200)
LAUNCHER_UPDATES = (30, 300)
LAUNCHER_PAGES = 12
LAUNCHER_RECENTS = 50
FRONTEND_PAGES = 20
TOGGLE_SAMPLES = (20, 100)
TOGGLE_BUDGET_MS = 100
PAN_REPEATS = 5
PAN_SECONDS = 2
PAN_MIN_INTERVALS = 500
PAN_BUDGET_MS = 20
LAUNCHER_QUERIES = ("kyoto", "kyoto hotels", "example site", "find a quiet hotel in kyoto",
                    "page 99", "https://example.com/a", "stay", "t")


def summarize(values):
    return {"values": values, "n": len(values), "p50": statistics.median(values),
            "p95": bs.nearest_rank(values, 0.95), "p99": bs.nearest_rank(values, 0.99),
            "min": min(values), "max": max(values)}


def paint_epoch_ms(log, since):
    """First-paint epoch ms from the first fp beacon after log line `since`, else None."""
    for line in log[since:]:
        if "/__beacon?fp=" in line:
            return float(line.split("fp=")[1].split()[0])
    return None


def processes_of(document):
    if document.get("errors"):
        raise RuntimeError(f"footprint reported errors: {document['errors']}")
    return [(p["name"], p["pid"], p["footprint"]) for p in document["processes"]]


def measure_footprint(pids, raw_path):
    """[(name, pid, bytes)] for exactly `pids`; keeps footprint's own JSON at `raw_path`."""
    args = ["footprint", "-j", raw_path]
    for pid in pids:
        args += ["-p", str(pid)]
    subprocess.run(args, check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    with open(raw_path) as raw:
        processes = processes_of(json.load(raw))
    missing = set(pids) - {pid for _, pid, _ in processes}
    if missing:
        raise RuntimeError(f"footprint did not report pids {sorted(missing)}")
    return processes


def wait_for_paint(fixtures, since, what):
    return bs.wait_until(lambda: paint_epoch_ms(fixtures.log(), since), 30, what=what)


def launch_to_paint_ms(fixtures, data_dir, log_dir, label):
    since = len(fixtures.log())
    # One data dir per launch, so the logs copied out of each are not overwritten by the next.
    app = bs.App(f"{data_dir}-{label}", log_dir, label, test_hooks=False, url=PAGE_URL)
    started_ms = time.time() * 1000
    try:
        app.start()
        return wait_for_paint(fixtures, since, f"{label} first paint") - started_ms
    finally:
        app.stop()


def cold_start(fixtures, args, work):
    data_dir = os.path.join(work, "cold")
    log_dir = os.path.join(work, "logs")
    first = []
    for i in range(args.first_launch_runs):
        subprocess.run([os.path.join(HERE, "bundle.sh")], check=True, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        first.append(round(launch_to_paint_ms(fixtures, data_dir, log_dir, f"first-{i}"), 1))
    # The first launch after any (re-)signing is slow, so it never counts as a warm launch.
    warmup = round(launch_to_paint_ms(fixtures, data_dir, log_dir, "warmup"), 1)
    warm = [round(launch_to_paint_ms(fixtures, data_dir, log_dir, f"warm-{i}"), 1)
            for i in range(args.runs)]
    result = {"warmup_ms": warmup, "warm": summarize(warm), "budget_ms": COLD_START_BUDGET_MS,
              "pass": len(warm) >= MIN_WARM_RUNS and statistics.median(warm) < COLD_START_BUDGET_MS}
    if first:
        result["first_launch"] = summarize(first)
        result["first_launch_extra_ms"] = round(result["first_launch"]["p50"] - result["warm"]["p50"], 1)
    return result


def code_sign_clone_entries(root, bundles):
    """Every entry in the clone directories of the given bundle ids."""
    entries = set()
    for bundle in bundles:
        directory = os.path.join(root, f"{bundle}.code_sign_clone")
        if os.path.isdir(directory) and not os.path.islink(directory):
            entries.update(os.path.join(directory, name) for name in os.listdir(directory))
    return entries


@contextlib.contextmanager
def reaping_code_sign_clones(bundles, root=None):
    """Removes the code-sign clones of `bundles` that appeared while the block ran.

    Chromium copies a launched bundle into <DARWIN_USER_TEMP_DIR>/../X/<id>.code_sign_clone/
    and removes the copy only on a clean exit; a re-signed ~650 MB bundle is copied on each
    first launch. Entries that existed beforehand are never touched. Entry names are random, so
    a clone from another launch of the same bundle id during the block is indistinguishable
    and also removed: do not launch the same bundle id elsewhere while a bench runs.
    """
    root = root or CLONE_ROOT
    before = code_sign_clone_entries(root, bundles)
    try:
        yield
    finally:
        for path in code_sign_clone_entries(root, bundles) - before:
            if os.path.islink(path) or not os.path.isdir(path):
                os.remove(path)
            else:
                shutil.rmtree(path, ignore_errors=True)


def bundles_to_reap(what):
    """Only cefclient leaves clones. Barestate exits cleanly, and its bundle id may also name the
    user's own running copy, whose clone must never be deleted."""
    return (CEFCLIENT_ID,) if what == "cefclient-baseline" else ()


def stop_tree(proc):
    """Terminates a process this script started and every helper it spawned."""
    # Helpers are reparented once the parent exits, so they are collected first.
    children = bs.descendants(proc.pid)
    proc.terminate()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
    for pid in children:
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass


def resigned_cefclient(work, name):
    """A fresh APFS clone of the vendored cefclient.app, ad-hoc signed inside-out like bundle.sh."""
    app = os.path.join(work, name, "cefclient.app")
    os.makedirs(os.path.dirname(app))
    subprocess.run(["cp", "-c", "-R", os.path.realpath(CEFCLIENT), app], check=True)
    frameworks = os.path.join(app, "Contents", "Frameworks")
    framework = os.path.join(frameworks, "Chromium Embedded Framework.framework")
    targets = sorted(glob.glob(os.path.join(framework, "Libraries", "*.dylib")))
    targets += [framework] + sorted(glob.glob(os.path.join(frameworks, "*Helper*.app"))) + [app]
    for target in targets:
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", target],
                       check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    return app


def cefclient_to_paint_ms(fixtures, app, work, label):
    since = len(fixtures.log())
    cache = os.path.join(work, f"cache-{label}")
    started_ms = time.time() * 1000
    proc = subprocess.Popen(
        [os.path.join(app, "Contents", "MacOS", "cefclient"), f"--url={PAGE_URL}",
         f"--root-cache-path={cache}"],
        cwd=work,  # cefclient writes console.log into its working directory
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        return wait_for_paint(fixtures, since, f"{label} first paint") - started_ms
    finally:
        stop_tree(proc)
        shutil.rmtree(cache, ignore_errors=True)


def cefclient_baseline(fixtures, args, work):
    """First launch of a freshly re-signed cefclient next to its own warm launches: the OS cost."""
    first = []
    for i in range(args.first_launch_runs):
        app = resigned_cefclient(work, f"cefclient-{i}")
        first.append(round(cefclient_to_paint_ms(fixtures, app, work, f"first-{i}"), 1))
    warm = [round(cefclient_to_paint_ms(fixtures, app, work, f"warm-{i}"), 1)
            for i in range(args.runs)]
    result = {"first_launch": summarize(first), "warm": summarize(warm), "pass": True}
    result["first_launch_extra_ms"] = round(result["first_launch"]["p50"] - result["warm"]["p50"], 1)
    return result


def settled_footprint(root_pid, raw_path):
    time.sleep(SETTLE_SECONDS)  # the budget is defined at 3 s after the page settled
    for attempt in range(3):
        pids = [root_pid] + bs.descendants(root_pid)
        try:
            processes = measure_footprint(pids, raw_path)
            break
        except (RuntimeError, subprocess.CalledProcessError):
            # A helper exited between listing and measuring (Chrome swaps renderers on real pages).
            if attempt == 2:
                raise
    return {"total_bytes": sum(size for _, _, size in processes),
            "processes": [{"name": n, "pid": p, "bytes": s} for n, p, s in processes]}


def barestate_footprint(fixtures, work, raw_path):
    data_dir = os.path.join(work, "fp-app")
    since = len(fixtures.log())
    app = bs.App(data_dir, os.path.join(work, "logs"), "footprint", test_hooks=False, url=PAGE_URL)
    try:
        app.start()
        wait_for_paint(fixtures, since, "barestate first paint")
        return settled_footprint(app.proc.pid, raw_path)
    finally:
        app.stop()


def chrome_footprint(fixtures, work, raw_path):
    if not os.path.exists(CHROME):
        raise FileNotFoundError(CHROME)
    profile = os.path.join(work, "chrome-profile")
    since = len(fixtures.log())
    proc = subprocess.Popen(
        [CHROME, f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
         PAGE_URL], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for_paint(fixtures, since, "chrome first paint")
        return settled_footprint(proc.pid, raw_path)
    finally:
        stop_tree(proc)
        shutil.rmtree(profile, ignore_errors=True)


def footprint(fixtures, args, work, raw_dir):
    measured = {"barestate": [], "chrome": []}
    for i in range(args.footprint_runs):
        # Alternating keeps drift in machine state from favouring either browser.
        for name, measure in (("barestate", barestate_footprint), ("chrome", chrome_footprint)):
            measured[name].append(measure(fixtures, work, os.path.join(raw_dir, f"{name}-{i}.json")))
    result = {}
    medians = {}
    for name, runs in measured.items():
        totals = [run["total_bytes"] for run in runs]
        medians[name] = statistics.median(totals)
        result[name] = {"p50_mib": round(medians[name] / MIB, 1),
                        "totals_mib": [round(t / MIB, 1) for t in totals], "runs": runs}
    result["budget_mib"] = FOOTPRINT_BUDGET_MIB
    result["pass"] = (medians["barestate"] < FOOTPRINT_BUDGET_MIB * MIB
                      and medians["barestate"] <= medians["chrome"])
    return result


def open_pages(app, count, url_of):
    """Opens `count` loaded pages, each with a preview in the cache; returns their tab ids."""
    ids = []
    for n in range(count):
        ids.append(app.call("open_tab", {"url": url_of(n)})["id"])
        bs.wait_until(lambda: not any(t["loading"] for t in app.call("tabs")["tabs"]),
                      what=f"page {n} loaded")
        app.call("test.previewCapture", {"tabId": ids[-1]})
    return ids


def set_presentation(app, wanted):
    if app.call("test.ui")["presentation"] != wanted:
        app.call("test.key", {"key": "\\", "modifiers": ["cmd", "shift"]})
        bs.wait_until(lambda: app.call("test.ui")["presentation"] == wanted,
                      what=f"presentation {wanted}")


def launcher_bench(fixtures, args, work):
    app = bs.App(os.path.join(work, "launcher"), os.path.join(work, "logs"), "launcher").start()
    try:
        def call(method, params=None):
            return app.call(method, params)

        base = bs.FIXTURE_URL
        now = time.time()
        call("test.seed", {
            # The 50 most recent rows are the empty launcher's "Recent" candidates; the rest are
            # a year old.
            "history": [{"url": f"{base}/index.html?h={n}", "title": f"Page {n} about kyoto stay",
                         "lastVisit": now - n if n < LAUNCHER_RECENTS else now - 365 * 86400 - n}
                        for n in range(10_000)],
            "bookmarks": [{"url": f"{base}/index.html?b={n}", "title": f"Bookmark {n}"}
                          for n in range(1_000)],
        })
        call("test.modelOffline", {"on": True})
        call("test.windowSize", {"w": 1440, "h": 900})
        pages = open_pages(app, LAUNCHER_PAGES, lambda n: f"{base}/index.html?tab={n}")
        previews = call("test.previews")["count"]

        def key(name, *modifiers):
            call("test.key", {"key": name, "modifiers": list(modifiers)})

        def open_launcher():
            key("t", "cmd")
            bs.wait_until(lambda: call("test.ui")["launcher"]["open"], what="the launcher")

        def close_launcher():
            key("Escape")
            bs.wait_until(lambda: not call("test.ui")["launcher"]["open"], what="the launcher closed")

        call("test.launcherTimings", {"reset": True})
        warm, samples = LAUNCHER_OPENS
        for i in range(warm + samples):
            # Even samples open over a focused page, odd ones over the overview.
            set_presentation(app, "focused" if i % 2 == 0 else "overview")
            open_launcher()
            close_launcher()
        opens = call("test.launcherTimings", {"reset": True})["open"][warm:]

        set_presentation(app, "focused")
        open_launcher()
        warm, samples = LAUNCHER_UPDATES
        typed = 0
        while typed < warm + samples:
            for query in LAUNCHER_QUERIES:
                call("test.key", {"key": "a", "modifiers": ["cmd"]})
                call("test.key", {"key": "Backspace", "modifiers": []})
                for character in query:
                    call("test.type", {"text": character})
                    # Waiting per character keeps a slow update from being superseded unmeasured.
                    bs.wait_until(lambda: call("test.ui")["launcher"]["current"], what="an update")
                    typed += 1
        updates = call("test.launcherTimings", {"reset": True})["update"][warm:warm + samples]
        if len(updates) < samples:
            raise RuntimeError(f"only {len(updates)} of {samples} suggestion updates were measured")
        close_launcher()
    finally:
        app.stop()
    return {"dataset": {"openPages": len(pages), "previews": previews, "history": 10_000,
                        "bookmarks": 1_000, "recents": LAUNCHER_RECENTS, "modelOffline": True,
                        "window": "1440x900", "opensAlternate": "focused page / overview"},
            "open": summarize([round(v, 2) for v in opens]),
            "update": summarize([round(v, 2) for v in updates]), "budget_ms": LAUNCHER_BUDGET_MS,
            "pass": bool(opens) and bool(updates)
            and bs.nearest_rank(opens, 0.95) < LAUNCHER_BUDGET_MS
            and bs.nearest_rank(updates, 0.95) < LAUNCHER_BUDGET_MS}


def pan_intervals(app):
    """Intervals between the committed canvas updates of PAN_REPEATS pans of PAN_SECONDS each. The
    app scrolls the overview on every display-link tick (what test.scroll does, without a socket
    round trip per step) inside a transaction and timestamps its commit. Also returned: the raw
    display-link tick intervals, and the steps, commits and steps whose position was not yet in the
    presentation layer on the next tick."""
    intervals, ticks, refresh = [], [], 0
    counts = {"steps": 0, "commits": 0, "notPresented": 0}
    for _ in range(PAN_REPEATS):
        app.call("test.frameProbe", {"action": "start", "pan": {"dx": 8, "dy": 3}})
        time.sleep(PAN_SECONDS)
        result = app.call("test.frameProbe", {"action": "stop"})
        intervals += [round(v, 2) for v in result["intervalsMs"]]
        ticks += [round(v, 2) for v in result["tickIntervalsMs"]]
        for key in counts:
            counts[key] += result[key]
        refresh = result["refreshHz"]
    return intervals, ticks, counts, refresh


def presentation_start_ms(app):
    """When the latest overview presentation began: its camera flight or its Reduce Motion swap."""
    starts = [i["startedAtMs"] for i in app.call("test.motion")["recent"]
              if i["kind"] == "camera" or (i["kind"] == "previewCrossfade" and i["target"] == "swap")]
    return max(starts)


def toggle_and_pan_bench(fixtures, args, work):
    """Overview toggle (key-down to settled, Reduce Motion on) and pan frame intervals, with 20
    live pages that hold previews at 1440x900."""
    app = bs.App(os.path.join(work, "frontend"), os.path.join(work, "logs"), "frontend").start()
    try:
        base = bs.FIXTURE_URL
        app.call("test.windowSize", {"w": 1440, "h": 900})
        app.call("test.reduceMotion", {"on": True})
        blank = [t["id"] for t in app.call("tabs")["tabs"]]
        open_pages(app, FRONTEND_PAGES, lambda n: f"{base}/index.html?tab={n}")
        for tab in blank:
            app.call("test.closeTab", {"tabId": tab})
        bs.wait_until(lambda: len(app.call("tabs")["tabs"]) == FRONTEND_PAGES,
                      what="exactly the dataset's live pages")
        nodes = len(app.call("test.ui")["canvas"]["nodes"])
        timeouts = app.call("test.motion")["counters"]["previewCaptureTimeouts"]
        presentation_starts = []
        set_presentation(app, "focused")
        app.call("test.toggleTimings", {"reset": True})
        warm, samples = TOGGLE_SAMPLES
        for i in range(warm + samples):
            want = "overview" if i % 2 == 0 else "focused"
            app.call("test.key", {"key": "\\", "modifiers": ["cmd", "shift"]})
            bs.wait_until(lambda: len(app.call("test.toggleTimings")["toggle"]) == i + 1,
                          what=f"toggle {i} to settle")
            if app.call("test.ui")["presentation"] != want:
                raise RuntimeError(f"toggle {i} did not reach {want}")
            if want == "overview":
                presentation_starts.append(presentation_start_ms(app))
        toggles = app.call("test.toggleTimings", {"reset": True})["toggle"][warm:]
        timeouts = app.call("test.motion")["counters"]["previewCaptureTimeouts"] - timeouts
        # Every leaving toggle logs one capture; the log keeps the newest 128 records.
        leaving = app.call("test.previews")["log"][-len(presentation_starts):]
        capture_ms = [round(r["finishedMs"] - r["startedMs"], 2) for r in leaving]
        late_ms = [round(r["finishedMs"] - start, 2)
                   for r, start in zip(leaving, presentation_starts) if r["finishedMs"] > start]
        pairs = [{"captureStartMs": r["startedMs"], "captureFinishMs": r["finishedMs"],
                  "presentationStartMs": start} for r, start in zip(leaving, presentation_starts)]
        stored = all(r["outcome"] == "stored" for r in leaving)
        set_presentation(app, "overview")
        time.sleep(1)
        intervals, ticks, counts, refresh = pan_intervals(app)
    finally:
        app.stop()
    toggle_p95 = bs.nearest_rank(toggles, 0.95)
    interval_p95 = bs.nearest_rank(intervals, 0.95)
    return {"dataset": {"livePages": FRONTEND_PAGES, "nodes": nodes, "window": "1440x900",
                        "reduceMotion": True, "refreshHz": refresh},
            "toggle": summarize([round(v, 2) for v in toggles]), "toggle_budget_ms": TOGGLE_BUDGET_MS,
            "capture": summarize(capture_ms), "capture_after_presentation_ms": late_ms,
            "capture_timeouts": timeouts, "capture_pairs": pairs, "tabs": FRONTEND_PAGES,
            "pan": summarize(intervals), "pan_ticks": summarize(ticks), "pan_counts": counts,
            "pan_repeats": PAN_REPEATS, "pan_seconds": PAN_SECONDS,
            "pan_budget_ms": PAN_BUDGET_MS,
            "pass": len(toggles) == samples and len(intervals) >= PAN_MIN_INTERVALS
            and len(leaving) == len(presentation_starts) and stored and not late_ms and not timeouts
            and counts["commits"] >= counts["steps"] - 2 * PAN_REPEATS
            and counts["notPresented"] <= counts["steps"] // 10
            and toggle_p95 < TOGGLE_BUDGET_MS and interval_p95 <= PAN_BUDGET_MS}


# Public pages for `footprint-20 --real-pages`: a real network fetch of ordinary content.
REAL_PAGES = [f"https://en.wikipedia.org/wiki/{name}" for name in (
    "Kyoto", "Tokyo", "Osaka", "Nara,_Nara", "Hiroshima", "Sapporo", "Nagoya", "Kobe", "Fukuoka",
    "Yokohama")] + [
    "https://example.com/", "https://example.org/", "https://info.cern.ch/",
    "https://www.python.org/", "https://developer.mozilla.org/en-US/", "https://news.ycombinator.com/",
    "https://text.npr.org/", "https://lite.cnn.com/", "https://www.gnu.org/", "https://www.rust-lang.org/"]
REAL_PAGES_SETTLE_SECONDS = 30
real_pages = False


def page_urls(count):
    if real_pages:
        return REAL_PAGES[:count]
    return [f"{bs.FIXTURE_URL}/fp.html?page={n}" for n in range(count)]


def wait_for_requests(fixtures, since, count, what):
    if real_pages:
        # Real pages keep working after their load event; every browser gets the same pause.
        time.sleep(REAL_PAGES_SETTLE_SECONDS)
        return

    def served():
        log = fixtures.log(since)
        return all(any(f"GET /fp.html?page={n} " in line for line in log) for n in range(count))
    bs.wait_until(served, 60, what=what)


def barestate_20_footprint(fixtures, work, raw_path):
    app = bs.App(os.path.join(work, "fp20-app"), os.path.join(work, "logs"), "fp20").start()
    try:
        since = len(fixtures.log())
        app.call("test.windowSize", {"w": 1440, "h": 900})
        ids = open_pages(app, FRONTEND_PAGES, lambda n: page_urls(FRONTEND_PAGES)[n])
        wait_for_requests(fixtures, since, FRONTEND_PAGES, "20 pages served")
        # Both limits reached: every page holds a preview and the byte limit is what they use.
        used = app.call("test.previews")["bytes"]
        app.call("test.previews", {"limits": {"count": FRONTEND_PAGES, "bytes": used}})
        for tab in ids:
            app.call("test.previewCapture", {"tabId": tab})
        cache = app.call("test.previews")
        if cache["count"] != FRONTEND_PAGES or cache["bytes"] > cache["limits"]["bytes"]:
            raise RuntimeError(f"the preview cache is not full: {cache['count']}, {cache['bytes']}")
        set_presentation(app, "overview")
        result = settled_footprint(app.proc.pid, raw_path)
        result["preview_cache"] = {"count": cache["count"], "bytes": cache["bytes"],
                                   "limits": cache["limits"]}
        return result
    finally:
        app.stop()


def chrome_20_footprint(fixtures, work, raw_path):
    if not os.path.exists(CHROME):
        raise FileNotFoundError(CHROME)
    profile = os.path.join(work, "chrome-profile-20")
    since = len(fixtures.log())
    proc = subprocess.Popen(
        [CHROME, f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check"]
        + page_urls(FRONTEND_PAGES),
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for_requests(fixtures, since, FRONTEND_PAGES, "chrome served 20 pages")
        if real_pages:  # no load hook: the first window is the load, this one the settle
            wait_for_requests(fixtures, since, FRONTEND_PAGES, "chrome settled")
        return settled_footprint(proc.pid, raw_path)
    finally:
        stop_tree(proc)
        shutil.rmtree(profile, ignore_errors=True)


def footprint_20(fixtures, args, work, raw_dir):
    """20 live pages with a full preview cache, overview showing, vs Chrome on the same 20 pages."""
    measured = {"barestate": [], "chrome": []}
    for i in range(args.footprint_runs):
        for name, measure in (("barestate", barestate_20_footprint), ("chrome", chrome_20_footprint)):
            measured[name].append(measure(fixtures, work, os.path.join(raw_dir, f"fp20{'-real' if real_pages else ''}-{name}-{i}.json")))
    result = {}
    medians = {}
    for name, runs in measured.items():
        totals = [run["total_bytes"] for run in runs]
        medians[name] = statistics.median(totals)
        result[name] = {"p50_mib": round(medians[name] / MIB, 1),
                        "totals_mib": [round(t / MIB, 1) for t in totals], "runs": runs}
    result["pages"] = FRONTEND_PAGES
    result["budget_mib"] = FOOTPRINT_BUDGET_MIB
    result["pass"] = (medians["barestate"] < FOOTPRINT_BUDGET_MIB * MIB
                      and medians["barestate"] <= medians["chrome"])
    return result


def cold_start_verdict(cold):
    if cold["warm"]["n"] < MIN_WARM_RUNS:
        return f"not enough runs for a budget verdict (n<{MIN_WARM_RUNS})"
    return (f"cold-start warm p50 < {cold['budget_ms']} ms over >= {MIN_WARM_RUNS} runs: "
            f"{'PASS' if cold['pass'] else 'FAIL'}")


def print_report(report):
    for key in ("cold_start", "cefclient_baseline"):
        for label in ("first_launch", "warm"):
            if label in report.get(key, {}):
                s = report[key][label]
                print(f"{key.replace('_', '-')} {label}: p50 {s['p50']} ms, p95 {s['p95']} ms, "
                      f"max {s['max']} ms, values {s['values']}")
        if "first_launch_extra_ms" in report.get(key, {}):
            print(f"{key.replace('_', '-')} first launch over warm: "
                  f"{report[key]['first_launch_extra_ms']} ms (p50 difference)")
    launcher = report.get("launcher")
    if launcher:
        for label in ("open", "update"):
            s = launcher[label]
            print(f"launcher {label}: n {s['n']}, p50 {s['p50']} ms, p95 {s['p95']} ms, "
                  f"max {s['max']} ms")
        print(f"launcher open and update p95 < {launcher['budget_ms']} ms: "
              f"{'PASS' if launcher['pass'] else 'FAIL'}")
    spatial = report.get("overview")
    if spatial:
        for label in ("toggle", "pan"):
            t = spatial[label]
            print(f"overview {label}: n {t['n']}, p50 {t['p50']} ms, p95 {t['p95']} ms, "
                  f"max {t['max']} ms")
        c = spatial["capture"]
        print(f"overview leaving capture: n {c['n']}, p50 {c['p50']} ms, p95 {c['p95']} ms, "
              f"p99 {c['p99']} ms, max {c['max']} ms; finished after the presentation started: "
              f"{len(spatial['capture_after_presentation_ms'])}; deadline misses: "
              f"{spatial['capture_timeouts']}")
        c = spatial["pan_counts"]
        print(f"overview pan: {c['steps']} steps, {c['commits']} commits, {c['notPresented']} "
              f"not yet in the presentation layer on the next tick; display-link ticks "
              f"p95 {spatial['pan_ticks']['p95']} ms (n {spatial['pan_ticks']['n']})")
        print(f"overview toggle p95 < {spatial['toggle_budget_ms']} ms, pan interval p95 <= "
              f"{spatial['pan_budget_ms']} ms ({spatial['dataset']['refreshHz']} Hz display): "
              f"{'PASS' if spatial['pass'] else 'FAIL'}")
    fp20 = report.get("footprint_20")
    if fp20:
        for name in ("barestate", "chrome"):
            print(f"footprint (20 pages) {name}: p50 {fp20[name]['p50_mib']} MiB, "
                  f"runs {fp20[name]['totals_mib']}")
        print("preview cache " + str(fp20["barestate"]["runs"][-1]["preview_cache"]))
        print(f"footprint (20 pages) barestate < {fp20['budget_mib']} MiB and <= chrome: "
              f"{'PASS' if fp20['pass'] else 'FAIL'}")
    cold = report.get("cold_start")
    if cold:
        print(cold_start_verdict(cold))
    fp = report.get("footprint")
    if fp:
        for name in ("barestate", "chrome"):
            print(f"footprint {name}: p50 {fp[name]['p50_mib']} MiB, runs {fp[name]['totals_mib']}")
            for process in fp[name]["runs"][-1]["processes"]:
                print(f"  {process['name']} [{process['pid']}] {process['bytes'] / MIB:.1f} MiB")
        print(f"footprint barestate < {fp['budget_mib']} MiB and <= chrome: "
              f"{'PASS' if fp['pass'] else 'FAIL'}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("what", nargs="?", default="all", choices=["cold-start", "cefclient-baseline", "footprint", "footprint-20", "launcher", "overview", "frontend", "all"])
    parser.add_argument("--real-pages", action="store_true", help="footprint-20 on 20 public pages instead of fixtures")
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--first-launch-runs", type=int, default=3)
    parser.add_argument("--footprint-runs", type=int, default=3)
    parser.add_argument("--out", default=os.path.join(bs.ROOT, ".logs", "bench-startup.json"))
    args = parser.parse_args()
    global real_pages
    real_pages = args.real_pages

    raw_dir = os.path.join(os.path.dirname(args.out), "bench-startup")
    os.makedirs(raw_dir, exist_ok=True)
    report = {"date": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    fixtures = bs.Fixtures(raw_dir).start()
    work = tempfile.mkdtemp(prefix="bs-bench-")
    try:
        with reaping_code_sign_clones(bundles_to_reap(args.what)):
            if args.what in ("cold-start", "all"):
                report["cold_start"] = cold_start(fixtures, args, work)
            if args.what == "cefclient-baseline":
                report["cefclient_baseline"] = cefclient_baseline(fixtures, args, work)
            if args.what == "launcher":
                report["launcher"] = launcher_bench(fixtures, args, work)
            if args.what in ("overview", "frontend"):
                report["overview"] = toggle_and_pan_bench(fixtures, args, work)
            if args.what in ("frontend", "footprint-20"):
                report["footprint_20"] = footprint_20(fixtures, args, work, raw_dir)
            if args.what in ("footprint", "all"):
                report["footprint"] = footprint(fixtures, args, work, raw_dir)
    finally:
        fixtures.stop()
        shutil.rmtree(work, ignore_errors=True)
    with open(args.out, "w") as out:
        json.dump(report, out, indent=2)
    print_report(report)
    print(f"report: {args.out}")
    sys.exit(0 if all(section["pass"] for key, section in report.items() if key != "date") else 1)


if __name__ == "__main__":
    main()
