# Flow map

`flow-map.json` is a map of how people move around Spoken Margins: every screen, every control that leads somewhere else, and a set of everyday jobs with their tap counts. It covers the app, and for the sharing loop it follows a Margin out of the app and back: the message a link arrives in, the browser listener, the link's server page, the join page and TestFlight. It started as the ground for the navigation redesign (proposals are judged by how they change the jobs' tap counts before anyone draws a screen); since #5280 it is also where anyone changing a sharing screen looks up what leads to it, what it leads to, and the owner's rulings on it.

## What's in it

- **screens**: tab roots, full screens, sheets, and the surfaces outside the app. Each has a `surface`: `app`, `system` (iOS or the browser's own sheets), `messages`, `web` (the browser listener in `Web/`), `site` (the link's server page and `Site/join/`) or `testflight`. Screens in the sharing loop have `"sharing": true` and a `capture` (below), and may name `rulings`.
- **edges**: one arrow per control. Each names the control in the person's words and cites the file, line and an exact piece of that line (`anchor`). App files are relative to `App/SpokenMarginsApp/Sources/SpokenMarginsApp/`; others are repository paths (`Web/…`, `Site/…`, `Packages/…`, `research/…`). A tap on Apple's own surfaces (Messages, TestFlight, the share sheet) has no file. Arrows in the sharing loop have `"sharing": true`.
- **retired_edges**: arrows whose control left the app, with the commit that removed it, so proposals that removed them still check.
- **jobs**: everyday tasks, each with a start, optional waypoints and a target. Tap counts are computed from the edges, not written by hand. A two-person job (ids `s01` to `s06`: send by link, send as a file, a friend's first listen in a browser or in the app, a reply from the browser or the app and the sender hearing it) has `legs`: each leg names its `person`, and a leg that changes person says in `handoff` what passes between them. Taps are counted per person.
- **rulings**: the owner's rulings on sharing, each with its date, a summary, what it `protects` (`removal`, `rename` or `behaviour`) and the line of `docs/decisions.md` it quotes (`anchor`). Screens and arrows name the rulings that govern them, so "may this control be removed or renamed?" is answered on the map. Read the ruling itself before acting on the summary.
- **assumptions** and **omitted**: what the map leaves out on purpose (back moves, confirmation dialogs, in-place menus, code no screen shows). An arrow whose `control_kind` is `auto` (a page that moves on by itself) costs 0 taps.

## Captures

Each sharing screen's `capture` says whether the real thing was seen and where:

- `pass`: the run reached the screen; `file` is the picture in `captures/`, `commit` the commit it was taken at, `run` which run.
- `broken`: the step failed in that run; `seen` says what was on screen instead and `commit` the commit it failed at. A failed step usually leaves no picture (each capture follows the step's check), so `file` is optional. The map does not wait for a full pass.
- `pending`: no capture yet; `why` says which run takes it, or that it needs a person on a device (Messages, TestFlight).

Pictures come only from test simulators and fixtures, never a real Library. Two runs make them:

1. **The browser listener and the site**: a headless browser run over the fixture links and local stub servers. Run `npm ci` in `Web/` once, then:

   ```bash
   cd Web && npm run capture:flow-map
   cd .. && python3 scripts/flow-map-captures.py --from artifacts/flow-map-capture/web --commit "$(git rev-parse --short=8 HEAD)" --run "Headless browser run (WebKit, 390x844, fixtures and local stub servers): npm run capture:flow-map in Web/"
   ```

2. **The app**: `J12SharingLoopJourneyUITests` attaches a `flowmap-<screen id>` screenshot at each sharing screen it confirms. It runs with the scripted journeys when a phone build is cut; then point the same script at that cut's attachments, `artifacts/integration-run/<id>-<sha7>-journeys/journeys/xcode-tests-probation-attachments/`, with that commit and `--run "J12 scripted journey, test simulator"`. A step that failed goes in as `--broken '<screen id>=<what was seen>'`.

`captures/` keeps one small JPEG (390 px wide) per screen, about 50 KB each: only what the viewer shows. Full-size shots, variants and recordings stay in `artifacts/`.

## Keeping it honest

```bash
python3 scripts/flow-map-check.py
```

The check fails when an arrow's anchor is gone from its file, when a ruling's quote is gone from `docs/decisions.md`, or when a sharing screen lacks a surface or a capture status. A sharing anchor whose text repeats in its file (the same "Report this link" in two footers) must be cited once for each line it is on: otherwise deleting one control would send its arrow to the other as "moved", and the check would pass. So when a sharing anchor matches more lines than the map cites, or fewer, the check fails; map the other copy too, or pick anchor text that is on one line only. `--fix-lines` rewrites line numbers for anchors that only moved. It also lists navigation calls in the app that no arrow covers, so a new sheet or screen shows up as work to map.

```bash
python3 scripts/flow-map-check.py --touched Web/src/app/screens/Arrival.tsx App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackScreen.swift
```

prints the sharing screens those files touch, each one's ways in and out, the jobs through them and the rulings on them.

On every PR that runs the portable fast plan, its `flow-map` step runs `scripts/flow-map-check.py --pr`: the anchor check over the sharing loop's arrows and screens (a sharing control removed, renamed or re-routed fails it), then the lookup for the PR's changed files. When it fails, update the map in the same PR, and read the rulings it names before removing or renaming a control.

The tap counts check with `python3 Design/proposals/compute-taps.py Design/flow-map/flow-map.json --check`.

## Viewer

`viewer.html` shows the sharing loop end to end: each two-person job person by person, with every screen's capture, its status (a shape and a word, never colour alone), the taps and the hand-offs; every sharing screen with its ways in and out; the rulings; and all jobs with their taps. Serve this folder and open it:

```bash
python3 -m http.server -d Design/flow-map 8765
```

then `http://localhost:8765/viewer.html`. The older interactive viewer for the whole app (map, jobs, sandbox for proposals) is a claude.ai artifact built from this file; proposals saved there are read back from the artifact's database.

## Proposals

Structure proposals built on this map live in [../proposals/](../proposals/README.md), each as a JSON file of edits in this schema plus a note. `Design/proposals/compute-taps.py` applies a proposal and recomputes every job.
