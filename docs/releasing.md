# Releasing: the main T3 gate (#4575)

Owner's call, 2026-11-18 (#2048): pull requests no longer wait for a simulator run (T3). Instead `main` is tested on a schedule, and **no build is made for the owner's phone or App Store Connect from a commit whose T3 on main did not pass.**

## The rule

The scheduled main T3 (#4573) sets a GitHub commit status on the commit it tested: context `main-t3`, state `success`, `failure` or `error`, and a link to the run. A commit may be built only when its newest `main-t3` status is `success`. Missing, `pending`, `failure`, `error`, or GitHub unreachable, refuses. The refusal names the commit, the state it found and the run link.

`scripts/main_t3_gate.py` holds the rule. It is called by:

1. `scripts/phone-build`, the rolling phone build. Without `--commit` it builds the newest commit on `main` whose `main-t3` is green, not the tip (the tip rarely has a result yet). A named commit, or the GitHub-hosted build's commit, without a green run is refused.
2. `scripts/xcodebuild-lane ... archive`, the first step of an upload. It checks the worktree's `HEAD` and refuses when tracked files have uncommitted changes, since the archive would not be that commit. Archive through the wrapper, not plain `xcodebuild`.

Check any commit by hand:

```zsh
scripts/main_t3_gate.py <commit>
```

It exits 0 when allowed and 1 when refused.

## Getting a green run on a commit

1. Dispatch the main T3 workflow on it: `gh workflow run main-t3.yml --ref main -f sha=<commit>` (the workflow comes with #4573).
2. Or run the Test Desk's local T3 on that commit, then post its result as the status, linking the lane report:

```zsh
gh api repos/Spoken-Margins/spoken-margins-native/statuses/<commit> -f state=success -f context=main-t3 -f target_url=<report link>
```

Post `failure` for a failed run. Only post `success` for a T3 that actually ran and passed on that exact commit.

## The owner's override

The owner, and only the owner, may build anyway:

```zsh
scripts/phone-build --commit <commit> --allow-without-main-t3 "<reason>"
```

`scripts/xcodebuild-lane` and `scripts/main_t3_gate.py` take the same flag. A reason is required. It is printed and appended as one JSON line to `~/Library/Logs/SpokenMargins/main-t3-overrides.jsonl` (set `SM_MAIN_T3_OVERRIDE_LOG` to move it). If overrides become routine, the gate is costing more than it catches, and that log is the evidence.

Scripted journeys still run at the cut as before (`docs/workstreams/test-lane.md`). This gate does not replace them.
