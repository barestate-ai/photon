# Photon handover

Written 2026-11-02 for an engineer taking over the project cold. Everything here was checked against the repository or the mission records when it was written. Where something was not run or is not known, the text says so.

## 1. What Photon is

Photon, by Barestate, is a native macOS browser. It was called "Barestate Browser" before. Many internal names still say Barestate: the bundle id, the data directory, the socket, the SwiftPM targets, the environment variables and the binaries. Only what a person sees says Photon.

- It is Swift and AppKit around Chromium Embedded Framework (CEF 156.0.14). It is not Electron.
- It has no toolbar, tab strip, address bar or sidebar. The window is borderless. Open pages are live cards on one spatial canvas, joined by trails (links, popups, and the steps Muse took).
- Command-T opens one launcher: URLs, web search, switching to an open page, browser commands and requests for Muse.
- Muse is Meta's agent. It acts in the user's real logged-in session, from the Mac or from a phone. The person can take over at any moment (any real input in the page fences the agent). Sensitive actions (delete, purchase, password field, submit) wait for "Allow once". Every action leaves a verified record: a before and after check, not just "the click was sent".
- Atom is a small local model bundled as an optional install. It turns "click Save" plus a screenshot into a point, before Photon asks Muse. It was built before this project (`barestate-ai/atom-inference`). Photon vendors its runtime in `runtime/atom/` and ships the weights as a separate archive.

The product description is in `README.md`. The plan is `PLAN.md`. `HACKATHON.md` separates what existed before the mission from what was built. `DECISIONS.md` is the decision log (D1 to D80) and the place to record new decisions.

## 2. Current state (2026-11-02)

- Release `v0.1.0` is on GitHub (`github.com/barestate-ai/photon`, private). Assets:
  - `Photon-0.1.0.dmg`, 164,563,535 bytes
  - `Photon-0.1.0.zip`, 150,423,229 bytes
  - `atom-tinyclick-4bit-v1.tar.gz` (the Atom model archive)
  - `SHA256SUMS`
- The app CDHash is `e23fc4396801c6a67cf0d1f19d302a640cc5213c`, the same in the ZIP, the DMG and `.build/Photon.app`. It is ad-hoc signed, not notarized (see section 9).
- `main` was at `45ceebf` ("Record the menu-dismiss refresh CDHash and sizes") before this document was added. `origin/main` matched it.
- All 216 assertions in the mission's validation contract are recorded as passed.
- The latest work, in order:
  - Direct page selection: an "Open pages" scope in the launcher (D75).
  - Full window and native full screen (D78).
  - Mouse support in the overview: ⌘-scroll zoom, drag empty canvas to pan, a zoom pill, a lift on a dragged card (D79).
  - Maximize: a button on every card, a right-click menu (Open, Maximize, Close Page), and a restore that goes back to the card (D80).
  - A takeover fix: the click that dismisses the card menu over a live page is consumed (commit `b035035`).
- The installed `/Applications/Photon.app` is the refreshed build, but it is not connected to Barestate Muse yet (section 8).
- The commit hashes cited in older `DECISIONS.md` and `BENCH.md` entries come from the original development history. The published history on GitHub is a clean re-commit, so those hashes do not resolve (`HACKATHON.md` explains this). Hashes from the Maximize and menu-dismiss work onward are real.

## 3. Repo map

Build and tooling:

- `Package.swift`: SwiftPM, Swift 6, macOS 14. No package dependencies (`make check-agpl` fails if one is added). Every C++ and ObjC++ target must define `NDEBUG`, because CEF changes class layout otherwise.
- `Makefile`, `scripts/`: see section 4.
- `Vendor/`: CEF 156.0.14 and `cefclient.app`. Git-ignored, fetched by `make vendor`. About 675 MB.
- `.build/`: build output. `.build/Photon.app` is the only app bundle. `dist/` is git-ignored too and holds the release files. `.logs/` is git-ignored and holds bench and test output.

Swift targets (`Sources/`):

- `BarestateCore`: pure logic with no AppKit or CEF imports, unit-tested with Swift Testing in `Tests/BarestateCoreTests`. Domain logic goes here. Things to know:
  - `AgentLoop.swift`, `Runs.swift`, `ModelClient.swift`, `MetaResponsesProvider.swift`: the Muse run and the model client.
  - `Grounding*.swift`, `AtomClient.swift`, `AtomInstall.swift`: the act ladder (DOM, then Atom, then Muse's computer tool).
  - `Verifier.swift`, `ReadBack.swift`: outcome checks.
  - `Approval.swift`, `Sensitivity.swift`: Allow once rules.
  - `PageGraph.swift`, `CanvasGeometry.swift`, `ViewLevel.swift`, `CardAction.swift`: the canvas model.
  - `LauncherModel.swift`, `LauncherRanking.swift`: the launcher.
  - `ModelKey.swift`, `BarestateMuse.swift`: model key lookup and the Barestate API client.
  - `Gateway.swift`, `PhoneAPI.swift`, `Pairing.swift`, `MCP*.swift`: remote and MCP.
  - `LaunchOptions.swift`: `--data-dir`, `--test-hooks`, `--url`.
- `Barestate`: the AppKit app. `AppController*.swift` is the main-actor controller. `CanvasView`, `NodeCard`, `ZoomPillView`, `MaximizeButton`, `CardMenuView` are the canvas. `SettingsWindow` is Settings. `TestHooks*.swift` are the `test.*` socket methods; they are unreachable without `--test-hooks`.
- `CEFBridge` (ObjC++) and `CEFWrapper`: the CEF glue. `BarestateHelper`: the CEF helper process.
- `barestate-mcp`: a stdio MCP proxy that forwards to the running app's socket. `barestate-gateway`: the phone and Remote gateway.

Other directories:

- `e2e/`: Python end-to-end tests (`test_*.py`) plus `bs.py` (the harness), `appcase.py` and `run.py` (the runner). They drive the real bundle through its Unix socket with `test.*` methods. Standard library only.
- `fixtures/`: the local fixture server (`server.py`, port 47810) and test pages.
- `server/barestate-api/`: the Cloudflare Worker (`worker.mjs`, `worker.test.mjs`, `wrangler.toml`).
- `runtime/atom/`: the vendored Atom runtime and installer.
- `Resources/`: fonts (OFL), the phone page (`phone/`). `Resources/Art/` is git-ignored and must never be committed or bundled.
- `docs/`: `muse.md` (Custom Connector), `muse-code.md`, four screenshots, the demo video.

The Muse prompts (read these before changing agent behavior):

- `Sources/BarestateCore/AgentLoop.swift:22-38`: the agent loop's instructions (`observe` before `act`, read `state` and `reason` after each act, never type passwords).
- `Sources/BarestateCore/Verifier.swift:54-62`: the before and after screenshot verifier.
- `Sources/BarestateCore/GroundingProbe.swift:164-166`: the grounding prompt for Muse's computer tool.
- The model is `muse-spark-1.3` for all three.

## 4. Build, run, test, release

Needs Apple silicon, macOS 14 or later, the Xcode Command Line Tools (Swift 6) and `python3`. Check `df -h` first: a release build and bundle need several GB.

Makefile targets:

```sh
make vendor     # fetch and verify the pinned CEF builds into Vendor/ (idempotent)
make build      # swift build -c release
make bundle     # build, then scripts/bundle.sh: assemble and ad-hoc sign .build/Photon.app
make test       # swift test -c release (Swift Testing; the target adds the plugin path)
make test-api   # node --test server/barestate-api/worker.test.mjs
make lint       # swift format lint --strict, bash -n on scripts, Python syntax check
make check      # build, test, test-api, scripts/check-secrets.sh, check-agpl, lint
make e2e        # make bundle, then python3 e2e/run.py (the whole suite)
make bench      # python3 scripts/bench.py (cold start and footprint)
make atom       # install Atom into ~/Library/Application Support/Barestate
make atom-archive  # write dist/atom-tinyclick-4bit-v1.tar.gz
make dmg        # dist/Photon-<version>.dmg from the existing bundle
make dist       # scripts/release.sh: dist/Photon-<version>.zip
```

Do not run `make clean`. It deletes `.build` and `dist`, and `dist` holds the release files and the model archive.

Running the app from a checkout:

```sh
scripts/run-app.sh                                   # foreground; arguments go to the app
scripts/run-app.sh --data-dir /tmp/bs-demo --test-hooks
scripts/stop-app.sh /tmp/bs-demo                     # SIGTERM, then SIGKILL; reads <data-dir>/app.pid
```

- `--data-dir <dir>` keeps all state (profile, SQLite, socket, logs, settings) in that directory. The default is `~/Library/Application Support/Barestate/browser`. Use a short path: a Unix socket path must be under 104 bytes.
- `--test-hooks` turns on the `test.*` socket methods that the e2e suite uses. It also stores the Barestate Muse device token in a 0600 file in the data dir instead of the Keychain.
- Logs are in `<data-dir>/logs/photon.log` and `cef.log`. They hold ids, counts and `scheme://host` only, never URLs with paths, page text, typed text or tokens.

End-to-end tests:

- `make e2e` runs everything. It starts its own fixture server on 47810 and one app per test class, and logs to `.logs/e2e/<timestamp>/`.
- To run one module (build the bundle first with `make bundle`):

  ```sh
  cd e2e && python3 -m unittest test_view_mouse
  cd e2e && python3 -m unittest test_view_mouse.<Class>
  cd e2e && python3 -m unittest test_view_mouse.<Class>.<test_name>
  ```

  `python3 test_core.py ObserveTests` also works (the files have a `__main__`). Do not use `python3 e2e/appcase.py --class ...`: it is a library and silently does nothing.
- Kill any stray `fixtures/server.py --port 47810` process before a run, or you get connection-refused cascades.
- Tests that call the real model are skipped unless `BARESTATE_LIVE_META=1` and a key are set. Do not set that flag for the launcher tests; real runs add Stop rows and break their row counts. Run live tests by class.

Benchmarks: `python3 -u scripts/bench.py <overview|launcher|frontend|footprint|footprint-20|cold-start|all> --out .logs/<name>.json`. BENCH.md has the exact commands used for each number.

Checks to run before any commit: `make check`. It includes the secret scan (`scripts/check-secrets.sh`, which fails on key-shaped tokens, a tailnet host name, forbidden artifacts, or an un-ignored `.env`).

### Release refresh

The release is `v0.1.0`. Every fix that ships rebuilds the bundle and replaces the assets in place. The rules:

1. Sign once. `scripts/release.sh` runs `make bundle` (which signs) and zips the result. Then run `scripts/dmg.sh`, which only packs the existing `.build/Photon.app`. Do not run `make bundle` between the two, or the ZIP and DMG will carry different signatures. Both scripts refuse to run with less than 1.5 GB free after the file.
2. Check that the CDHash is the same in all three places: `.build/Photon.app`, the app extracted from the ZIP (`ditto -x -k`), and the app inside the mounted DMG (`hdiutil attach -readonly`, then `hdiutil detach`):

   ```sh
   codesign -dvvv <path-to>/Photon.app 2>&1 | grep CDHash
   ```
3. Write `dist/SHA256SUMS` last, after the DMG and ZIP are final, in the same order as the current file (atom archive, DMG, ZIP). The format is `shasum -a 256` output (hash, two spaces, file name). The atom archive is unchanged unless Atom itself changed.
4. Upload the changed assets:

   ```sh
   gh release upload v0.1.0 --repo barestate-ai/photon --clobber \
     dist/Photon-0.1.0.dmg dist/Photon-0.1.0.zip dist/SHA256SUMS
   ```
5. Prove it: download all assets into a scratch directory and check them.

   ```sh
   gh release download v0.1.0 --repo barestate-ai/photon --dir /tmp/photon-verify
   cd /tmp/photon-verify && shasum -c SHA256SUMS
   ```
6. Record the new CDHash and sizes in `BENCH.md` (and `README.md` if it quotes them), then commit and push. Recent commits "Record the ... release refresh CDHash and sizes" show the pattern.

The benches are not re-run on a refresh by default. BENCH.md says which build each number came from.

## 5. Model access

Photon needs a model key for Muse. It looks in this order, and the first hit wins:

1. `MODEL_API_KEY` in the environment.
2. `MODEL_API_KEY` in the env file: the file named by `BARESTATE_ENV_FILE`, else `.env` in the working directory. In a checkout, `.env` is git-ignored. Never print, log or commit it. The name must be exactly `MODEL_API_KEY`; `env.example` is the template.
3. The Keychain generic password `meta-model-api`. An app opened from the Dock has no `.env`, so this is how an installed app gets a key:

   ```sh
   security add-generic-password -s meta-model-api -a "$USER" -w
   ```

With a key of its own, Photon calls Meta directly. With none, it uses the Barestate API:

- The base URL is `https://api.barestate.xyz/v1/muse`. Set `BARESTATE_API_URL` to override it.
- The device token is in the Keychain item `barestate-api` (a 0600 file in the data dir under `--test-hooks`).
- To get a token: Settings (⌘,) > Model > Use Barestate Muse, paste an invite code, Connect. Disconnect removes the token. A device at its cap gets the proxy's 402 message as the refusal.
- Code: `Sources/BarestateCore/BarestateMuse.swift`, `ModelKey.swift`. Decisions: D73, D74, D76.

The Barestate API (`server/barestate-api/worker.mjs`, a Worker with no npm dependencies):

- Routes: `GET /healthz`, `POST /v1/devices` (invite code in, device token out, once), `POST /v1/muse/responses` (proxy to Meta).
- The server stores only the SHA-256 of each device token in KV.
- Spend caps: $2 per day per device and $10 per day global (`DEFAULT_DEVICE_DAILY_CAP_USD`, `GLOBAL_DAILY_CAP_USD` in `wrangler.toml`). The counters are read-modify-write in KV, so they are soft caps and a burst can overshoot a little. This was accepted (D73).
- Streaming is refused with 400 before any upstream call, and a non-JSON 2xx from upstream becomes a 502. This closed a cap bypass (D76).
- It never logs prompts, images, tokens or the key.

Everything runs on Cloudflare. Google Cloud is not used; nothing was created there.

- Worker `barestate-api`, custom domain `api.barestate.xyz`.
- KV namespace `barestate-api-kv`. The invite codes are a JSON list in the key `invites`.
- Worker secret `META_API_KEY`.
- R2 bucket `barestate-downloads`, served at `download.barestate.xyz`. It holds `atom-tinyclick-4bit-v1.tar.gz`, which Settings > Atom > Install Atom downloads. The GitHub release asset is the fallback.

Operating it (wrangler is installed globally and logged in on the owner's Mac):

- Deploy from the repo with `scripts/deploy-api.sh`. It is idempotent. It creates or syncs the KV namespace, the secret and the `invites` key only when missing, then deploys. Do not run a bare `wrangler deploy`. Wrangler needs the account id in `CLOUDFLARE_ACCOUNT_ID`; the script sets it, and the value is in `server/barestate-api/wrangler.toml`.
- Tests: `make test-api`.
- Read the invite codes (this prints secrets, so do it only on your own terminal):

  ```sh
  wrangler kv key get --remote --namespace-id b52da027ff9d4afc91acacbd86efa1d5 invites
  ```

  Add codes with `wrangler kv key put --remote` on the same key.
- `wrangler kv key ...` and `wrangler r2 object ...` need `--remote`. Without it wrangler silently writes to a local simulation under `.wrangler/` and prints success. The Worker never sees it.
- The KV store is eventually consistent. A new device token can get a 401 at a distant edge for up to about a minute.

## 6. Performance budgets

All numbers below are measured, from `BENCH.md`, on an M4 Mac mini with macOS 27.0.1. Read BENCH.md for the command, sample count, load average and raw output of each. Run benches only when the 1-minute load average is below about 8 (below 4 for the maximize and restore rows). Percentiles are nearest-rank. Most rows were taken on the earlier release build; the benches were not re-run on the later refreshes except where the table says otherwise.

| Budget | Limit | Measured |
|---|---|---|
| Cold start, warm cache (to first paint) | median < 1.5 s | p50 240.55 ms (10 launches) |
| Cold start, first launch after a new signature | same limit | p50 1761.1 ms. A miss; the OS assessing a new signature, not isolated further (D15) |
| Footprint, one page | < 400 MiB and no worse than Chrome | Photon p50 199.4 MiB, Chrome 522.8 MiB. Pass |
| `observe` (151 elements) | p50 < 150 ms | p50 38.2 ms |
| DOM act, verifier stubbed | p50 < 250 ms | p50 150.0 ms. The live verifier adds about 2.7 s per act (reported, not budgeted) |
| Atom `ground`, warm | median < 500 ms | median 325.5 ms |
| ⌘T to a usable launcher | p95 < 50 ms | p95 3.15 ms (2.31 ms on the polish build) |
| Suggestion update per keystroke | p95 < 50 ms | p95 12.04 ms |
| Overview toggle | p95 < 100 ms | p95 64.8 ms on the polish build; 71.51 ms in the latest run |
| Pan frame interval (scroll, and drag) | p95 <= 20 ms | scroll p95 17.04 ms, drag p95 17.08 ms |
| Maximize from a card | p95 < 100 ms | p95 64.68 ms (D80) |
| Restore to the card | p95 < 100 ms | p95 94.20 ms, p50 79.28 ms (D80). Thin headroom |

Recorded misses, not hidden:

- Footprint with 20 fixture pages is 871.1 MiB (Chrome 1104.1). Above 400 MiB, below Chrome.
- Footprint with 20 real public pages is 1733.8 MiB against Chrome's 1486.4 MiB. Photon is above Chrome. One attempt found no low-risk lever (D63, D64).
- Do not share renderers (`--process-per-site`, renderer limits) to chase these figures. Pages that an agent drives need process isolation.

Restore has the least headroom. A first Maximize run at load about 4 also missed by 2 ms (three slow samples) and passed on the second run. If a run misses, re-run once at low load before treating it as a regression.

## 7. Known issues and gotchas

Environment and e2e:

- Native full-screen e2e (`FullScreenTests.test_native_full_screen_*` in `test_view_full_window.py`) cannot pass while the screen is locked. ⌃⌘F never enters full screen. Check first: `ioreg -n Root -d1 | grep CGSSessionScreenIsLocked`.
- `NoStrayWritesTests` in `e2e/test_engine.py` can fail while a user Photon is running, because it sees that instance's files in the default data dir. Quit it or rerun alone.
- `OrbTests` in `e2e/test_polish_motion.py`: the orb fade can fail once under load and passes on rerun.
- A full `make e2e` on a locked or background session showed about 42 environmental errors on the unmodified base: Settings, About and launcher close flows, QR and remote pairing, network-path toggling, some launcher tests. They are not product defects. Before counting one, rerun that test file alone on an idle machine.
- Do not run e2e or benches at a 1-minute load average of 8 or more (check `uptime`). Chromium's teardown watchdog can make a clean quit exit 2, and bench numbers rise (overview toggle p95 reached 98 to 101 ms against 85 to 88 ms on a quiet machine).
- Maximize and restore timing must poll `test.motion` about every 10 ms while waiting. On a locked or idle screen nothing reads the layers, so the Core Animation completion never arrives. The motion ledger's fallback (item length plus 150 ms) ends the move and every sample reads about 200 ms too high.
- The green window button's exit from native full screen is unreachable for synthetic input. In full screen the button's frame is at y=-22, outside the window, and a synthetic click hit nothing. Entry by the green button, and entry and exit by ⌃⌘F and the View menu, are covered. The contract was amended to not require the green-button exit.
- Synthetic input from a locked session is valid evidence for app logic. It is not evidence of real input.
- Traffic lights sit top left. Synthetic clicks must avoid x < 72 and y < 28, or they close the window.

Tools:

- wrangler can fail once with "Authentication error [code: 10000]", for example inside `scripts/deploy-api.sh`. Run it again; retry once before escalating.
- `scripts/stop-app.sh` SIGKILLs every descendant of the app, so it hides child-process leaks. A test that checks for orphaned children must signal the app directly (see `AtomQuitTests` in `e2e/test_atom_install.py`).
- With System Events, the app menu is menu bar item 2 (item 1 is the Apple menu). Quit by name ("Quit Photon"), never by index. AXPress through System Events works on a locked screen and does not move the cursor.
- A process started with `&` inside a tool call dies when the call returns. Use a proper background mechanism and kill it by PID. Do not use `pkill -f` or `pgrep -f` with a pattern that appears in your own command line.
- Never post CGEvents. They move the real cursor. All test input is NSEvents sent through `sendEvent`.

Product and code:

- The first launch after a new signature takes about 1.8 s. Later launches take about 240 ms. This is the OS, and the unmodified cefclient pays more (D15).
- All shortcuts are matched with exact modifiers in `BarestateApplication.sendEvent` and `performShortcut` (D16). A new menu item must register there too. AppKit's own key-equivalent search mismatches some combinations.
- Takeover: anything that acts on the live page (navigation, reload, native edits, keys) must fence agent control before it runs, whether it came from a shortcut, a menu item or a launcher row. Edits in the launcher, find or Settings fields never touch control.
- Photon disables Chromium's `MacAppCodeSignClone` feature. Do not re-enable it. Only `cefclient` (the bench baseline) still creates code-sign clones; do not re-run `bench.py cefclient-baseline`.
- Do not add timers to the resize sync in `BSCef.mm` (D32). Re-check it on a CEF upgrade.
- The tailnet host name for Remote is personal. Never write it into a tracked file; docs use `<your-mac>.<tailnet>.ts.net`. The secret scan enforces this.
- The Custom Connector path for the Muse app (`docs/muse.md`) is not verified against a real Muse account (FT5 in `DECISIONS.md`).
- Two concurrent `setup-atom.sh` runs into the same runtime directory race. The Settings button serializes installs, so a user cannot hit this.

## 8. Not tested

- Real physical mouse and trackpad input. Everything was driven by synthetic NSEvents.
- VoiceOver. Running it changes system settings. The accessibility tree is checked through the `test.ax` hook only.
- The system Reduce Motion setting. The app's own override (`test.reduceMotion`) was used.
- Muse Code end to end (the CLI was not installed) and the Muse Custom Connector with a real account.
- A live Baseten model. No key was available.
- The installed `/Applications/Photon.app` is not connected to Barestate Muse. The screen was locked during the release refresh, so Settings could not be used. To do it: open Photon, press ⌘, , choose Model, then Use Barestate Muse, paste an invite code and press Connect. It then reads Available. Startup success (`app.status` ready) does not mean the model is available.

## 9. Suggested next steps

- Connect Muse on the installed app (section 8) and run one real task as a smoke test.
- Add checks with real device input: a physical mouse wheel for ⌘-scroll, drag-pan and the Maximize controls, and a trackpad pinch.
- Sign with a Developer ID certificate and notarize. The app is ad-hoc signed today, so the first launch from a download needs "Open Anyway" (README, Install).
- Re-run the restore benchmark at low load on the next release, because its headroom is the thinnest.
- Keep recording changes in `DECISIONS.md` with the next free D number (D81), and keep `BENCH.md` figures labelled by the build they came from.
