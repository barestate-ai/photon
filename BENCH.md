# Measured budgets

The ten budgets on the final release bundle are in the next section, "Release bundle: the ten budgets (2026-10-31)". The older tables below are history; where they differ, the next section is the figure to cite.

## Release bundle: the ten budgets (2026-10-31)

Bundle: `dist/Photon-0.1.0.zip` (150,179,186 bytes), built by `make dist` from the HEAD source plus the one-constant change in D63 (`Motion.reducedToggleFade` 50 to 34 ms); `.build/Photon.app` is the `make bundle` output the zip was made from. The final zip was extracted with `ditto -x -k` and compared with `.build/Photon.app` by `diff -rq` (no differences, same CDHash `2478e79bfe7494c44284836b004177bac697b65b`; the earlier 19:18 build, CDHash `ca10582992a880256eb31f49d3b7ff3eb41f928e`, was checked the same way before the fix), so the bundle the benches launch is the zip's app. Ad-hoc signed, Manrope and Instrument Serif bundled, no Kyoto art. `du -sh .build/Photon.app` 338M; `du -sh .build/Photon.app/Contents/Resources/Fonts` **252K** (Manrope-Variable.ttf 164,700 B, InstrumentSerif-Regular.ttf 70,012 B, two OFL texts). M4, macOS 27.0.1, 60 Hz display, 1440x900 window where a window size is stated. Every run was on an unlocked screen with the Photon window on screen (`ioreg -n Root -d1 -a` shows no `CGSSessionScreenIsLocked`; recorded in each `env-*.txt`). The 1-minute load average is given as start / end. Raw output: `.logs/ship-final/final/` (the `bench-*.out` and `.json` files, `observe/`, `act/`, `atom/`, `live/`, `env-*.txt`); runs on the earlier build are in `.logs/ship-final/pre-fix/`. p50 is the sample median; p95 and p99 are nearest-rank. Every row below is **measured**; nothing in this section is "not run". The figures below were measured on that build (CDHash `2478e79bfe7494c44284836b004177bac697b65b`, a 150,179,186-byte zip). The release published as v0.1.0 was rebuilt from the polish source afterwards (`scripts/release.sh`, then `scripts/dmg.sh` from the same `.build/Photon.app`, 2026-11-01): CDHash `6222b5e49394ebb285c9dba7a8d3e2a4b5ce21e3` in `Photon-0.1.0.zip` (150,423,396 bytes) and in `Photon-0.1.0.dmg` (164,563,540 bytes) after the 2026-11-02 Maximize refresh (earlier refreshes: `b0f80d47e0264336c2cd4aa875bc8e142d112955` after Full window, native full screen and mouse zoom/pan, `ea15360c29cb232d9699c369c24c8509df5b399a` after the 2026-11-01 trail-target and installer-quit fixes, and `6fbe92f0543f7ff9a22c999d53fb7a5e047eab63`), checked with `codesign -dvvv` on the extracted ZIP, the mounted DMG and `.build/Photon.app`; the benches were not re-run on it.

| # | Budget | Limit | Measured on the final bundle | Verdict |
| --- | --- | --- | --- | --- |
| 1 | Cold start: harness clock before spawn to the fixture page's first paint (`fixtures/fp.html`), fresh `--data-dir` per launch, no test hooks | median < 1500 ms | **Warm cache** (10 launches after a discarded 244.4 ms warm-up): p50 240.55 ms, p95 255.0, max 255.0; values 241.4, 237.3, 245.0, 238.1, 235.4, 233.9, 255.0, 239.7, 250.7, 249.2; the median of the first 5 is 238.1 ms. **First launch after a new signature** (`scripts/bundle.sh` re-signs before each, 5 launches): p50 **1761.1 ms**, p95 1841.8, max 1841.8; values 1841.8, 1734.7, 1722.8, 1797.3, 1761.1; 1520.5 ms over warm. Load 5.88 / 4.11 | warm **pass**; first launch **MISS** (D15 cause, D63) |
| 2 | Footprint, one fixture tab settled 3 s: sum of `footprint` over the app and its descendants vs Chrome 155 on a temp `--user-data-dir`, same page, 5 alternating runs, same session | Photon < 400 MiB and <= Chrome | Photon p50 **199.4 MiB** (201.6, 198.3, 200.8, 198.8, 199.4; 6 processes: browser 55.7, GPU 38.0, renderers 32.4 and 27.8, network 25.5, storage 20.0); Chrome p50 **522.8 MiB** (502.4, 527.2, 526.5, 522.8, 522.5; 11 processes, per-process lines in `bench-startup.out`). 199.4 MiB is 209 MB decimal. Fonts in the bundle: 252K (`du -sh`, above). Load 5.88 / 4.11 (same run as #1) | **pass** |
| 3 | `observe` on `fixtures/many.html` (151 elements), 1 warm-up then 30 socket calls | p50 < 150 ms | p50 **38.2 ms**, p95 38.9, max 39.5 (`observe/bench-observe.json`), n 30. Load 4.11 / 4.11 | **pass** |
| 4 | DOM `act` by ref, **verifier stubbed** (`test.verifier` agree, no model call): 20 clicks and 20 types on `fixtures/act.html`, socket call to final-state response | p50 < 250 ms | p50 **150.0 ms**, p95 166.5, max 167.4, n 40. This is the DOM path only, not the latency of a live verified act. Load 4.11 / 3.94 | **pass** (stubbed) |
| 4b | Live verifier added latency per act: the same act with `test.verifier` live (real `muse-spark-1.3`, before and after screenshots) minus the same act stubbed | reported, no limit | 3 pairs (click, type, click): +2710.4, +3032.2, +2595.5 ms; median **+2710.4 ms**; all three acts `confirmed`; spend $0.004487 (`.logs/spend.json` `total_usd` 0.980096 to 0.984583). Load 3.86 / 3.50 | reported |
| 5 | Atom `ground`, warm (1 warm-up call, then 12), request line written to parsed point | median < 500 ms | median **325.5 ms**, min 315.7, max 331.9, n 12. Load 3.94 / 3.86 | **pass** |
| 6 | Cmd-T to a usable launcher (key-down at `sendEvent` to a laid-out panel with the field focused), 20 discarded then 200 opens alternating a focused page and the overview | p95 < 50 ms | p50 2.74 ms, p95 **3.15 ms**, max 3.56, n 200. Dataset: 12 loaded pages with previews, 10,000 history rows, 1,000 bookmarks, model offline, 1440x900. Load 3.50 / 3.18 | **pass** |
| 7 | Suggestion update per keystroke, same run: 30 discarded then 300 updates | p95 < 50 ms | p50 8.24 ms, p95 **12.04 ms**, max 20.81, n 300 | **pass** |
| 8 | Overview toggle, Cmd-Shift-\ key-down at `sendEvent` to settled, Reduce Motion on (`test.reduceMotion`), 20 live pages with previews, 20 discarded then 100 alternating toggles | p95 < 100 ms | After the fix (D63): p50 48.09 ms, p95 **82.40 ms**, max 92.42 (n 100; `bench-frontend.out`, load 3.18 / 3.81); repeat `overview`: p50 49.07, p95 82.66, max 88.20 (`bench-overview-after.out`, load 6.09 / 7.52). Before the fix (50 ms fade, build of 19:18, `.logs/ship-final/pre-fix/`): p50 68.57, p95 **100.15**, max 104.41 (load 2.77 / 3.47) and p50 68.50, p95 **101.83**, max 103.45 (load 3.22 / 3.20), both a miss | **pass** after one fix (D63) |
| 9 | Pan frame interval: committed canvas updates (in-app probe), 5 x 2 s pans, 20 nodes, 1440x900, 60 Hz display | p95 <= 20 ms | p50 16.66 ms, p95 **16.89 ms**, max 17.23, n 596 intervals from 601 steps and 601 commits; 0 steps missing from the presentation layer on the next tick. Load 3.18 / 3.81 | **pass** |
| 10 | Footprint with 20 pages and a full preview cache, overview showing, settled 3 s, median of 5 alternating runs vs Chrome on the same 20 URLs, same session. **Fixture pages** (`fixtures/fp.html?page=n`, served on loopback) | Photon < 400 MiB and <= Chrome | Photon p50 **871.1 MiB** (874.1, 870.2, 869.8, 877.4, 871.1); Chrome p50 **1104.1 MiB** (1185.1, 1115.0, 1104.1, 1103.6, 1081.2); cache 20 previews, 10,560,000 bytes, at its limits. Load 3.18 / 3.81 (same run as #8, #9) | <= Chrome **pass**; 400 MiB **MISS** (D32, D63) |
| 10b | The same with **20 real pages loaded over the network** (10 English Wikipedia city articles and 10 public sites, `REAL_PAGES` in `scripts/bench.py`), median of 3 alternating runs. Photon: each page waited for its load flag, then 30 s, then the 3 s settle. Chrome (no load hook): 30 s after launch to load, 30 s more, then the 3 s settle | Photon < 400 MiB and <= Chrome | Photon p50 **1733.8 MiB** (1735.0, 1733.8, 1710.2; 26 processes in run 2: browser 145.1, 22 renderers 1450.4, 3 helpers 138.2); Chrome p50 **1486.4 MiB** (1496.1, 1486.4, 1485.5; 26 processes: browser 143.3, 22 renderers 1221.1, 3 helpers 122.0); cache 20 previews, 11,158,400 bytes in run 2 (10,679,680 in run 3; `test.previews`), at its limits. Load 2.63 / 2.81 | both **MISS** (D63); one fix attempt found no lever, unchanged (D64) |

Commands (from the repository root, bundle already built; each ran after the 1-minute load was below 8):

```
python3 -u scripts/bench.py all --runs 10 --first-launch-runs 5 --footprint-runs 5 --out .logs/ship-final/final/bench-startup.json > .logs/ship-final/final/bench-startup.out        # 1, 2
BS_E2E_LOGDIR=$PWD/.logs/ship-final/final/observe python3 e2e/test_core.py ObserveTests.test_p50_under_150ms_on_a_page_with_100_elements                                           # 3
BS_E2E_LOGDIR=$PWD/.logs/ship-final/final/act python3 e2e/test_act_kinds.py ActLatency.test_dom_act_p50_is_under_250_ms                                                              # 4
set -a; . ./.env; set +a; BARESTATE_LIVE_META=1 BARESTATE_SPEND_LOG=$PWD/.logs/spend.json BS_E2E_LOGDIR=$PWD/.logs/ship-final/final/live python3 e2e/test_act_kinds.py ActLatency.test_live_verifier_added_latency_per_act   # 4b
BS_E2E_LOGDIR=$PWD/.logs/ship-final/final/atom python3 e2e/test_act_kinds.py RealAtom                                                                                                 # 5
python3 -u scripts/bench.py launcher --out .logs/ship-final/final/bench-launcher.json                                                                                                 # 6, 7
python3 -u scripts/bench.py frontend --footprint-runs 5 --out .logs/ship-final/final/bench-frontend.json                                                                              # 8, 9, 10
python3 -u scripts/bench.py footprint-20 --real-pages --footprint-runs 3 --out .logs/ship-final/final/bench-real.json                                                                # 10b
```

Notes.

- **Cold start.** "Cold" has two meanings here and both are reported. The first launch of a newly signed bundle costs about 1.5 s more than later launches on this Mac; the unmodified cefclient pays more (D15), so the likely cause is the OS assessing a new signature and not this app (not isolated). Warm launches are 240 ms. A user who unzips the release gets the first-launch figure once, then the warm one.
- **Footprint, fixtures vs real pages.** On fixture pages Photon is 21% below Chrome; on 20 real pages it is 17% above, because its 22 renderers average 65.9 MiB against Chrome's 55.5 MiB. The preview cache is 10 to 11 MB of 1734 MiB, so the cache limits (64 entries / 48 MiB, D27) are not the lever and were left alone. Real pages keep working after their load event, so the figure depends on the pause: with only the 3 s settle after the last load (first attempt, `.logs/ship-final/pre-fix/bench-real-no-pause.out`) Photon measured 2183.8 MiB against Chrome 1538.4 MiB, and with a 30 s pause after Photon's load but Chrome's 30 s counted from launch (`pre-fix/bench-real-30s-after-photon.out`) 1734.8 against 1538.9; the row above gives both browsers the same 30 s pause. Three alternating runs agree within 2%. The fixture rows (`fp20-*` raw files in `bench-startup/`) were partly overwritten by the first real-page attempt before the raw files were renamed (`fp20-real-*`); the per-process data of all five fixture runs is in `bench-frontend.json`.
- **Footprint fix attempt on 10b (D64, 2026-10-31).** Before: Photon 1733.8 MiB, Chrome 1486.4 MiB. After: not re-measured, because no source changed (original benchmark retained). Diagnosis on the same 20 pages (one Photon run, one Chrome run, load 2.2 to 2.9, unlocked screen, window on screen; raw in `.logs/ft2-fix/`): `document.visibilityState` is `hidden` on every off-screen tab (20 of 20 in the overview, 19 of 20 focused), so Chromium already treats them as hidden; renderer CPU over 30 s is 1.50 s for all 22 (overview) and 0.43 s (focused), so no busy loop showed up in those 30 s samples; the gap is the ten largest renderers (Photon 993.9 MiB at 33 s, Chrome 782.2 MiB at 63 s), the other twelve are within 4%. Photon total / renderers: 3 s 2176.6 / 1846.7 MiB, 33 s 1782.4 / 1454.9, focused 5 s 1791.2, focused 35 s 1770.3; Chrome 63 s 1491.3 / 1226.6, 93 s 1508.4. Pages opened with `activate:false` and no capture: 1801.7 MiB; 900x600 window: 1842.3. The one lever tried, as an upper bound through CDP on all 20 hidden tabs and without a source change (`HeapProfiler.collectGarbage`, then `Memory.simulatePressureNotification` critical, then `Memory.forciblyPurgeJavaScriptMemory`): 1779.4 to 1773.9, 1749.9, 1753.2 MiB, at most 29.5 MiB of a 250 to 290 MiB gap, so it was not built. Commands: `python3 -u .logs/ft2-fix/fp_diag.py photon|chrome|purge|background|small` and `python3 -u .logs/ft2-fix/fp_flags.py` (throwaway, built on `scripts/bench.py` helpers; not committed).
- **Live verifier.** The +2.6 to +3.0 s is a model round trip (two screenshots, `muse-spark-1.3`, minimal effort); it is not counted against the 250 ms DOM budget. Earlier live runs on other days: median +1916 ms (nine acts, 2026-10-31 morning) and +3594 ms (2026-10-30), so the live figure varies by a second or more with the API's load.
- **Cefclient baseline.** The D15 figures (cefclient first launch p50 2000.0 ms, warm 331.6 ms) are reused; `cefclient-baseline` was not run.
- **Pre-fix runs of the other budgets** (the 19:18 build, same code apart from the fade): cold start warm p50 266.05 ms, first launch p50 1773.5 ms; footprint Photon 202.8 vs Chrome 504.7 MiB; observe p50 37.4 ms; DOM act stubbed p50 150.5 ms; Atom 323.0 ms; live verifier median +2136.8 ms (spend 0.975447 to 0.980096); launcher open p95 3.02 ms, update p95 12.14 ms; 20-page fixtures Photon 872.2 vs Chrome 1107.5 MiB. They agree with the final figures.

| Budget | Limit | Measured | Source |
| --- | --- | --- | --- |
| `observe` latency, p50 (151 elements, `fixtures/many.html`, 30 samples, signed bundle) | < 150 ms | p50 38.7 ms, p95 39.2 ms, max 39.5 ms (2026-10-29) | `make e2e` (`e2e/test_core.py`, `ObserveTests`) writes `.logs/bench-observe.json` |
| Cold start, warm cache: harness clock before spawn to the fixture page's first paint (10 launches after a discarded warm-up, fresh `--data-dir` each, signed bundle, no test hooks) | p50 < 1500 ms | p50 269.5 ms, max 284.2 ms; values 284.2, 269.0, 269.4, 271.9, 254.9, 269.5, 277.7, 268.8, 270.4, 264.7 (2026-10-29, commit 4460457 + this feature, M4, macOS 27.0.1) | `python3 scripts/bench.py > .logs/bench-startup.out` (the same run as `make bench`, minus the redirect); raw: `.logs/bench-startup.out`, `.logs/bench-startup.json` |
| Cold start, first launch after signing (`scripts/bundle.sh` re-signs before each launch, 3 launches) | p50 < 1500 ms | **MISS** p50 1843.6 ms, max 2218.8 ms; values 2218.8, 1843.6, 1838.1 (same run) | same command and files |
| Footprint, one fixture tab settled 3 s: sum of `footprint` over the app and all descendants, Barestate vs Chrome 155.0.8059.85 on a temp `--user-data-dir`, same page (`fixtures/fp.html`), 3 alternating runs | Barestate < 400 MiB and <= Chrome | Barestate p50 193.6 MiB (runs 193.6, 193.6, 193.5; 6 processes); Chrome p50 593.5 MiB (runs 593.5, 497.3, 596.5; 11 processes) (same run) | same command (`python3 scripts/bench.py footprint` runs this part alone); raw per-process `footprint -j` output: `.logs/bench-startup/{barestate,chrome}-<n>.json`, summary in `.logs/bench-startup.out` |

## Notes on the startup and footprint figures

- Cold start is the difference between `time.time()` taken just before `scripts/run-app.sh` is spawned and `performance.timeOrigin + first-paint` that `fixtures/fp.html` reports through `/__beacon?fp=`; both are wall-clock epoch ms. The run-app.sh wrapper is included.
- The first-launch figure is not within 1.5 s. It is a one-time cost of the first launch after a new signature (about 1.8 s versus about 0.27 s afterwards, measured). The vendored `cefclient.app`, re-signed the same way, pays at least as much extra, so the cost is consistent with the OS assessing a new signature and not with anything in this app (the exact cause is not isolated); see D15 and the first-launch attribution section below. The 1.5 s budget is judged on the warm figure per AGENTS.md, and the first-launch miss is recorded here and not hidden.
- `footprint` is the per-process `phys_footprint` from `/usr/bin/footprint`; MiB is 2^20 bytes. 193.6 MiB is 203 MB in decimal units, so the 400 limit holds in either unit.
- The Chrome tree was not trimmed: it holds 7 renderers for the one fixture tab (Chrome starts extra renderer processes on its own; their pages were not inspected), so the comparison is against a default Chrome launch, not against a single-process minimum. Barestate had 2 renderers.
- Chrome runs headed with `--no-first-run --no-default-browser-check`; only PIDs the script started were measured and killed. The user's Chrome (and its profile) was running throughout and was not touched.

## Engine-core validation rerun (2026-10-29)

These measurements supplement the original results above. Raw output is under `.logs/validation/engine-core/`.

| Measurement | Result | Command and evidence |
| --- | --- | --- |
| `observe`, 151 elements on `fixtures/many.html`, one warm-up then 30 socket calls (including transcript logging) | **PASS** p50 36.3170415 ms, p95 37.758584 ms, max 38.922292 ms | `PYTHONDONTWRITEBYTECODE=1 python3 /tmp/bs-val-1f2cf-observe-extract/validate.py`; raw samples: `observe-extract/bench-observe.json`, summary: `observe-extract/latency-summary.json`, output: `observe-extract/validation-run.log` |
| Startup, fresh data dir each launch | First-after-signing **MISS**: five values 1851.4, 1759.1, 1990.6, 1759.8, 1768.7 ms; p50 1768.7 ms, max 1990.6 ms. Warm-cache **PASS**: ten values 246.4, 217.4, 241.5, 240.9, 238.5, 240.4, 241.9, 247.5, 242.8, 239.7 ms; p50 241.2 ms, max 247.5 ms; discarded warm-up 244.1 ms | `TMPDIR=/tmp/bs-val-1f2cf-engine-runtime/bench-tmp python3 -u scripts/bench.py all --runs 10 --first-launch-runs 5 --footprint-runs 3 --out .logs/validation/engine-core/engine-runtime/bench-startup.json`; output: `engine-runtime/bench-command.log` |
| Footprint, same-session alternating fresh profiles, same fixture and 3 s settle | **PASS** Barestate 195.4, 195.3, 193.2 MiB (p50 195.3); Chrome 605.9, 597.1, 505.4 MiB (p50 597.1) | Same benchmark command; per-process output: `engine-runtime/bench-startup/{barestate,chrome}-<n>.json` |

The observation p95 uses nearest rank `ceil(0.95 * 30)`, rank 29; the e2e helper used rank 28 until `bs.nearest_rank` replaced it (it gave 37.49475 ms for these samples). `scripts/bench.py` and `e2e/test_core.py` now both use `bs.nearest_rank`, so every p95 in this file from 2026-10-29 on is nearest-rank (the first table's observe p95 predates the change and is one rank low). The temporary observation harness was removed after validation; its exact source is retained as `observe-extract/validation-harness.py.txt`. The startup script exits 0 for its warm-cache budget, but this validation reports VAL-ENGINE-012 failed because the contract does not explicitly exempt the separately measured first-launch miss. The orchestrator must reconcile that acceptance interpretation; no test expectation was changed.

## First-launch attribution (2026-10-29)

Same session, same fixture page (`fixtures/fp.html`), same method for both apps: harness wall clock before spawn to `performance.timeOrigin + first-paint`. Percentiles are nearest-rank. Machine: M4, macOS 27.0.1.

| Dataset | n | p50 | p95 | max | Values (ms) |
| --- | --- | --- | --- | --- | --- |
| Barestate, warm (fresh `--data-dir`, after a discarded warm-up) | 10 | 243.0 | 252.8 | 252.8 | 241.1, 246.3, 239.9, 247.7, 234.6, 243.0, 252.8, 222.5, 247.6, 242.9 |
| Barestate, first launch after `scripts/bundle.sh` re-signs | 5 | 1727.6 | 2063.3 | 2063.3 | 1745.1, 1725.1, 1710.0, 2063.3, 1727.6 |
| cefclient, warm (same signed clone, fresh temp `--root-cache-path`) | 10 | 331.6 | 356.4 | 356.4 | 356.4, 329.4, 325.9, 343.8, 344.1, 314.9, 334.8, 330.0, 332.8, 330.3 |
| cefclient, first launch of a fresh clone of `Vendor/cefclient.app`, ad-hoc re-signed inside-out | 5 | 2000.0 | 2065.5 | 2065.5 | 1953.0, 2065.5, 1936.8, 2053.8, 2000.0 |

First launch over warm (p50 difference): Barestate **1484.6 ms**, cefclient **1668.5 ms**. The unmodified Chromium test client pays the same one-time cost (and slightly more), with a different binary, bundle ID and no Barestate code, so the extra time is consistent with the OS assessing a newly signed bundle once. Both apps share the same CEF build and the clone also has a new path and inode, and no trace was taken, so the exact cause is not isolated. Barestate warm launches stay at 243 ms; the first launch after any new signature misses 1.5 s on this machine regardless of the app (D15).

Commands (run in this order, after `make e2e` had bundled the app):

```
python3 -u scripts/bench.py cold-start --runs 10 --first-launch-runs 5 --out .logs/fix-engine-core/bench-startup.json > .logs/fix-engine-core-cold-start.out
python3 -u scripts/bench.py cefclient-baseline --runs 10 --first-launch-runs 5 --out .logs/fix-engine-core/bench-cefclient.json > .logs/fix-engine-core-cefclient.out
```

Raw output: `.logs/fix-engine-core-cold-start.out`, `.logs/fix-engine-core/bench-startup.json`, `.logs/fix-engine-core-cefclient.out`, `.logs/fix-engine-core/bench-cefclient.json`, fixture request logs in `.logs/fix-engine-core/bench-startup/`.

`cefclient-baseline` clones `Vendor/cefclient.app` with `cp -c -R` into a temp dir for every first launch (so a new path and inode), signs the dylibs, framework, helpers and app with `codesign --force --sign - --timestamp=none` in that order, and launches it with `--url=<fixture> --root-cache-path=<temp>`. The vendored bundle is never modified. The cefclient warm figure is launches of the last signed clone. cefclient is a heavier shell than Barestate, so its warm time (332 ms) is higher; the attribution rests on the extra time, not the absolute value.

Unattended e2e after the timestamp fix: `make e2e < /dev/null` exited 0 three times in a row (49 tests each, logs `.logs/fix-e2e-{1,2,3}.log`, exit codes in `.logs/fix-e2e-exits.txt`).

## Launcher (2026-10-30)

Dataset (VAL-LAUNCH-011/012): 12 loaded pages with previews, 10,000 history rows (the newest 50 are the recents), 1,000 bookmarks, model offline, 1440x900. Times come from the app's own clock: the key-down reaching `sendEvent` to a laid-out panel with the field focused (open), and to the rows of that generation being applied (update). The harness waits for every character's result before typing the next, so no update is superseded unmeasured. 20 discarded opens then 200 alternating a focused page and the overview; 30 discarded updates then 300 (each typed character, mixed URL-like, task-like and command-like queries). Percentiles are nearest-rank. M4, macOS 27.0.1, signed bundle with `--test-hooks`.

| Budget | Limit | Measured | Source |
| --- | --- | --- | --- |
| Cmd-T to a usable launcher, p95 | < 50 ms | p50 2.07 ms, p95 2.32 ms, max 2.49 ms (n 200) | `python3 scripts/bench.py launcher --out .logs/frontend/bench-launcher.json` (not part of `all`) |
| Suggestion update per keystroke, p95 | < 50 ms | p50 8.28 ms, p95 12.38 ms, max 21.25 ms (n 300; each character waits for its own update) | same run |

An earlier run (2026-10-29) on 12 tabs, before the dataset gained previews and recents, measured open p95 8.08 ms and update p95 14.36 ms. Before the scan used UTF-8 byte search, update p50 was 51.9 ms and p95 70.7 ms (`String.contains` over 11,000 sites); that is why the scan changed.

## Frontend: overview toggle, pan and 20-page footprint (2026-10-30)

Command: `python3 -u scripts/bench.py frontend --footprint-runs 5 --out .logs/frontend/bench-frontend.json` (first run) and `python3 -u scripts/bench.py overview --out .logs/frontend/bench-overview.json` (and `bench-overview2.json`, repeat). Dataset: 20 live fixture pages, each with a captured preview, 1440x900, Reduce Motion on. Display refresh 60 Hz (`maximumFramesPerSecond`). M4, macOS 27.0.1.

| Budget | Limit | Measured | Verdict |
| --- | --- | --- | --- |
| Overview toggle, Cmd-Shift-\ key-down at `sendEvent` to settled (`motion.inFlight` empty), p95 | < 100 ms | After the fix: p50 66.34 ms, p95 95.20 ms, max 101.00 ms (n 100, 20 discarded); repeat p50 66.92, p95 87.16, max 116.70 (n 100); with the 80 ms capture deadline and the settle-on-resize/key changes (bf-fix-camera-transition-gaps, `.logs/bfc/bench-overview.json`): p50 67.78 ms, p95 91.97 ms, max 102.60 ms (n 100, 20 discarded) | pass |
| Pan frame interval, committed canvas updates (in-app probe, 5 x 2 s, 20 nodes), p95 | <= 20 ms | p50 16.67 ms, p95 16.82 ms, min 16.35 ms, max 17.16 ms (n 596 intervals from 601 pan steps and 601 commits; 0 steps missing from the presentation layer on the next tick; 60 Hz display; `.logs/bf2/bench-overview.json`) | pass |
| Footprint, 20 pages, preview cache full, overview settled 3 s, median of 5 | <= Chrome, same session (VAL-PREVIEW-006); 400 MB compared and recorded | Photon 909.3 MiB (908.4, 910.9, 909.3, 916.4, 908.2); Chrome 155 1114.2 MiB (1208.8, 1101.7, 1087.0, 1114.2, 1209.2); cache 20 previews, 10,560,000 bytes (at its count and byte limits), included | **<= Chrome: pass; 400 MB comparison: MISS (D32)** |

The first full run measured the toggle at p50 71.82 ms, p95 101.78 ms (max 107.63 ms) with a 60 ms Reduce Motion fade; one focused fix attempt (FT2) shortened the toggle's own reduced fade to 50 ms (`Motion.reducedToggleFade`; the general reduced fade stays 120 ms) and it passed twice. Before that, the 120 ms reduced fade measured p95 126 to 160 ms in smoke runs. The pan figure is the interval between the commits of consecutive pan steps. Method (`FrameProbe`, `test.frameProbe` with `pan`): on every display-link tick the probe scrolls the overview inside its own `CATransaction`, whose completion block timestamps the commit (`CACurrentMediaTime`); the interval is the time between two consecutive commits, so a main thread that is late for a frame stretches it. On the next tick the probe also checks that the first visible card's presentation layer is at the position the step committed (`notPresented`). The raw intervals, the display-link tick intervals (p95 16.67 ms, n 596, kept as `pan_ticks`) and the step, commit and not-presented counts are in the bench JSON. The earlier figure (p50 = p95 = max 16.67 ms, n 595) sampled the display-link timestamps only and so measured the display's cadence, not committed canvas updates; it is superseded. In this run the overview toggle also measured p50 66.07 ms, p95 95.99 ms, max 112.32 ms (n 100), inside the 100 ms limit with little margin. A first pan probe that scrolled over the socket (`test.scroll` per step) measured p95 40.69 ms; that was the socket round trip and the canvas state serialisation, not drawing, so the probe now pans inside the app.

Overview toggle fix (bf-fix-overview-toggle-budget, D37). The user test of 2026-10-30 measured p50 75.08 ms, p95 113.19 ms, max 121.32 ms against the 100 ms limit, and a rerun on the same HEAD reproduced it (`.logs/bf-toggle-before.json`: p50 81.20, p95 117.33, max 118.56 ms, n 100); leaving the page was the slow half (78 to 121 ms; entering 51.5 to 72.8 ms) because it waited for a capture that takes 25 to 82 ms (median 48 ms, 70 captures). The capture deadline is now 15 ms and a preview landing under a move no longer fades in, so the worst case is 15 + 50 + 33.3 = 98.3 ms by construction. Command (unchanged benchmark, 20 warm-up and 100 alternating toggles, Reduce Motion on, 20 live pages with previews, 1440x900, 60 Hz): `python3 scripts/bench.py overview --out .logs/bf-toggle-after.json` (stdout in `.logs/bf-toggle-after.out`). Run 1: toggle p50 68.57 ms, p95 84.50 ms, max 88.76 ms (n 100); pan p50 16.66 ms, p95 16.87 ms, max 17.54 ms (n 598 intervals from 603 steps and 603 commits, 0 not presented). Run 2 (`.logs/bf-toggle-after2.json`): toggle p50 62.79 ms, p95 82.31 ms, max 86.38 ms; pan p95 16.88 ms (n 596), max 29.22 ms. Both PASS; the older toggle rows above are superseded.

Footprint, 400 MB comparison (FT2, D32). The acceptance is Photon <= Chrome in the same session with a full, bounded cache; the 400 MB budget is defined for one settled page (VAL-ENGINE-013) and is recorded here as a MISS for 20 pages. Photon's 909.3 MiB is 22 renderer processes (20 pages plus two more) at 686 MiB, three other helper processes at 132.5 MiB, and the browser process at 89.9 MiB (preview cache 10 MiB). Chrome on the same 20 URLs sums to 1114 MiB, so Photon is 18% lower, as the single-page spike (195 MB versus 451 MB) predicted. A 400 MB total for 20 live pages means about 20 MB per renderer; one Chromium renderer holding a small fixture page costs about 31 MiB on its own. The only lever is sharing renderers between pages (`--process-per-site` or a renderer limit), which would put pages of one site in one process and trade away the isolation that agent-driven pages need, so it was not applied. The 400 MB bound holds for the one to few pages of the spike and not for 20.

The cefclient figures above (D15) are not re-measured; `cefclient-baseline` was not run.

Overview toggle with the capture back in front (bf-fix-noninvasive-leaving-capture, D38; supersedes the 15 ms deadline of D37). The leaving capture is a no-clip viewport screenshot (JPEG q60), cropped and scaled in the ImageIO thumbnail decode, with the key reads sent concurrently; leaving waits for it, so the overview starts from the fresh image. `scripts/bench.py overview` now closes its own blank tab after the 20 pages open (20 tabs, 20 nodes) and records, for every leaving toggle, the capture's start and finish and the camera or swap start. Command (unchanged timing loop: 20 warm-up and 100 alternating toggles, Reduce Motion on, 20 live pages with previews, 1440x900, 60 Hz, M4, macOS 27.0.1): `python3 scripts/bench.py overview --out .logs/bf38-final1.json` and `.logs/bf38-final2.json` (the final code; `capture_pairs` keeps each leaving toggle's capture start and finish and presentation start, and `pass` needs every leaving capture `stored`). Two runs taken while macOS Storage Management was scanning at load average 9 to 36 gave toggle p95 97.9 and 100.8 ms with capture p95 43.9 and 45.6 ms; they are not the figures above, and the load, not the code, is the difference: earlier runs on the same capture path measured toggle p95 87.95 and 88.25 ms (`.logs/bf38-run1.json`, `.logs/bf38-run2.json`).

| Run | Toggle p50 / p95 / max (n 100) | Pan p50 / p95 / max (intervals) | Leaving capture p50 / p95 / p99 / max (n 60) | Captures finished after the presentation started | Deadline misses |
| --- | --- | --- | --- | --- | --- |
| 1 | 67.08 / 85.78 / 90.90 ms | 16.66 / 16.89 / 17.49 ms (597) | 24.09 / 34.29 / 39.60 / 39.60 ms | 0 of 60 | 0 |
| 2 | 67.78 / 87.28 / 104.22 ms | 16.66 / 16.93 / 17.60 ms (597) | 24.00 / 33.18 / 49.04 / 49.04 ms | 0 of 60 | 0 |
| both | p95 < 100 ms: pass | p95 <= 20 ms: pass | n 120: 24.08 / 33.95 / 45.78 / 49.04 ms | 0 of 120 | 0 |

An earlier run with the same code and a 200 ms deadline (`.logs/bf38-a.json`): toggle p50 67.92 / p95 87.68 / max 106.34 ms, captures p50 23.56 / p95 36.33 / p99 50.50 ms (n 60). The safety-net deadline is 100 ms, above every capture seen. Before the change the same capture (clip, serial frame-tree, layout-metrics and key reads) took 25 to 82 ms, median 48 ms, and 61 of 61 finished after the overview began. A six-page run with Reduce Motion off (camera): 30 leaving captures, p50 24.8 / p95 38.1 / max 47.8 ms, 0 finished after the camera started, 0 deadline misses. In an isolated probe of one tab, a viewport screenshot took p50 33.6 ms (clipped: 65.4 ms; `optimizeForSpeed` made no difference) and one `Page.startScreencast` frame p50 16.4 ms (not used, D38).


## Acting: DOM act, settle and Atom warm latency (2026-10-30)

Command: `python3 e2e/test_act_kinds.py ActLatency RealAtom SettleTests` (measurements in the e2e log dir as `act-latency.json`, `atom-warm.json`, `settle-*.json`). Bundled app, 483 x 407 viewport, M4, macOS 27.0.1, load average 5 to 9 from other work during the runs. The D42 rows (settle on the main frame only) were measured on 2026-10-31 with `python3 e2e/test_act_kinds.py` (1-minute load average 3.6 at the start, 9 to 10 near the end; `SettleTests` alone at 3 to 5), saved as `settle-*.json`; a `SettleTests` run at load 5 to 8 once measured the stopped navigation at 10231 ms and passed twice on rerun. DOM act p50 in the same run: 99.8 ms (p95 106.6, max 130.9, n 40).

Verifier in these runs: none. Every figure in this section was measured at or before commit 62f9298 (2026-10-31 01:27 +0700); the outcome verifier and its `test.verifier` hook arrived in af72274 (02:48 +0700, `git grep test.verifier` finds nothing at 2113411 or 62f9298), so those acts confirmed on the page read-back alone, with no model call and no stub. The rows measured with the verifier stubbed (`test.verifier` agree) are in the D50 section below, and the live verifier's own cost is in the last section.

| Budget | Limit | Measured | Verdict |
| --- | --- | --- | --- |
| DOM `act` by ref (20 clicks and 20 types on the act fixture), socket call to final-state response, settle included; no verifier existed yet (see above) | p50 < 250 ms (VAL-ACT-003) | n 40: p50 95.4 ms, p95 105.9 ms, max 113.1 ms (two more runs: p50 93.8, p95 108.9, max 114.7; and p50 100.0, p95 107.8, max 117.0 at load average 27) | pass |
| Atom `ground`, warm (one warm-up call, then 12), request line written to parsed point (screenshot capture and temp file excluded) | median < 500 ms (VAL-ACT-009) | median 344.6 ms, min 330.7, max 352.8 (two more runs: median 326.2, min 313.2, max 338.4; and median 347.9, min 343.3, max 357.2 at load average 27) | pass |
| Settle, click starting `/slow-xhr?ms=600` | 600 to 850 ms | 702.5 ms (600 ms response + 80 ms quiet + the call) | pass |
| Settle, page mutating every 20 ms | 2 s +/- 100 ms | 2005.3 ms | pass |
| Settle, click starting a navigation to a page delayed 3 s | after the load, not 2 s | 3118.4 ms | pass |
| Settle, click starting a navigation that never commits (`/hang`), D42 | 10 s +/- 200 ms; row `outcome-unknown`, reason `navigation stopped: no response in 10 s` | 10009.8 ms (alone, three runs: 10012.5, 10009.7, 10010.9); settle `{ms 10002, capped, navigationStopped}`; the next act reached the page in 57.7 ms | pass |
| Settle, agent navigate to a committed page holding one image 12 s (D42) | <= DOMContentLoaded + 2.3 s; no stop; image delivered | settle 2011 ms (call 2016 ms), `navigationStopped` false, fixture log `HELD /slow-image started, delivered`, readyState `complete` after | pass |
| Settle, agent navigate to a page that opens a 15 s long-poll after load (D42) | <= DOMContentLoaded + 2.3 s; poll completes | settle 2009 ms (call 2014 ms), `navigationStopped` false, `HELD /long-poll started, delivered` | pass |
| Settle, click inserting an iframe to `/hang` (D42) | 2 s +/- 200 ms; nothing stopped | settle 2001 ms (call 2004 ms), `navigationStopped` false, `HELD /hang started, delivered` | pass |

The DOM act time is mostly the two round trips that locate and check the element and the 80 ms quiet period; the settle waits on events, never a fixed pause. Atom's first call after the runtime starts loads the model (about 2.9 s in the research notes) and is not in the median.

## Slim Atom runtime (2026-11-01, D71)

Same machine, 1-minute load average about 5. `BARESTATE_RUNTIME_DIR=/tmp/bs-atom-slim scripts/setup-atom.sh runtime` into an empty directory, then `du -sh` of it; warm `ground` through `runtime/atom/atom_runtime.py` on that venv with the read-only installed model (one warm-up, then 12 timed calls; screenshot generation excluded); in-app warm median from `BS_E2E_LOGDIR=/tmp/bs-atom-logs BARESTATE_ATOM_PYTHON=/tmp/bs-atom-slim/venv/bin/python python3 e2e/test_act_kinds.py RealAtom` (the `/tmp/bs-atom-logs` e2e log dir is deleted; the numbers are here and in `.logs/atom-slim-warm.json`).

| Budget | Limit | Measured | Verdict |
| --- | --- | --- | --- |
| Fresh Atom runtime size (`du -sh`), slimmed lock + cache deleted after sync (D71) | smaller than the previous 2.4 GB | **1.2 GB** (venv 1.1 GB, managed Python 56 MB, uv 38 MB) | **pass** |
| Atom `ground`, warm, direct stdio on the slim venv | median < 500 ms | median **333.5 ms**, min 321, max 347, n 12 (second run median 338.0) | **pass** |
| Atom `ground`, warm, in-app (`test.ground`) on the slim venv | median < 500 ms (VAL-ACT-009) | median **330.9 ms**, min 324.0, max 349.1, n 12 | **pass** |

A real act "Click Save" on `fixtures/ground.html` with `BARESTATE_ATOM_PYTHON` pointing at the slim venv landed `confirmed` on the atom rung (journal row `(confirmed, click, atom)`; the page read `click 1`), and `smoke_ground.py` passed against the read-only model.

## Acting: DOM act after the pre-write recheck (2026-10-31, D50)

Command: `python3 e2e/test_act_kinds.py ActLatency`, run twice on the HEAD bundle and twice on the D50 bundle, 1-minute load average 4.7 to 5.0. HEAD: p50 149.9 and 150.0 ms, p95 152.2 and 164.6 ms (n 40). D50: p50 150.2 and 150.0 ms, p95 166.5 and 166.7 ms. Budget p50 < 250 ms: pass; no measurable change. DOM path with the verifier stubbed: these runs were after af72274, and `ActBase.setUp` in `e2e/test_act.py` calls `test.verifier` with `{"mode": "agree"}` before every test, so the page read-back decided and no model call was made.

## Acting: VAL-ACT-003, DOM path with the verifier stubbed, and the live verifier on its own (2026-10-31)

Two separate figures. The first is the budget; the second is a different cost (a model round trip) and is not counted against the 250 ms DOM budget.

| Budget | Limit | Measured (labelled measured) | Verdict |
| --- | --- | --- | --- |
| DOM act path, verifier stubbed (`test.verifier` agree): 20 clicks and 20 types by ref on `fixtures/act.html`, socket call to final-state response, settle and the kind-specific read-back included, no model call | p50 < 250 ms (VAL-ACT-003) | n 40: p50 150.18 ms, p95 166.63 ms, max 170.27 ms (an earlier run of the same command, `.logs/am-bench/act-latency-1.out`: p50 150.0, p95 164.9, max 168.5) | pass |
| Live screenshot verifier, added latency per act: the same act with the live verifier (`test.verifier` live, real `muse-spark-1.3`, before and after screenshots) minus the same act with the verifier stubbed | not counted against the 250 ms DOM budget | measured on the commit that carries this row (verifier cap 2000, effort minimal, pictures-only instructions, `fixtures/act.html` effect on screen; D56), 1-minute load 4.2 to 5.0 across the three runs: `set -a; . ./.env; set +a; BARESTATE_LIVE_META=1 BARESTATE_SPEND_LOG=$PWD/.logs/spend.json python3 e2e/test_act_kinds.py ActLatency.test_live_verifier_added_latency_per_act`, run three times (`.logs/am-visible/live-latency*.out`). n 3 pairs per run, deltas (click, type, click): run 1 +1841.0, +1916.4, +4049.5 ms; run 2 +2283.3, +1635.3, +2338.0 ms; run 3 +1733.7, +1399.3, +1921.3 ms; all nine live acts `confirmed`; median of the nine +1916.4 ms (per-run medians +1916.4, +2283.3, +1733.7 ms); verifier output tokens 136, 198, 82 in run 1; spend $0.004388, $0.003522, $0.003193. The previous row (ce05a25, old instructions) read +1973.8 (click), +1208.7 (type), +1028.8 ms (click), median +1208.7 ms from one run of three pairs | reported, no limit |

Commands (HEAD 51b81a9 plus the live test added with this entry, bundled app, 483 x 407 viewport, M4, macOS 27.0.1):

```
python3 e2e/test_act_kinds.py ActLatency                      # 1-minute load average 5.1 at the start, 5.9 at the end; .logs/am-bench/act-latency-1.out
BS_E2E_LOGDIR=$PWD/.logs/am-bench/dom python3 e2e/test_act_kinds.py ActLatency   # load 5.9 to 6.9; table row above; .logs/am-bench/act-latency-2.out, dom/act-latency.json
set -a; . ./.env; set +a; BARESTATE_LIVE_META=1 BARESTATE_SPEND_LOG=$PWD/.logs/spend.json BS_E2E_LOGDIR=$PWD/.logs/am-bench/live4 python3 e2e/test_act_kinds.py ActLatency.test_live_verifier_added_latency_per_act   # load 6.95 at the start, 6.19 at the end; .logs/am-bench/act-live-4.out, live4/act-live-verifier.json, live4-notes.txt
```

The DOM runs skip the live case (it needs `BARESTATE_LIVE_META`/`BARESTATE_SPEND_LOG`); the key is loaded only inside the live command. The live case checks the ledger's `total_usd` stays under $40 and this run under $3, and that each live act raised it (a billed model call); this run took it from 0.617345 to 0.623311 (`live4-notes.txt`). Both halves of a pair capture the before and after screenshots, so the delta is the extra work of the live verification (the model round trip and saving the images) plus timing noise, not only HTTP time. In two of the three pairs the model read the fixture's Count click as "no visible change" and the act ended `outcome-unknown` (a disagreement with the page read-back); the latency is of the verifier call either way. Other runs of the same case the same day: an earlier run with a stricter assertion gave +4585.5, +2976.5 and +2852.0 ms (median +2976.5 ms, spend $0.008538, `.logs/am-bench/act-live.out`, `live/act-live-verifier.json`); two further runs failed that stricter assertion because the verifier's reply to the typed act came back as `unavailable: malformed verdict` (the ledger shows 600 output tokens for those calls, the request's `maxOutputTokens`; `.logs/am-bench/act-live-2.out`, `act-live-3.out`), so they produced no figures, and the case now asserts only that the live act was billed.

Earlier run of the live pairs, quoted from the round-1 user-testing report (`validation/agent-muse/user-testing/flows/act.json` in the mission directory, script `.logs/validation/agent-muse/act/live-source.py`, commit 07e2374): added 4167.4, 3594.4 and 3053.8 ms, median 3594.4 ms. The same report measured the stubbed DOM path at n 40, p50 150.3 ms, p95 166.1 ms, max 167.2 ms. The figures above are a fresh run, not those.

## Polish motion re-measure (2026-11-01)

The four frontend budgets re-measured on `make bundle` output with the polish motion on (first-preview fade, activity panel and step fades, notice, status dot, command-button cover fade, trail flow, thinking orb; D70). Same machine and method as the release-bundle section; the bundle is `.build/Photon.app` from this commit, ad-hoc signed. 1-minute load average at the start of each command: overview 6.82, launcher 6.14, footprint 5.25. Raw output: `.logs/pm-bench/` (`bench-overview.{out,json}`, `bench-launcher.{out,json}`, `bench-footprint.{out,json}`), `.logs/pm-orb/polish-cpu.json`.

| Budget | Limit | Measured | Verdict |
| --- | --- | --- | --- |
| Overview toggle, key-down to settled, Reduce Motion on, 20 live pages with previews, 100 alternating toggles | p95 < 100 ms | p50 52.29 ms, p95 **64.8 ms**, max 71.31, n 100 (`test.toggleTimings`) | **pass** |
| Pan frame interval, committed canvas updates, 5 x 2 s pans, 20 nodes, 60 Hz | p95 <= 20 ms | p50 16.66 ms, p95 **16.88 ms**, max 17.15, n 596; 0 not-presented steps | **pass** |
| Cmd-T to a usable launcher, 200 opens alternating a focused page and the overview (12 loaded pages, 10,000 history, 1,000 bookmarks) | p95 < 50 ms | p50 2.13 ms, p95 **2.31 ms**, max 2.54, n 200 | **pass** |
| Suggestion update per keystroke, same run | p95 < 50 ms | p50 8.64 ms, p95 **12.59 ms**, max 22.49, n 300 | **pass** |
| Footprint, one fixture tab settled 3 s, 2 alternating runs vs Chrome | within 5% of 199.4 MiB | Photon p50 **200.7 MiB** (199.6, 201.7; 6 processes); Chrome p50 537.7 MiB | **pass** |
| Motion CPU, app process, `top -l 6 -s 2`: idle with no run (registry empty), then orb + Muse pulse + trail flow all live in the overview | idle about 0; run adds a few percent of one core at most | idle 0.0, 0.4, 0.2, 0.4, 0.2, 0.1 %; with all three loops live 0.0, 0.4, 0.4, 0.4, 0.3, 0.3 % | **pass** |

Commands:

```
python3 -u scripts/bench.py overview --out .logs/pm-bench/bench-overview.json
python3 -u scripts/bench.py launcher --out .logs/pm-bench/bench-launcher.json
python3 -u scripts/bench.py footprint --footprint-runs 2 --out .logs/pm-bench/bench-footprint.json
# motion CPU: app started with --test-hooks over e2e/bs.py, `top -l 6 -pid <app pid> -s 2 -stats pid,cpu`,
# idle and with the orb, pulse and trail flow live (throwaway driver, not committed; output in .logs/pm-orb/polish-cpu.json)
```

## Full window: enter, leave and the existing budgets (2026-11-02, D78)

Entering and leaving Full window (Cmd-Return, key-down at `sendEvent` to a settled level with the motion ledger empty, `test.toggleTimings`), 20 live pages with previews, 1440x900, 60 Hz, Reduce Motion on (the instant path), `make bundle` output with `--test-hooks`. 10 discarded then 50 presses per direction, alternating, on top of the overview toggle (20 + 100) and the pan probe (5 x 2 s). Command: `python3 scripts/bench.py overview --out .logs/bench-view-full-window.json`. 1-minute load average at the start: about 9.

| Measure | Limit | Result | |
|---|---|---|---|
| Enter Full window | p95 < 100 ms | p50 0.68 ms, p95 **1.67 ms**, max 1.91 ms, n 50 | **pass** |
| Leave Full window | p95 < 100 ms | p50 0.66 ms, p95 **1.79 ms**, max 2.12 ms, n 50 | **pass** |
| Overview toggle (unchanged benchmark) | p95 < 100 ms | p50 52.13 ms, p95 **71.55 ms**, max 91.79 ms, n 100 | **pass** |
| Pan frame interval | p95 <= 20 ms | p50 16.67 ms, p95 **16.92 ms**, max 17.35 ms, n 597 | **pass** |

Under Reduce Motion a Full window move is instant: one frame change of the same browser view and no ledger item, so the level is settled at the commit (about a millisecond). Without Reduce Motion the move is one `camera` item of at most 0.45 s (spring) and the timer waits for the ledger to empty; that figure is not part of this table.

## Mouse pan, ⌘-scroll zoom and the zoom pill: overview budgets (2026-11-02, D79)

Same method and dataset as the Frontend section: 20 live pages with previews, 1440x900, 60 Hz, Reduce Motion on for the toggle, `make bundle` output with `--test-hooks`, 1-minute load average about 11 at the start. Command: `python3 scripts/bench.py overview --out .logs/bench-view-mouse.json` (stdout in `.logs/bench-view-mouse.log`). The new row presses on empty canvas at (1390, 450) and drags the pointer 8 x 3 pt per display-link tick, back and forth every 30 ticks, through `CanvasView.mouseDown`, `mouseDragged` and `mouseUp` (`test.frameProbe` with `pan.press`; the hook refuses a press that lands on a card). The interval is the time between the commits of consecutive pan steps.

| Measure | Budget | Result | |
|---|---|---|---|
| Overview toggle (20 + 100 alternating) | p95 < 100 ms | p50 53.66 ms, p95 **70.44 ms**, max 83.78 ms, n 100 | **pass** |
| Pan by scroll, committed canvas updates (5 x 2 s) | p95 <= 20 ms | p50 16.67 ms, p95 **16.93 ms**, max 17.34 ms, n 597; 602 steps, 602 commits, 0 not presented | **pass** |
| Pan by dragging empty canvas, committed canvas updates (5 x 2 s) | p95 <= 20 ms | p50 16.67 ms, p95 **17.21 ms**, max 32.56 ms, n 596 intervals from 602 steps and 601 commits | **pass** |

A first run of the same command, before the probe refused a press on a card, measured the drag at p50 16.67 ms, p95 17.12 ms, max 24.98 ms (n 598). The max is a single late frame under the machine load, not a trend; the p95 sits within 0.3 ms of the display's own 16.67 ms tick.

## Maximize from a card and restore to it (2026-11-02, D80)

Maximizing a hovered card's page from the overview by clicking its Maximize control, and restoring with the exit control (⤡), `test.toggleTimings`: the action to a settled level with the motion ledger empty. 20 live pages with previews, 1440x900, 60 Hz, Reduce Motion on (the cut-and-fade path: the page appears at its full frame and the card preview fades off in 34 ms), `make bundle` output with `--test-hooks`. 10 discarded then 50 measured per direction, alternating over the 20 cards; the pointer is moved onto the control and the hover fill left to finish before each press, as a person's pointer would be. Run in the same session as the existing overview toggle and the pan probes. Command: `python3 -u scripts/bench.py overview --out .logs/bench-max-card-2.json` (stdout in `.logs/bench-max-card-2.log`). 1-minute load average at the start: about 3.

| Measure | Budget | Result | |
|---|---|---|---|
| Maximize from the overview (click on ⤢) | p95 < 100 ms | p50 55.05 ms, p95 **64.68 ms**, max 67.16 ms, n 50 | **pass** |
| Restore to the overview (click on ⤡) | p95 < 100 ms | p50 79.28 ms, p95 **94.20 ms**, max 174.21 ms, n 50 | **pass** (thin) |
| Overview toggle (20 + 100 alternating) | p95 < 100 ms | p50 51.52 ms, p95 **71.51 ms**, max 73.17 ms, n 100 | **pass** |
| Pan frame interval, scroll (5 x 2 s) | p95 <= 20 ms | p50 16.67 ms, p95 **17.04 ms**, n 599 | **pass** |
| Pan frame interval, empty-canvas drag | p95 <= 20 ms | p50 16.67 ms, p95 **17.08 ms**, n 588 | **pass** |

Notes on the numbers:

- A first complete run (`.logs/bench-max-card.json`, load about 4) gave maximize p95 102.07 ms (three stragglers of 100, 111 and 171 ms among 50, p50 53.30) and restore p95 95.57 ms: it failed the maximize bound by 2 ms. The second run above passed. The typical maximize is 50 to 60 ms; a straggler is a loaded machine, not a path difference.
- Restore costs more than maximize because it captures the page's last look first, as every move into the overview does, and a Full window page is larger than a focused one. Its p95 has under 6 ms of headroom here; a loaded machine can cross 100 ms.
- The settle is read from `test.motion`, as the contract defines it. With the screen locked an idle app is never asked to display, and a finished Core Animation completion is only delivered when something reads the layers; unread, the ledger's fallback (the item's length plus 150 ms) ends the move and every sample reads about 200 ms. The bench reads `test.motion` every 10 ms while it waits; a person looking at the window gets the completion from the display.
- A key-down stamp within the last second is not used for a move a pointer started, so a keystroke just before a click is not billed to it (`ToggleTimer.begin(toward:byKey:)`).
