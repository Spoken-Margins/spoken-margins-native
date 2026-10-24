# Claude Mac worker (#1599)

A Mac-side worker that takes Mac-only `ready` issues and stalled PRs with **headless Claude** (`claude -p`), one fresh session per job, so nobody taps Allow for each new Mac thread and no single session runs out of context mid-issue. It replaced the Codex worker, which was retired by #1195 and deleted by #1853.

Nothing here is installed by default. Loading the job and the first real run need the owner's Mac: see "Mac steps".

## What it does

launchd runs `sm_claude_worker.py` every 10 minutes (a tick). A tick reads, and starts at most one detached child:

1. **The Dial** (#589), through `ops/dial/dial_gate.py`'s own parser, so there is one reading of it. Mode Off, or no Threads box ticked, holds.
2. **The usage breaker and usage** from the Mac tick on #337. `HALT (usage breaker: Claude)` holds in every mode. Paced also holds at the Stop line minus 3, ahead of the trend line by more than 10 points, or with no usage report under 3 hours old. These are the Dial gate's own rules.
3. **Free disk** (holds under 20 GiB, the Mac finisher's pause line) and **memory pressure** (holds unless normal).
4. **Claude slots.** The Dial's Threads box is Claude's slot count. The worker counts every active Claude thread from the claim and stop notes (project threads and its own), using the Dial gate's `parse_threads`. Its notes use the title `Claude Mac worker N`, which the gate counts as Claude (only `Codex worker N` is Codex, #1587). So a worker run takes one of the Dial's slots, and the worker never starts when the project already fills them. A child that has started but not yet posted its claim note counts too. The worker also keeps its own cap, `SM_CLAUDE_WORKER_MAX` (default 1: the Mac has two build slots and one simulator).

### The project board (#1621)

Each tick also runs `scripts/sm_project_sync.py --apply` at most once an hour, whatever the Dial says (it uses no model tokens), and a child syncs its issue's card right after its claim and after its stop note. The hourly stamp is `board-sync.json` in the worker's folder, written before the run, so a hang can't repeat it every tick. The hourly pass records its time and any unknowns in the lane's step ledger (`scripts/lane_ledger.py`, step `project-sync`) when the lane's state folder exists, so three runs in a row with unknowns raise its fault alarm in the log. A missing script, a failure or a timeout (10 minutes) is logged and holds nothing. The cloud dispatch can't do this: the user project's API answers its token with 403, and the Mac's `gh` token has the `project` scope.

### Job order

1. **A stalled PR** into `main` on a branch in this repo, not a draft: `needs-mac`, a lane FAIL on its head that names a code failure (not a runner fault), or audit findings on its head. It waits an hour first so the Mac finisher goes first. PRs touching lane machinery qualify only for audit findings. At most two rounds per PR in 24 hours and four in a week; another finisher's claim ("Finisher … taking this.") holds it for two hours. The child claims it with `Finisher Claude taking this.` and a `Claimed by project thread "Claude Mac worker N"` note on the PR (the Dial gate reads PR comments too, so a PR run counts as a Claude slot like an issue run), removes `automerge` so nothing merges half done, works, and only an agent push plus `automerge` counts as done. Otherwise it restores the labels it found (without `automerge`) and posts why.
2. **A `ready` issue labelled `where:mac`** (cloud threads take the rest), without `in-progress`, `needs-owner`, `deferred`, `blocked` or `status: needs-human-validation`, and not claimed by a thread that is still active. A pending hand-off first, then `priority`, regressions and reverts, `found-on-phone`, the focus milestone (`SM_CLAUDE_WORKER_FOCUS_MILESTONE`, default `Showcase`; a comma-separated list ranks in the order given), then oldest.

### One run

The child claims the issue (`in-progress` on, `ready` off, `Claimed by project thread "Claude Mac worker N"`), makes the worktree `wt-N` on `ws/<issue>-<slug>` from fresh `origin/main` (or from the hand-off branch), runs `scripts/setup-worktree.sh`, and starts Claude in it with the prompt on stdin: AGENTS.md first, the issue, the run rules, and the "Keep bulk out of your context" rule with heavy reading sent to helper agents. Claude is a full agent: it builds through `scripts/xcodebuild-lane`, runs the host tests, has a fresh-context helper review the diff, opens the PR, labels it `automerge` and asks for `/lane T3`. The wrapper does not open PRs for it.

Caps per run: 90 minutes wall time (under the Dial's two-hour "quiet" line), 250 turns, a budget of 25 USD. Environment overrides: `SM_CLAUDE_WORKER_TIMEOUT_MIN`, `_MAX_TURNS` (empty turns the cap off), `_BUDGET_USD`, `_MODEL` (default `opus`), `_EFFORT` (default `high`).

### When a run ends

- **A PR on the branch carries `automerge`.** Stop note `Thread "Claude Mac worker N" stopping: PR #X armed · done`. `in-progress` stays until the dispatcher clears it on merge, as for any thread.
- **No armed PR (the hand-off).** The wrapper commits loose work as a `WIP:` commit, pushes the branch, and posts ONE comment on the issue: the stop note (first line, in the format the Dial gate reads) and the hand-off, `Hand-off: run N of 3`, `Branch:`, `Head:`, `Commits ahead of main:`, `Progress: yes|none`, and Claude's own `handoff.md` (what is done, what is next, what it learned). The issue goes back to `ready`. The next run, a fresh session, starts from that branch and that comment. If the branch is gone it starts from the trunk (`main`) and says so in the log.
- **Run 3 without an armed PR.** The branch becomes a PR (or the existing one is used) labelled `needs-mac`, without `automerge`, with a `Handing to the Mac finisher:` comment, and the issue keeps `in-progress`. The worker never starts a fourth run.
- **Two runs in a row with no commit** (the waste signal in #1599): the issue is parked as `blocked` with a comment. Its ledger rows carry the outcome `no commit`.
- **`NEEDS OWNER:` first line in `handoff.md`.** The issue gets `needs-owner` and the question in the stop note.
- **A fault** (no token, CLI missing, no JSON result, and nothing on the branch): the issue goes back to `ready` with a note marked `(fault)`, no run is used, and the issue waits 30 minutes before the next try. Three faults in a row (a hand-off or an armed PR ends the streak) park it as `blocked`.
- **An error in the wrapper after Claude ran** (a `gh` blip, say): the wrapper commits what Claude left and pushes the branch, or moves the worktree to `kept/`, before it cleans up, and the stop note says which.
- **A hand-off whose branch is not `ws/<this issue>-…`** is ignored, so a comment can never make the worker delete or push the trunk or someone else's branch.
- **If the agent armed a PR and Claude then exited badly**, the PR still counts as armed and the wrapper pushes nothing to it.
- **A push failure** keeps the worktree under `claude-worker/kept/` and says where.

Hand-offs older than 48 hours do not count, so an issue the owner re-readies later starts at run 1.

## Files and logs

All under `~/SpokenMarginsOps/claude-worker/`: `log.txt`, `slot-N.lock`, `slot-N.out`, `wt-N/` (removed after every run), `kept/`, and `runs/<issue>-<time>/` with `prompt.md`, `transcript.json` (Claude's JSON result, which the usage ledger reads) and `out/handoff.md`. Each run adds one row to `~/SpokenMarginsOps/ledger/usage.jsonl` (job `issue` or `finisher`, the model, tokens, the outcome and its signature), so `ops/ledger/report.py` counts it with the audit's rows. Each session is also a normal Claude Code session on the Mac (`claude --resume` can open it).

## Safety

Claude runs with `--permission-mode dontAsk`, tools `Bash,Read,Edit,Write,Grep,Glob,Agent`, no MCP servers, project settings only plus `--settings ops/claude/worker-settings.json`, which registers the lane guard (blocks raw `xcodebuild`), the 250k/300k token-limit hook and the toolchain guard from `~/.claude/hooks/` (the repo has no `.claude/settings.json`, so without that file a worker session loads no hooks; install them with `scripts/install-lane-guard.py`), and a deny list on force pushes, pushes to `main` or `next`, `xcodebuild`, `simctl boot`, `sudo` and `rm -rf` of `/` or `~`. The deny list is best effort; the prompt's rules and the hooks do the rest. The token comes from the Keychain item the audit job uses (`claude-code-oauth`), `ANTHROPIC_API_KEY` is removed from its environment, and `CODEX_SANDBOX` never applies. The worker never touches `main`, releases or the owner's Library and recordings, and never pushes to a PR that carries `automerge`.

## Mac steps (Cole, or the Mac finisher if its permissions allow `launchctl`)

I could not do these from the cloud, so they are written out and untried. The code was tested against a fake `claude` binary, not the real CLI.

1. Pull `main` in the ops checkout once this merges: `git -C ~/SpokenMarginsOps/repo fetch origin && git -C ~/SpokenMarginsOps/repo switch --detach origin/main`.
2. Check the machine can run it: `/usr/bin/python3 ~/SpokenMarginsOps/repo/ops/claude/sm_claude_worker.py --check`. It names a missing CLI, a missing Keychain token, a `claude` that lacks a flag the worker uses (it only notes `--max-turns`, which may be hidden from `--help`; if the first run faults on it, set `SM_CLAUDE_WORKER_MAX_TURNS=` empty in the plist), and a `gh` that is not signed in. Fix what it names before going on.
3. See what it would do: `/usr/bin/python3 ~/SpokenMarginsOps/repo/ops/claude/sm_claude_worker.py --dry-run`. It prints the Dial, the slots, and the job it would take. It changes nothing.
4. Load it:

```zsh
mkdir -p ~/SpokenMarginsOps/claude-worker
/usr/bin/python3 ~/SpokenMarginsOps/repo/ops/install-launchd.py --install claude-worker
```

5. The Codex worker is gone (unloaded 2026-10-17, files deleted by #1853). If `~/Library/LaunchAgents/com.spokenmargins.codex-worker.plist` is still there, delete it.

6. Watch the first run: `tail -f ~/SpokenMarginsOps/claude-worker/log.txt`, then the claim note and the stop note on the issue it took. Look for: the claim note appearing, the branch pushed, a stop note in the Dial gate's format, and the Dial's status comment on #589 counting the run among the Claude threads. If the first run is a fault, its note says why (the usual causes are the Keychain prompt on first use, which needs one click on the Mac, and a flag the installed `claude` does not know).

To stop it: untick Threads to a number the project already fills, or Off, on the Dial (running children finish); or `launchctl bootout gui/$(id -u)/com.spokenmargins.claude-worker`.

## Known limits

- A child killed mid-run (a reboot) leaves its issue `in-progress` with no stop note. The next tick clears the dead lock and logs the issue number; the coordinator releases the claim after 6 quiet hours. The branch, if pushed, is still on GitHub.
- The wrapper does not run the fast plan itself (the Codex worker had to because its sandbox could not run everything). Claude runs it as part of the job; the lane runs host tests again before merging.
- The deny list matches command prefixes, so a determined command can slip past it. The hooks and the prompt are the real guard.

## Tests

```zsh
/usr/bin/python3 -m unittest discover -s ops/claude
```

They run the worker against a fake `claude` script (the real subprocess path, prompt on stdin, JSON result) and real git in a temp repo, with only `gh` faked. They cover slot counting through the Dial gate's parser, the hold rules, job order, the hand-off and resume path (the resume test fails if the hand-off branch is ignored), the 3-run limit, the two-empty-runs park, faults, caps, `NEEDS OWNER`, PR finishing, and the ledger row.
