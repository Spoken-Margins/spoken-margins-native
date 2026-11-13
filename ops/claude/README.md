# Claude Mac worker (#1599)

A Mac-side worker that takes Mac-only `ready` issues and stalled PRs with **headless Claude** (`claude -p`), one fresh session per job, so nobody taps Allow for each new Mac thread and no single session runs out of context mid-issue. It replaced the Codex worker, which was retired by #1195 and deleted by #1853.

Nothing here is installed by default. Loading the job and the first real run need the owner's Mac: see "Mac steps".

## What it does

launchd runs `sm_claude_worker.py` every 10 minutes (a tick). A tick reads, and starts at most one detached child:

1. **The Dial** (#589), through `ops/dial/dial_gate.py`'s own parser, so there is one reading of it. Mode Off, or no Threads box ticked, holds.
2. **The usage breaker and usage** from the Mac tick on #337. `HALT (usage breaker: Claude)` holds in every mode. Paced also holds at the Stop line minus 3, ahead of the trend line by more than 10 points, or with no usage report under 3 hours old. These are the Dial gate's own rules.
3. **Free disk** (holds under 20 GiB, the Mac finisher's pause line) and **memory pressure** (holds unless normal).
4. **Claude slots.** The Dial's Threads box is Claude's slot count. The worker counts every active Claude thread from the claim and stop notes (project threads and its own), using the Dial gate's `parse_threads`. Its notes use the title `Claude Mac worker N`, which the gate counts as Claude (only `Codex worker N` is Codex, #1587). So a worker run takes one of the Dial's slots, and the worker never starts when the project already fills them. A child that has started but not yet posted its claim note counts too. The worker also keeps its own cap, `SM_CLAUDE_WORKER_MAX` (default 1: the Mac has two build slots and one simulator).

### The hourly pass: area labels (#3636)

Each tick also runs `scripts/area_labels.py --apply` at most once an hour, whatever the Dial says (it uses no model tokens). It adds `needs-area` to any open issue without exactly one area label and takes it off once fixed; it posts no comment. It replaced the project-board sync (`scripts/sm_project_sync.py`, #1621) when the owner retired the board on 2026-11-07. The hourly stamp is `board-sync.json` in the worker's folder, written before the run, so a hang can't repeat it every tick. The hourly pass records its time and any unknowns in the lane's step ledger (`scripts/lane_ledger.py`, step `area-labels`) when the lane's state folder exists, so three runs in a row with unknowns raise its fault alarm in the log. The same hourly pass then runs `scripts/pr_issue_link.py --apply` (#2167), which labels `needs-issue-link` and comments once on an open PR whose body has no `Closes #N` or `Part of #N`, and takes the label off when the body is fixed; it never blocks a merge. Then it runs `scripts/ready_owner_only.py --apply` (#3666): an open `ready` issue whose newest comment from a trusted author (`scripts/comment_trust.py`) says "owner only" or names only the owner's check as left loses `ready`, gains `status: needs-human-validation` and gets one comment; a stranger's comment is ignored, and the guard's own comment stops a second pass, so an owner who puts `ready` back is not overruled. Last it runs `scripts/owner_card_guard.py --apply` (#3898): an open issue with `needs-owner` and no `**Decision for Cole**` or `**Step for Cole**` card from a trusted author gets one reminder comment; a trusted card on an issue without `needs-owner` gets the label; `scripts/sm_owner_queue.py` prints the whole queue with each card. A missing script, a failure or a timeout (10 minutes) is logged and holds nothing.

### Job order

1. **A stalled PR** into `main` on a branch in this repo, not a draft: `needs-mac`, a lane FAIL on its head that names a code failure (not a runner fault), or audit findings on its head. It waits an hour first so the Mac finisher goes first. PRs touching lane machinery qualify only for audit findings. At most two rounds per PR in 24 hours and four in a week; another finisher's claim ("Finisher … taking this.") holds it for two hours. The child claims it with `Finisher Claude taking this.` and a `Claimed by project thread "Claude Mac worker N"` note on the PR (the Dial gate reads PR comments too, so a PR run counts as a Claude slot like an issue run), removes `automerge` so nothing merges half done, works, and only an agent push plus `automerge` counts as done. Otherwise it restores the labels it found (without `automerge`) and posts why.
2. **A `ready` issue labelled `where:mac`** (cloud threads take the rest), without `in-progress`, `needs-owner`, `deferred`, `blocked`, `status: needs-human-validation` or `needs-design`, and not claimed by a thread that is still active. A pending hand-off first, then `priority`, regressions and reverts, `found-on-phone`, the lowest open release milestone by version (`0.2`, then `0.2.1`, `0.3`; Showcase counts as `0.2` until renamed), or the order `SM_CLAUDE_WORKER_FOCUS_MILESTONE` gives as a comma-separated list, then oldest.

3. **A design pass (#3866)**, only when there is no PR or Mac issue to take. `scripts/design_queue.py` picks one batch of `needs-design` issues: the batches in `ops/claude/design-queue.json` first, in file order (the order the director set on #4187), then the rest by `priority` and age, joined by the waiting issues that share a parent (`Part of #N`) with the first or that it names. The file's `hold` list keeps out issues someone is designing by hand. The Dial, the usage breaker, disk and memory hold it like any run.

### A design pass

The child claims the batch's first issue (the anchor) with a `Claimed by project thread "Claude Mac worker N"` note, so the Dial counts it, but changes no label. It makes `wt-N` detached at fresh `origin/main` (no branch, no setup), copies the newest screen tour on the Mac (`artifacts/integration-run/*/tour/screens`, about 17 MB) into the run's `out/captures`, and starts the same headless Opus session with [design-pass-brief.md](design-pass-brief.md) filled in: the batch, the captures and the last pass's stop note. The session reads, writes one design for the batch, has a fresh Opus gap finder and a Sonnet builder read review it, then posts a **Design** comment on each issue and swaps `needs-design` for `ready` itself. It writes no code and opens no PR.

When it ends, the wrapper re-reads each issue and posts one stop note on the anchor: `Thread "Claude Mac worker N" stopping: design pass, K of M designed`, with the designed and left issues and the session's `handoff.md`. An issue counts as designed when a trusted **Design** comment is on it and `needs-design` is off, or still on beside `needs-owner` for a decision card. A run that never reached the model posts `design pass not run … (fault)` instead. Both notes name the whole batch (`Batch: #1, #2.`), and the picker reads them for every issue they name, so a batch is paced as one: its issues wait 30 minutes after any note; two runs in a week that designed nothing, or three faults in a day, pass them over as `stuck` (a stuck issue may still ride in a batch another issue anchors, behind its anchor), and `scripts/design_queue.py` lists them. A failing batch therefore stops after two runs, instead of re-anchoring on each member in turn. An issue with `needs-owner` (a decision card) is held until the owner answers. Design notes never count toward job 2's fault limits. The worktree and the captures copy are removed; the run folder keeps the prompt and transcript, and the ledger row has job `design`.

`scripts/sm_sweep.py` rule 14 reports when `needs-design` issues have waited over three days and no design pass has posted a stop note in 24 hours, so a stopped pass shows on the next coordinator wake.

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
