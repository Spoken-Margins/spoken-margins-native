# Away check

One command that says whether the project can run without the owner for a stretch. The lead session runs it before any overnight or away-day hand-off, and whenever the owner says "run the away check". It reads GitHub with `gh` and changes nothing.

```zsh
python3 ops/away/away_check.py --hours 12
```

Use the hours until the owner is back. `--rate` changes how many issues one thread is expected to finish per hour (default 1). `--ref` reads AGENTS.md from another branch (default: the trunk, `main`). It also reads the owner overlay (`OWNER.md` in the private ops checkout, `<SM_OPS_HOME>/ops/OWNER.md`) when that file is on the machine, because Current focus and the standing calls live there since #1854.

## What it prints

Four numbered points, under about 25 lines:

1. **Queue.** Open `ready` issues not `in-progress`, plus open `found-by-audit` and `review-finding` issues, counted once each. It compares them with the Dial's Threads box (#589) times the hours times the rate, and says **enough** or **thin** with the shortfall. If the Dial is Off, it says nothing will start.
2. **Holds in AGENTS.md and the owner overlay.** Lines on the trunk (`main`), and in the overlay file when present, that make work wait ("until", "waits", "on hold", "only after", "no `ready`", "planning only", "stays off"…). A line counts as the owner's when it, a bullet above it, or the paragraph that leads into it has a date and either his words in quote marks or an "(owner, date)" tag. The rest are listed as suspect. It is a prompt to look, not a verdict: some suspects are mechanism ("waits for one of two build slots"). It never edits AGENTS.md.
3. **Only the owner.** Open PRs touching `scripts/lane-runner.py` or `.github/` (his merge tap), open `needs-owner` issues, and open issues whose latest comment hands him a command (a command in code marks plus words like "owner step", "please run", "could you run", "paste this").
4. **Allowance.** The latest Claude weekly % from the Mac tick on #337 and the usage breaker state, against the Dial's straight line from the week's start to its stop line at the Finish-by time. It reuses `ops/dial/dial_gate.py`'s parsers, so both read #589 and #337 the same way. It warns when the tick is more than 3 hours old.

## Why the rate is 1 issue per thread-hour

In the 7 days to 2026-10-17, 404 PRs merged into `next` with the Dial at 5 threads: about 0.5 per thread-hour, averaged over hours when threads sat idle with nothing to take. A thread with work goes faster than that average, and a queue that runs dry costs the night while spare issues cost nothing, so the default errs toward "thin".

## Tests

```zsh
python3 -m unittest discover -s ops/away
```
