# Codex roles, and what replaced them (#1195)

After 2026-10-15 Claude is the only model on this project. Each job Codex did has an owner that does not need Codex:

| Codex role | After 2026-10-15 | Where |
|---|---|---|
| Audit of risky and lane PRs (the merge gate) | **Headless Claude**, read-only, same script and launchd job, posts `**Claude audit on `<sha7>`**` | "Audit" below |
| Taking `ready` issues (Codex worker) | The owner's Claude Code project threads, one per `ready` issue (AGENTS.md), and for `where:mac` issues and stalled PRs the **Claude Mac worker** (headless Claude, #1599). **Deleted.** | "Deleted: Codex worker" below; `ops/claude/README.md` |
| Finishing stalled PRs (lane FAIL on the head, `needs-mac`, audit findings) | The Mac finisher for Mac-side fixes, and the project's hourly dispatch, which gives a conflict, a failing cloud test or confirmed audit findings to a free thread. **Retired on the Codex side.** | project instructions; `.claude/skills/lane-request/SKILL.md` |
| Test Desk (`--plan app` plus scripted journeys on each new tip of `next`) | The integration script, `ops/testdesk/` (#1178), with culprit and revert in #1180. **Retired** (the launchd job was never loaded; its script and plist are deleted). | `ops/testdesk/README.md` |
| Journey desk (a Codex app automation with computer use, #693) | Agent-driven journeys stay with the standing Claude Test Desk. **Retired** (owner, 2026-10-09). | `.claude/skills/journey/SKILL.md` |

`com.spokenmargins.codex-audit` is the audit job, which now calls Claude; it keeps its name so the loaded job, its log and its lock carry on. See "After 2026-10-15" at the end.

# Deleted: Codex worker

The Mac-side worker that finished PRs and took `ready` issues with Codex (`gpt-6.1-sol`), paced by the Dial (#589), is gone: retired by #1195, unloaded by the owner on 2026-10-17, and its script, plist and tests deleted by #1853. The Claude Mac worker (`ops/claude/README.md`) does that job now.

## Local token ledger

Audit batches (headless Claude), and the retired worker's issue runs and finisher
rounds (`codex exec --json`), each append one row to
`~/SpokenMarginsOps/ledger/usage.jsonl`. A batch has multiple `targets` (PR, linked
issues, head/base SHA, trigger, outcome and posted comment URL) in a single row;
its tokens are never duplicated per PR. Outcomes and post URLs
also appear at the run level. Counts come from Codex's `turn.completed.usage`
events, or from the `usage` of the `result` object that `claude -p --output-format json`
ends with (input is its three input counts added; cached input is the cache read);
cached input is included in input. Missing fields are null with a reason,
and a failed later turn marks completed-turn totals as incomplete.

The audit keeps its `.jsonl` transcript (Claude's JSON result) beside the answer in
`artifacts/ops/codex-audit-outputs/`, including failures. Workers keep
`transcript.jsonl` in their run folder. These files and the ledger stay local. A write failure is logged
and does not stop the job or change its posting behavior.

A locked, atomically replaced journal in `ledger/pending/` is saved before each
model invocation. A normal/failed/timed-out invocation finalizes its row. If the
wrapper itself is killed, the next wrapper tick, model invocation or report recovers its row
once, with the preserved usage and an interrupted outcome. Its wall time is null
if the model hadn't finished. A run whose wrapper still holds the lock is left
alone. Successful posts checkpoint their URLs before later work.

Print a chosen week's summary locally (week start inclusive, seven days,
America/Chicago by default):

```zsh
/usr/bin/python3 ops/ledger/report.py --week 2026-10-05
```

The report reads the ledger and GitHub. It shows observed token subtotals by job,
PR-work tokens per PR merged that week, audit tokens per confirmed fix claim, and
diagnosis tokens per new Test Desk bug. Incomplete usage or a zero denominator
gives a null ratio. Batches count once. Fixes and new bugs count once even when
several runs mention them. GitHub errors abort the report instead of silently
producing an incomplete denominator.

A finding counts as a fix claim only when a later comment links its audit URL or
audited sha7, names the exact finding title as `**<title>: fixed.**`, and includes
`fixed in` followed by a backticked commit SHA. The commit must be ahead of the audited head and change
the finding's file. This recognizes #580's recorded replies. It does not prove
the behavior is fixed; unmatched prose remains uncounted. For example:

```text
Findings fixed in `123abcd` from audit on `765fedc`:
**The chime continues over newly started speech: fixed.**
```

The repeated-outcome measure compares stable finding titles/files, clean
verdicts, or stop reasons with the preceding result for each job/PR. A batch is
repeated only if every target repeats. Repetition can be necessary verification,
so this is an inspection signal. No percentage appears until ledger events span
a week. Interactive Codex app sessions are outside this ledger.

### Claude desktop sessions (#899)

Claude Code sessions on this Mac are measured from their own transcripts, read-only:

```zsh
/usr/bin/python3 ops/ledger/claude_sessions.py --since 2026-10-05
```

This writes `~/SpokenMarginsOps/ledger/claude-usage.jsonl` (`--dry-run` only prints the
summary). It writes one row per turn, and each turn is a new prompt: an owner message, a
scheduled or `/loop` fire, or a task notification. Claude Code stamps these with
`turnPosition`. Sub-agent requests join the turn their time falls in. Each request
counts once. The transcript writes one line per content block, and an early streamed
line can carry a partial output count, so each request keeps its largest count. Input and
cached input follow the wrapper convention above. The raw counts are kept per row,
including the cache-write split.

The job comes from recorded fields only:
- `scheduled:<task>` from the `<scheduled-task name=…>` tag that opens a scheduled run (the
  Mac tick, the integration run);
- `testdesk` and `finisher` from the folder the session was opened on;
- `headless` for an `sdk-*` entrypoint. A headless session that a wrapper row already
  counts (its `session_ids`) is skipped.

Anything else is `desktop-other`. A turn's outcome links are the comment and PR URLs that
`gh pr|issue create|comment` printed in that turn. The links are its only targets;
otherwise the row says attribution is missing. A turn that was interrupted, failed on an
API error, still running, or holds a compaction is marked incomplete with the reason.
Unreadable lines and files are listed, never fatal. The collector is not part of any job,
so it can't change what a job posts.

Each session also gets a `session-check` row. It compares the transcript's totals with
Claude Code's own running total, the last `cost-state` line. Claude Code also counts
calls it never writes to the transcript: titles, side queries and compaction. On the
first run (2026-10-12, turns since 10-05), the transcripts held 93% of Claude Code's own
total over the 206 sessions whose total was final. In a separate check on 2026-10-12, 173
of the 226 sessions active in the previous 7 days matched it exactly. The report shows this share
as `claude.coverage`. It shows Claude turns under `claude`, by job, with outcome links,
and keeps them apart from the wrapper totals. Not measured: project threads that run in
the cloud, audit runs (they use `--no-session-persistence` and are counted by their
wrapper), and other machines. The report reads `claude-usage.jsonl` by default
(`--claude-ledger` for another file); `claude` is null until the collector has run.
Scheduling the collector is an owner step.

Host tests (Python 3.9, no simulator):

```zsh
/usr/bin/python3 -m unittest discover -s ops/ledger
/usr/bin/python3 -m unittest discover -s ops/codex
```

## Audit (headless Claude)

`sm_codex_audit.py` is the mechanical audit of PRs into the trunk (`main`). Since #1195 it runs on headless Claude (`claude -p`, model `opus`, effort `high`), read-only; before that it ran Codex (`gpt-6-astra`). launchd runs it every 5 minutes (`com.spokenmargins.codex-audit.plist`; 20 until #1456). An idle tick makes no model call. The script, job label, log and lock keep their old names, so the loaded job picks the change up when the ops checkout pulls `main`, with nothing to reinstall. Its docstring has the full gating rules. In short, it audits an open PR when:

1. The PR has no Codex or Claude audit comment naming its head. Only comments the lane runner also counts are audits: legacy ones starting ``**Codex audit (Astra)`` or `## Codex audit`, or an exact first-line heading ``**Claude audit on `<sha7>`**`` (7–40 lowercase hex characters). A finisher's reply such as ``**Codex audit on `a919a79` (P2): fixed in `d00dd82` `` is not (#812).
2. Its newest lane report is a PASS on the head. A PR only the owner merges (it touches `scripts/lane-runner.py` or `.github/`) is never armed, so it gets no lane report: it is audited once its head's check runs and commit statuses have all finished with none failed (`head_checks_state`, #2052). A lane FAIL on the head still blocks it, and a head with no checks yet waits. The owner-tap alert (`scripts/owner_tap_alert.py`) then says "audit clean" or names the findings; an alert that went out before the audit gets one follow-up when the audit lands.
3. It touches a risky area (sharing, persistence, audio, or the lane itself: `.github/workflows/`, `scripts/lane*` and the runner's helpers), or the runner says it is waiting on an audit, or a comment asks for one.

The comment it posts is ``**Claude audit on `<sha7>`**``, then the findings or "No blocking findings.", then a Claude read-only footer. The newest audit naming the head decides across both reviewers, old Codex comments on open PRs still count for their heads, and the accepted-findings memory below applies to both.

**Clearing a finding about the description (#1643).** The audit reads the PR's title and description, so it can block on them (a missing "Cost and catch" section, `Closes #N` where it should say `Part of #N`). Fix the description; do not push a commit to get a new head. The audit comment ends with a hidden last line, `<!-- audit-input: sha256=… -->`, a fingerprint of the title and description it read, after the footer so the heading and verdict line stay as the runner reads them. On its next tick the script audits the same head again, under the same ``**Claude audit on `<sha7>`**`` heading, when all of these hold:

- the newest audit of the head is blocking and carries that line, and the title or description has changed since (whitespace and line-ending edits don't count);
- the head has had fewer than 3 audits, so editing the description back and forth can't burn tokens (the limit is `MAX_DESCRIPTION_REAUDITS`, 2 re-audits per head);
- the newest lane report is still a PASS on the head, as for any audit.

Other ways to get a second audit of an audited head: a PR comment that asks for one (`/claude audit`, "please run a Claude audit"), posted after the head's newest audit (this ignores the limit and also works after a clean audit), or running the script by hand with `--pr N`. Audits posted before this change have no fingerprint and are not repeated for a description edit, so only a request or `--pr N` re-audits them. A clean audit is never repeated for a description edit. The runner already reads the newest audit that names the head, and a clean re-audit re-arms `automerge` once, like any other clean audit. A change to the code still needs a new head, and a new audit of it.

A re-audit that fails is remembered under the head plus the description it read (or the request comment), so it is retried once and then left alone until the description changes again or someone runs `--pr N`. The "waste signal" for these re-audits (#1643): count them per week in the log (`re-audit:` in the candidate reasons, `trigger` in the usage ledger) and how many return the same blocking finding as the audit before; if more than half do, or PRs often reach the limit, tighten the trigger to the explicit request.

**How the call works.** One `claude -p` per batch (up to 5 small PRs, or one large PR), prompt on stdin, in a throwaway worktree of `origin/main`. The tools are `Read,Grep,Glob` with `--permission-mode dontAsk`, so the reviewer cannot write, run commands or reach the network, whatever a PR says. Because it cannot run `git`, the script copies what it needs into the worktree first: each PR's diff, its changed files as they are at the head (`.sm-audit/pr-N-head/`, with `_AUDIT_INDEX.txt` listing files left out: deleted, symlinks, submodules, binary, over 2 MB, or over 10 MB in all), and the diffs since earlier audited heads. The OAuth token comes from the login Keychain (service `claude-code-oauth`), as for the integration run; with no token or no CLI the run logs `paused: …` and posts nothing. A call that fails (budget $10, 30 minutes, an error, or an answer with no section for the PR) logs why and posts nothing. The failure is remembered per head in `artifacts/ops/codex-audit-failures.json`: the PR is retried on the next tick once, and after two failures on the same head it is left alone (the log says `audit failed twice`) until it gets a new head (or, for a re-audit, a new description) or someone runs the script with `--pr N`. A clean verdict written in bold (`**No blocking findings.**`) is posted without the markup, because the runner reads the verdict by its first characters. The probe in #1195 cost $0.27 for a short read-only call; a real audit reads more, and the first ones are the real measure (the ledger records each batch's tokens and the kept output has the cost).

**It does not read the usage breaker.** An audit is a few cents to a dollar and unblocks a merge, and a held gate stalls audio, persistence and packet PRs with only the runner's "not merged" line to say why. If you want it to pause on `HALT (usage breaker: Claude)`, say so on #1195.

After a clean audit ("No blocking findings") it removes and re-adds `automerge` once, so the runner's automerge job runs again and can merge.

The log, lock and kept outputs are in `artifacts/ops/` (`codex-audit.log`, `codex-audit.lock`, `codex-audit-outputs/`).

Keep the `lane` patterns in step with `LANE_PREFIXES` and `LANE_FILES` in `scripts/test-scope.py`.

Try it. A dry run prints each PR's decision and the re-arm check, and makes no model call and posts nothing:

```zsh
/usr/bin/python3 ~/SpokenMarginsOps/repo/ops/codex/sm_codex_audit.py --dry-run
```

Run the host tests:

```zsh
/usr/bin/python3 -m unittest ops/codex/test_sm_codex_audit.py
```

## Accepted audit findings and review memory

Record one accepted finding per PR comment, using this exact field format. Copy
the file and title from the audit, including its wording; use the audited sha7:

```text
**Accepted audit finding:**
- Audited sha7: `ff249c5`
- File: `App/SpokenMarginsApp/Sources/SpokenMarginsApp/PlaybackStartCue.swift`
- Title: Slow synchronous startup still misses the one-second feedback requirement
- Follow-up issue: #842
- Accepted by: owner
```

The owner can accept a finding. A thread can use `Accepted by: C4 (Default taken)`
under its Default taken rule, except for owner data loss, privacy, security, or
packet/database compatibility with the last shipped build: those require the
owner. A thread's acceptance of one of those remains blocking. A reply by a
finisher is still not an audit. Legacy nickname-only owner decisions are carried
as context; migrate them to the complete record before relying on a waiver.

Each audit receives the acceptance records, the three most recent audits (plus
any older audit that an acceptance references), and both the full PR diff and
diffs since the last audited head and accepted-code heads. Each comment is capped
at `BODY_CHARS`; an incomplete, oversized or truncated record cannot waive a
finding. Missing historical commits are reported explicitly: the reviewer must
establish unchanged code from the diff files and the code, or judge the finding again.

An accepted finding whose code is unchanged appears as one line under
`Previously accepted`, with its follow-up issue. If the new head changes that
code, the reviewer judges it again. An unrelated edit elsewhere in the same file
does not by itself invalidate acceptance. New findings still block. An answer
with only accepted findings starts `No blocking findings.` before the accepted
lines, so the lane runner, worker, audit re-arm and merge audit keep using their
existing verdict parsers.

## Codex Test Desk (retired)

`sm_codex_testdesk.py`, its plist and its tests are deleted (#1195). Its job, `--plan app` plus scripted journeys on each new tip of `next` with reports on #184 and real failures filed as `ready,priority,bug`, belongs to the integration script in `ops/testdesk/` (#1178), with culprit search and revert in #1180. The launchd job `com.spokenmargins.codex-testdesk` was never loaded. If your Mac has it installed anyway, remove it: `launchctl bootout gui/$(id -u)/com.spokenmargins.codex-testdesk`, then delete `~/Library/LaunchAgents/com.spokenmargins.codex-testdesk.plist`.

## After 2026-10-15 (owner)

1. Done (owner, 2026-10-17): the Codex worker is unloaded, and its files are deleted from the repo (#1853). Delete `~/Library/LaunchAgents/com.spokenmargins.codex-worker.plist` if it is still there.
2. Leave `com.spokenmargins.codex-audit` loaded. It is the Claude audit now.
3. Remove the **Codex workers**, **Codex stop line**, **Codex finish by** and **Codex focus** groups from the Dial (#589), and the Codex usage line from the Mac tick. Both live outside the repo.
