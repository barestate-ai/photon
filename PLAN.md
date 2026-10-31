# Plan

Photon, by Barestate, is a native macOS browser (Swift/AppKit + CEF) where Muse can act in the person's real session, from the Mac or a phone, with instant takeover, approvals, and a verified record of every action. Decisions are in `DECISIONS.md`.

## Default UI

A borderless window with no toolbar, tab strip, address bar or sidebar. The pages the person has open sit on one spatial canvas (the overview); one page at a time can be focused, with its neighbours and trails visible around it. A single Command-T launcher is the way in: URLs, web search, switching to an open page, browser commands, and requests for Muse, with local suggestions. Muse's work shows on the page it works on (a label and a copper trail), not in a panel. Design: Figma page "22 · Browser · Spatial Daylight" (D22, D65).

## Milestones
1. **Engine and core:** SwiftPM + CEF build and bundling, G1–G3, `CDPTransport`, observe/extract, SQLite journal, control epochs. First BENCH.md.
2. **Photon frontend:** identity and borderless shell with the command button; the launcher's Continue/Suggested/Browser sections, browser commands, history scope and result states; the page graph and the overview canvas with bounded preview captures; the focused page in context; motion; accessibility; frontend speed budgets.
3. **Agent and Muse:** act ladder, Atom client, `computer_call` executor, permissions and Allow-once, verified outcomes, launcher task submission with truthful status on the working tab, Stop, approvals, connection-error recovery, MCP and `barestate-mcp`.
4. **Remote and ship:** gateway, phone page, Funnel, the same run model for phone and Mac, final BENCH.md, DEMO.md, README, HACKATHON.md, screenshots and demo video, release zip.

Each milestone passes `make check` and `make e2e`, and the frontend is verified on the running app with screenshots and a short recording.

## Replaced requirements
- The original "Ask Muse panel" is replaced by launcher task submission (D7).
- The first frontend (horizontal and vertical tabs, a toolbar, an address bar, a sidebar) is replaced by the Photon canvas shell (D22, D65).
