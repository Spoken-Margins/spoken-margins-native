# Dial gate: Paced with the Mac asleep

The usage figure comes only from the Mac tick on #337, and threads run in the cloud without the Mac. So since #3518 a report that is out of date no longer stops the work by itself.

1. **A report under 3 hours old reads at face value**, as it always did. A Mac that is awake holds no earlier than before.
2. **An older report is charged for what ran since it (#4111).** The estimate adds 0.33 points an hour for the whole age (the idle rate), plus 0.55 points for each hour a Claude thread was active since the report, read from the claim and stop notes. Three threads running all the time add up to the old 2 points an hour. Any part of the age the gate could not read threads for (the repo's comment read hit its page cap) is charged at the full 2 points an hour, so missing data holds more, never less. Paced holds when the estimate reaches the hold line (stop line minus 3) or runs more than 10 points ahead of the trend, and the status comment says it is an estimate and shows the thread-hours it charged. Before #4111 the full 2 points an hour was charged for the whole age, so a gate that was holding (nothing running) still saw usage climb: on 2026-11-12 a 65% report 12 hours old read 90% while real usage was 66%.
3. **A report from before this week's reset** counts up from 0% at the reset.
4. **No report in 8 days** holds. A `HALT (usage breaker: Claude)` holds until its `RESUMED`, including one from before the reset.
5. **An unanswered fire with no thread active** is retried after 30 minutes, then 1, 2 and 3 hours. With a thread active it waits 3 hours.

The Mac worker (`ops/claude/sm_claude_worker.py`) keeps the plain 3-hour hold: it runs on the Mac, so a stale report there means something is wrong.

**Re-measure the rates** (`IDLE_BURN`, `THREAD_BURN` and the 2-point `STALE_BURN` they must add up to with three threads) when the thread count or the plan changes. Read every `Claude N% used` from #337 with its `created_at`, take the points gained over 6-hour and 12-hour spans inside one week, and look at the high end. The gaps where the Mac was off and the gate was holding read low (0.09 to 0.33 points an hour): that is the idle rate, and the top of it is `IDLE_BURN`. For `THREAD_BURN`, divide the busy-span gain, less the idle rate, by the thread-hours in that span.

**The sign it's wrong:** the first report after a long gap comes in above the estimate on the status comment's edit log for that time (GraphQL `userContentEdits` on the comment marked `dial-gate-status`).

# Usage breaker, per provider

The usage breaker stops work when a weekly allowance is running ahead of its line. Since 2026-10-09 (owner) it is decided **per provider**: a provider over its line halts only the work that runs on that provider. Claude over its line halts Claude threads, the Mac finisher, the SM integration run and the Dial gate's wake-ups. Codex over its line halts Codex tasks. Before this, either provider over its line halted both.

The thresholds, the stop line and the trend rule are unchanged. Only the scope of the halt changed.

## What lives where

1. **The decision** is made by the `SM Mac tick` scheduled task on the Mac (`~/.claude/scheduled-tasks/sm-mac-tick/SKILL.md`), outside this repository. It reads both providers' usage and posts the result on #337. The text below goes there.
2. **Claude-side readers** act on a Claude halt only: the Dial gate (`dial_gate.py`, deployed on the VPS), the coordinator's dispatch rule, the Mac finisher and the SM integration run (their prompts and the project instructions, outside this repository).
3. **Codex-side tasks** (the Codex worker, retired by #1195, unloaded by the owner on 2026-10-17 and deleted by #1853) never read the tick, so a Claude halt never stopped them. The worker holds on Codex's own stop line and trend. The audit (`sm_codex_audit.py`) is a Claude task since #1195, but it does not read the tick either: it is a merge gate and costs little, so a Claude halt does not pause it (a Default taken, veto on #1195).

## Marker format

The marker is `HALT (usage breaker: <providers>)` or `RESUMED (usage breaker: <providers>)`, with `Claude`, `Codex` or `Claude, Codex`. An unscoped `HALT (usage breaker)` is the old wording and means every provider.

- **The tick's advice line** names the halted providers and what each halt means:
  - `advice for dispatch: HALT (usage breaker: Codex): Codex tasks pause; Claude threads continue.`
  - `advice for dispatch: HALT (usage breaker: Claude): start no new Claude threads; Codex tasks continue.`
  - `advice for dispatch: HALT (usage breaker: Claude, Codex): start nothing.`
  - With no halt, no marker.
- **A change of state** gets its own comment, opening with `**HALT (usage breaker: <providers>)**` or `**RESUMED (usage breaker: <providers>)**` and one line of why. A halt stays until a RESUMED names that provider; a later tick without a marker does not clear it.

`dial_gate.py` reads these: a Claude halt holds Paced mode, a Codex-only halt changes nothing, and the status comment on #589 names the halted providers. It reads the scoped form on the advice line, and both forms when a comment opens with the marker, so the old wording on an advice line holds nothing until the tick is updated.

## Text for the Mac tick

Replace the single usage-breaker step in `SKILL.md` with:

```text
USAGE BREAKER, per provider. Apply the existing breaker test (the same thresholds and stop line) to Claude and to Codex separately, each against its own usage and its own share of the week gone. Never let one provider's result halt the other.
- Halted set = the providers that fail the test. Compare it with the last HALT or RESUMED marker on #337.
- If a provider joined the set, post `**HALT (usage breaker: <providers>)** · <provider> N% used, M% of its week gone.` as its own comment. If one left it, post `**RESUMED (usage breaker: <providers>)** · <why>`. Name only the providers that changed.
- The last line of every tick: `- advice for dispatch:` followed by `HALT (usage breaker: <providers>): <what pauses and what continues>` when the set is not empty, using the wording in ops/dial/README.md, otherwise the usual pacing advice.
- Claude halted: your own Claude work (SM integration run, Mac finisher) pauses. Codex halted: only Codex tasks pause; run the Claude work as usual.
```

## Text for the project instructions and the Claude loops

In the coordinator's project instructions, replace the `USAGE BREAKER (overrides everything)` paragraph with:

```text
USAGE BREAKER (per provider, overrides everything for Claude work)
Before starting any thread, read the latest Mac tick on #337. On HALT (usage breaker: Claude) or an unscoped HALT (usage breaker): start nothing, and tell running threads to finish their current commit, push, post their stop note, report in one line and stop. Resume only after a later RESUMED (usage breaker: Claude) or unscoped RESUMED. A HALT that names only Codex does not stop Claude threads, the Mac finisher or the Dial relay.
```

The Mac finisher's pause rule (`artifacts/finisher-prompt.md` on the Mac) and the SM integration run's prompt change the same way: pause for `HALT (usage breaker: Claude)` and an unscoped HALT, not for a Codex-only HALT.

## Apply it

1. Paste the tick text into `sm-mac-tick/SKILL.md` and the instruction text into the project instructions and the finisher and integration prompts.
2. Redeploy the Dial gate: `ops/dial/deploy.sh <ssh-host> --dry-run`, then `--enable`.
3. The next tick on #337 should name the halted provider. Until the tick is updated, its old unscoped HALT still reads as every provider to anything that reads it.

## Tests

```zsh
python3 -m unittest discover -s ops/dial
```

`scripts/verify-tests.py --plan fast` runs them too, as the `ops-dial` step.
