# Lane poll (shadow mode)

`sm_lane_poll.py` answers one question for #1057: **if GitHub Actions were not the trigger, would a poller start the same lane jobs?** It makes the lane's start decisions from GitHub's REST API alone, prints them, and starts nothing. It never writes to GitHub.

Why: GitHub Actions is the only paid part of GitHub we use, and the lane uses it only as a trigger and a queue. `scripts/lane-runner.py` already does the work. The plan and the cutover steps are in #1057.

## What one run does

1. Reads the open PRs into `next`, the newest issue events, and `next`'s head (three `gh api` reads).
2. Starts a job, on paper, for each PR that carries `lane:queued` or `automerge` and is from this repository, when:
   - its head changed since the last run (`push`), or
   - the label was added again since the last run (`labeled`; remove and re-add is how the dispatcher retries), or
   - the PR was reopened (`reopened`), or
   - it has no earlier record (`first-seen`).
3. Adds a `compat` job for a new head whose changed paths match `shipped-build-compat.yml`'s filter, and a `merge-audit` job when `next` moved.
4. For each job, looks up whether Actions has a run of the matching workflow on the same head and prints it as `actions`.

The first run only records a baseline (`baseline` line) and starts nothing. State is in `~/SpokenMarginsOps/lane-poll/state.json`, and is written only after every read succeeded.

## Read the output

One JSON line per job, for example:

```json
{"actions": "none", "at": "2026-10-07T20:30:17Z", "head": "f58c4c5d…", "pr": 939, "reasons": ["push"], "would_start": "automerge"}
```

- `actions: none` on a line more than a few minutes old is a trigger Actions missed (#221 is one cause). That is what the poller is for.
- A `merge-audit` line with `actions: none` is expected when the lane itself merged: a push made with the workflow token starts no workflow, and the lane runs `merge_audit.py --sweep-hours 2` itself.
- `warning` lines: `event feed gap` means label events between two polls may be missed (the head check still sees pushes); `100 open PRs` means the list may be cut off.
- Exit code 2 and a message on stderr mean GitHub could not be read. The state file is left alone.

## Run it once

```zsh
python3 ~/Documents/GitHub/spoken-margins-native/ops/lane-poll/sm_lane_poll.py
```

`--state PATH` keeps the state elsewhere. `--no-compare` skips the Actions lookup. `--reset` forgets the state and records a new baseline.

## Install (not done by the PR)

Run it every minute from launchd. It needs the `gh` CLI signed in on that Mac, and it prints only when there is something to say.

```zsh
mkdir -p ~/SpokenMarginsOps/lane-poll
```

```zsh
cp ~/Documents/GitHub/spoken-margins-native/ops/lane-poll/com.spokenmargins.lane-poll-shadow.plist ~/Library/LaunchAgents/
```

```zsh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.lane-poll-shadow.plist
```

Turn it off:

```zsh
launchctl bootout gui/$(id -u)/com.spokenmargins.lane-poll-shadow
```

```zsh
rm ~/Library/LaunchAgents/com.spokenmargins.lane-poll-shadow.plist
```

## Not covered yet

- Running anything: this is the decision half only.
- `lane-check/**` bases (lane.yml also starts for those).
- Draft status and GitHub's merge-conflict rule: Actions skips a PR that conflicts with `next`; the poller still lists it.
- The API budget: three reads a minute, plus one read per new head. GitHub allows 5,000 an hour.

## Tests

```zsh
python3 -m unittest discover -s ~/Documents/GitHub/spoken-margins-native/ops/lane-poll -t ~/Documents/GitHub/spoken-margins-native/ops/lane-poll
```

`scripts/verify-tests.py --plan fast` runs them too, as the `ops-lane-poll` step. Three tests read the workflow files and fail if `shipped-build-compat.yml`, `lane.yml` or `merge-audit.yml` change what they trigger on; they skip themselves once those files are gone.
