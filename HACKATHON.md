# Hackathon: what existed and what was built

Photon, by Barestate. Dates are commit dates from the original development history (UTC+7), which ran from 2026-10-28 to 2026-11-01. Work after that, to 2026-11-02, is B17 to B21 below.

## About this repository's history

The history published on GitHub starts with a clean re-commit made on 2026-11-01: ten commits grouped by area (`604f47e` to `5926d01`), whose final tree is identical to the tree of the original history at that point. The original 116-commit development history, from 2026-10-28 05:42 to 2026-11-01, is kept on the local branch `pre-photon-history` and is not published. The commits after those ten (2026-11-01 and 2026-11-02) are ordinary history. The commit hashes cited in [DECISIONS.md](DECISIONS.md) and [BENCH.md](BENCH.md) for the earlier work refer to the original history, so they do not resolve in the published one; hashes from the Maximize work onward do.

## Existed before the mission (not built here)

| Item | Where it lives | When | What this repository takes from it |
|---|---|---|---|
| **The Atom model and its runtime.** A grounding model that turns "click the Download button" and a screenshot into a point, and the HTTP inference API around it. | `~/Developer/atom-inference` (`barestate-ai/atom-inference`), 5 commits | 2026-10-22 | Photon runs it as a separate local process and only calls it (`AtomClient`). The stdio runtime and installer, unchanged except two edits, are vendored in `runtime/atom/` at commit `f19f5d9` (MIT, licences included); the weights are not in git and ship as a release archive. |
| **The Barestate site and the Lift mark.** The landing page, brand, and the Atom stateful-download component. | `~/Developer/barestate-lp`, 59 commits | 2026-10-03 to 2026-10-23 | The Lift mark's two paths (redrawn in `Design.liftMark`) and the name. No site code is used. |
| **The Spatial Daylight design.** Figma page "22 · Browser · Spatial Daylight" (overview, ⌘T suggestions, typed request, working page in context, result states) and its tokens. | Figma file `dQrWf5iyqhwiHZNUKDDLwy` | before 2026-10-29 | The design that the canvas, launcher and tokens implement (D65). |
| **`~/Developer/atom-demo`.** An earlier demo of an Atom-driven browser agent, 19 commits, 2026-10-02 to 2026-10-13. | local | before the mission | Design reference only. Nothing was copied; it is not a dependency. |

Third-party parts: Chromium Embedded Framework 156.0.14 (fetched by `make vendor`, not stored in git), Manrope and Instrument Serif (SIL OFL, in `Resources/Fonts/`), the Muse models through Meta's API, and Tailscale Funnel for the public URL.

## Built during the mission (2026-10-28 to 2026-11-02)

Each item names the commits' dates and the decision entries. The ids are the ones [DEMO.md](DEMO.md) uses.

| Id | Built | Dates | Notes |
|---|---|---|---|
| **B1 Engine** | A signed, sandboxed CEF app in Swift/AppKit with multiple tabs, a Unix-socket API, DevTools transport, `observe` and `extract` of a page, and the test hooks the end-to-end suite drives | 2026-10-28 to 2026-10-29 | D1, D2, D10, D11 |
| **B2 Control** | Per-tab control epochs, takeover on any real input, handoff, the action journal, and acting on a page by ref | 2026-10-29 | D9, D12, D14 |
| **B3 The Photon shell** | Bundle `Photon.app`, the borderless window, the Lift mark, the one command button, page security caption, design tokens | 2026-10-30 | D22, D65 |
| **B4 The ⌘T launcher** | One launcher for URLs, search, tabs and requests, with a pure ranker, local suggestions, commands and scopes | 2026-10-29 to 2026-10-30 | D19, D24 |
| **B5 Overview canvas** | The page graph (links, popups, launcher), bounded memory-only preview cache, cards, trails, pan and zoom, camera, the Reduce Motion toggle | 2026-10-30 | D25, D27, D28, D30, D35 to D38 |
| **B6 Focused page in context** | A live page with its neighbours and trails around it, find, close | 2026-10-30 | D29 |
| **B7 Motion** | One motion ledger, the camera spring, flying previews, trail draw, run pulse, Reduce Motion | 2026-10-30 to 2026-10-31 | D31, D48 |
| **B8 The act ladder** | DOM, Atom and Muse grounding in order, event-driven settling, outcomes verified by before and after pictures | 2026-10-31 | D39, D40, D42, D55, D56 |
| **B9 Muse runs** | The agent loop on `muse-spark-1.3`, typed requests ("Start task"), Muse labels, run rows, the copper trail, Stop, outage recovery, spend ledger | 2026-10-30 to 2026-10-31 | D3, D39, D45 to D47, D53, D54 |
| **B10 Approvals** | Allow once for sensitive acts, bound to the page as it was quoted, on every path to the effect | 2026-10-31 | D43, D50, D52 |
| **B11 MCP** | One MCP dispatcher on the socket, the bundled `barestate-mcp` stdio proxy, and the Muse docs | 2026-10-31 | D49, `docs/muse-code.md` |
| **B12 Remote** | The gateway with bearer auth and pairing, Settings pairing with a one-time QR code, the phone page and its event stream, the Funnel mount | 2026-10-31 | D57 to D61, `docs/muse.md` |
| **B13 Measurement and release** | The startup, footprint and frontend benches, BENCH.md, the privacy-safe logs, crash capture, the end-to-end suite, `dist/Photon-<version>.zip` | 2026-10-29 to 2026-10-31 | D13, D15, D21, D32, D62 to D64 |
| **B14 Docs and media** | README, DEMO, this file, the decision log, four screenshots and a 70 s video, all from the running app | 2026-10-31 | D66 |
| **B15 The Barestate API** | A dependency-free Cloudflare Worker at `https://api.barestate.xyz` holding the Meta key as a Worker secret, with invite-code device registration (SHA-256 token hashes in KV), per-device and global daily USD caps, and a pass-through Muse proxy that never logs content | 2026-11-01 | D73 |
| **B16 Barestate Muse in Photon** | Settings "Use Barestate Muse" with an invite code and Connect/Disconnect (token in the Keychain, a 0600 file under test hooks), the own-key-first route to Meta or the proxy, and the proxy's 402 as the call's refusal | 2026-11-01 | D74 |
| **B17 Direct page selection** | An "Open pages" scope in the launcher, so a page can be picked from any number of open pages | 2026-11-01 | D75 |
| **B18 Polish fixes** | The Muse trail flow follows the page in use; quitting stops the Atom installer | 2026-11-01 | D77 |
| **B19 Full window** | A third view level: the same live page in a bigger frame, and native full screen | 2026-11-02 | D78 |
| **B20 Mouse on the overview** | ⌘-scroll zoom, drag empty canvas to pan, a zoom pill, a lift on a dragged card | 2026-11-02 | D79 |
| **B21 Maximize** | A Maximize control on every card, a right-click menu (Open, Maximize, Close Page), and a restore that returns to the card | 2026-11-02 | D80 |

The mission's own fail triggers and their outcomes are in [DECISIONS.md](DECISIONS.md) (D1, D63, D40, D60, D66). Measured figures are only in [BENCH.md](BENCH.md).
