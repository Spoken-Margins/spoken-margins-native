# Integration script

`sm_integration_run.py` tests each new tip of `next` with `--plan app` from launchd, with no model session and no owner click (#1178). It replaces the scheduled "SM integration run" task once it has posted a real report.

## What a tick does

launchd starts it every 10 minutes. It stops at the first reason to wait:

1. The tip already has a result here, or any runner's `Lane report integration-<sha7>` is on #184.
2. Less than 30 minutes since its last start.
3. Memory pressure isn't normal.
4. Free disk is under 10 GB plus 4 GB per running `xcodebuild`.
5. The Mac-wide simulator slot is busy (the lane's own lock, taken without waiting).

Otherwise it tests the tip in its own detached worktree (`~/SpokenMarginsOps/integration-run/worktree`):

- It runs `--plan app`, then re-runs any failing tests twice on the same build. A test that passes both re-runs is reported as `flaky:`, and the verdict is PASS.
- It runs the scripted journeys, which only change the verdict once one is on `gating`.
- It frees the simulator, then posts one `Lane report integration-<sha7>` on #184 in test-lane.md's format, with `run by: integration script`. `scripts/phone-build` reads it unchanged.

On a confirmed FAIL it also:

- lists the merges since the last PASS as suspects;
- asks Claude to group the failures and name a likely culprit;
- comments on an open issue that names the test, or files a new one labelled `ready,priority,bug,regression`.

The Claude call is `claude -p` with only Read, Grep and Glob, `--permission-mode dontAsk`, structured JSON output and a $10 cap. Anything else is refused at once rather than waiting for a click. A missing token or a bad answer gives template text instead. A tip is tested at most once: a run cut off part-way is closed as INCONCLUSIVE, not repeated.

Not yet: finding the culprit by re-running the failing test at each merge, and opening the revert PR. Until that lands, a FAIL becomes a `ready` issue for a thread.

State and log: `~/SpokenMarginsOps/integration-run/`. Evidence: `artifacts/integration-run/` in the ops checkout; the newest 20 runs are kept, and a PASS run's `.xcresult` bundles are deleted.

```zsh
/usr/bin/python3 ops/testdesk/sm_integration_run.py --dry-run
```

prints today's decision and changes nothing.

## Claude token

The diagnosis reads a long-lived token from the login Keychain (service `claude-code-oauth`), made once with `claude setup-token`. It is passed only in the child's environment, never on a command line or in a file.

## Install (owner's call)

The job runs from the `~/SpokenMarginsOps/repo` checkout, which the phone-build job keeps on `next`. After this merges and that checkout has the folder:

```zsh
mkdir -p ~/SpokenMarginsOps/integration-run
```

```zsh
cp ~/SpokenMarginsOps/repo/ops/testdesk/com.spokenmargins.integration-run.plist ~/Library/LaunchAgents/
```

```zsh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.integration-run.plist
```

The first tick runs at load. Watch `~/SpokenMarginsOps/integration-run/log.txt` and #184. Once it has posted a report, switch off the "SM integration run" scheduled task. To stop the job:

```zsh
launchctl bootout gui/$(id -u)/com.spokenmargins.integration-run
```
