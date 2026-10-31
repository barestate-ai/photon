# Photon demo

A shot list that anyone with the repository, a Muse model key and a network connection can repeat, and the video made from it. Every shot maps to a built-during item in [HACKATHON.md](HACKATHON.md) (B1 to B14).

## The video

`docs/photon-demo.mp4`: 69.55 s, H.264, 1440 × 900, 371,157 bytes. It is tracked in git because it is under 5 MB.

- **What it shows, in order:** the empty canvas, the overview of six real pages, ⌘T suggestions, a typed request, the focused page with the Muse label and the trail, an approval card and Allow once, a takeover.
- **Method.** No screen recording. `scripts/capture-demo.py` launches the bundle (`.build/Photon.app`) at 1440 × 900 with test hooks and saves 172 `test.screenshot` frames of Photon's own window while it drives the app through its socket (launcher keys, a real ⌘-click on page links, the Start task row, the Allow button and a click in the page for the takeover). A `test.screenshot` frame can contain only the app's window, so nothing else on the screen can appear. `scripts/make-video.swift` assembles the frames with AVFoundation. A wait is shown shortened: a stretch of one wait keeps at most 12 frames, each held 0.5 s. The video is therefore not real time and says nothing about speed.
- **Capture log.** `.logs/demo/capture.tsv` (UTC time, seconds from the start, frame, what it shows, hold). `.logs` is not tracked. The run started 2026-10-31T15:41:39Z (22:41 local) and ended 15:44:46Z.
- **Live model.** Three segments call the real model `muse-spark-1.3` on Meta's API: the Kyoto and Tokyo comparison (shot 5) and the two runs on the permission fixture (shots 6 and 7). Nothing is canned or replayed. The three runs spent 0.051909 USD together. The pages in shots 1 to 5 are real public sites loaded over the network. Shots 6 and 7 use the harmless fixture page `fixtures/perm.html` (a "Delete draft" button that deletes nothing) served on 127.0.0.1; no logged-in or personal page appears anywhere.

## Reproduce it

```sh
make bundle
set -a; . ./.env; set +a      # MODEL_API_KEY, never printed
BARESTATE_LIVE_META=1 BARESTATE_SPEND_LOG=$PWD/.logs/spend.json \
  python3 scripts/capture-demo.py --frames /tmp/bs-demo-frames --stills docs/screenshots
swift scripts/make-video.swift build /tmp/bs-demo-frames/capture.tsv docs/photon-demo.mp4
swift scripts/make-video.swift frame docs/photon-demo.mp4 30 /tmp/check.png   # look at any second
```

The script exits non-zero if a run does not complete or the trail edge is missing. The model's wording differs between runs; the steps do not.

## Shot list

| # | Shot | How the script gets there | Built during |
|---|---|---|---|
| 1 | **The empty canvas** at first launch | Launch with a fresh data directory | B3 |
| 2 | **Overview canvas** of six real pages: en.wikipedia.org Kyoto and Tokyo, example.com, iana.org (reached by ⌘-clicking the link on example.com), www.python.org, and a python.org downloads page (⌘-click). Cards carry real captured previews; links draw the trail | Each page opens through ⌘T and Return; links open as background tabs; then ⌘⇧\\ waits until every card has a preview | B1, B4, B5 |
| 3 | **⌘T suggestions**: the Continue, Suggested and Browser rows | ⌘T from the overview | B4 |
| 4 | **A typed request**: the "Start task" and "Search the web" rows for a sentence | Type the request into the launcher | B4, B9 |
| 5 | **The focused page with context and a Muse run**: the Kyoto page in front, its neighbours around it, the copper "Muse" label while the run works, and the copper trail to the Tokyo page it read once the run completes | Click Start task, grant the Tokyo tab, release the run, click the Kyoto card to focus | B6, B7, B8, B9 |
| 6 | **An approval**: Muse is asked to click "Delete draft" and waits for Allow once; after Allow the page's status line changes and the run completes | Fixture `perm.html`, press Allow once on the card | B2, B10 |
| 7 | **A takeover**: the same request, and when the card appears the person clicks in the page; the run ends "taken over", the card leaves and nothing is deleted | `test.click` into the page as the person | B2, B10 |
| 8 | **The phone** (not in the video or the screenshots) | Settings → Enable Remote → Pair a phone, open the link on a phone or at 390 × 844; the page shows the run, the live frame and the approval, and Photon shows a "Phone connected" chip | B12 |

The video and the four screenshots cover shots 1 to 7. Shot 8 needs a phone and the Tailscale Funnel host of the person's own Mac, and showing it would put that host name in a recording, so it is not recorded. It is checked by `e2e/test_gateway.py`, `e2e/test_phone_events.py` and `e2e/test_funnel.py`, and by the outside-the-tailnet check in D60.

## Screenshots

`docs/screenshots/overview.png`, `suggestions.png`, `typed-request.png` and `focused-page.png` are frames 3, 4, 5 and 64 of the capture log of this same run (UTC 15:42:15.963, 15:42:16.116, 15:42:16.661 and 15:43:12.379). They are 1440 × 900 sRGB. The only metadata is the stamp macOS puts on every window capture (the pixel size and the text "Screenshot"); there is no name, location or date (`sips -g all`, and a read of the PNG chunks). None of them has the hash of a design export in the mission's `research/design-refs/spatial/`.
