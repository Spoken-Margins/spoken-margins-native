# Usage breaker, per provider

The usage breaker stops work when a weekly allowance is running ahead of its line. Since 2026-10-09 (owner) it is decided **per provider**: a provider over its line halts only the work that runs on that provider. Claude over its line halts Claude threads, the Mac finisher, the SM integration run and the Dial gate's wake-ups. Codex over its line halts Codex tasks. Before this, either provider over its line halted both.

The thresholds, the stop line and the trend rule are unchanged. Only the scope of the halt changed.

## What lives where

1. **The decision** is made by the `SM Mac tick` scheduled task on the Mac (`~/.claude/scheduled-tasks/sm-mac-tick/SKILL.md`), outside this repository. It reads both providers' usage and posts the result on #337. The text below goes there.
2. **Claude-side readers** act on a Claude halt only: the Dial gate (`dial_gate.py`, deployed on the VPS), the coordinator's dispatch rule, the Mac finisher and the SM integration run (their prompts and the project instructions, outside this repository).
3. **Codex-side tasks** (`ops/codex/sm_codex_worker.py`, `sm_codex_audit.py`, `sm_codex_testdesk.py`) never read the tick, so a Claude halt never stopped them. The worker and the Test Desk hold on Codex's own stop line and trend. The audit holds only when a Codex usage window is used up or the read fails; it has no stop-line hold, so a Codex halt on the tick pauses nothing there until the audit gets one.

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
