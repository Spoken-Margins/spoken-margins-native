# Flow map

`flow-map.json` is a map of how a listener moves around the app: every screen, every control that leads somewhere else, and a set of everyday jobs with their tap counts. It is the starting point for the navigation redesign: proposals are judged by how they change the jobs' tap counts before anyone draws a screen.

## What's in it

- **screens**: tab roots, full screens, sheets, and the system surfaces the app hands off to (Files picker, share sheet, Safari, the Settings app).
- **edges**: one arrow per control. Each arrow names the control in the listener's words and cites the file, line and an exact piece of that line (`anchor`).
- **jobs**: everyday tasks, each with a start, optional waypoints and a target. Tap counts are computed from the edges, not written by hand.
- **assumptions** and **omitted**: what the map leaves out on purpose (back moves, confirmation dialogs, in-place menus, code no screen shows).

## Keeping it honest

```bash
python3 scripts/flow-map-check.py
```

The check fails when an arrow's anchor is gone from its file. `--fix-lines` rewrites line numbers for anchors that only moved. It also lists navigation calls in the code that no arrow covers, so a new sheet or screen shows up as work to map. It isn't a lane step; run it when you change navigation, and update the map in the same PR.

The map shows what the code does. It has not been checked against the running app; a simulator walk of the jobs is the next level of evidence.

## Viewer

The interactive viewer (map, jobs, sandbox for proposed changes) is a claude.ai artifact built from this file. Proposals saved there are read back from the artifact's database.

## Proposals

Structure proposals built on this map live in [../proposals/](../proposals/README.md), each as a JSON file of edits in this schema plus a note. `Design/proposals/compute-taps.py` applies a proposal and recomputes every job.
