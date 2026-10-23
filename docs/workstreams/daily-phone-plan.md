# Daily phone pass

`scripts/daily-phone-plan` prepares the owner's daily hardware pass from the newest complete rolling binary. It builds nothing. A five-minute launchd tick delivers once after 08:00 America/Chicago, including daylight saving changes. After 17:00 it delivers only if five new eligible fixes wait compared with the last delivered plan. A sleeping Mac catches up when it wakes. No TestFlight email or upload is involved.

The input is every `status: needs-human-validation` issue, open or closed in the last 60 days (a merged fix closes its issue and the label stays, owner 2026-10-22), whose fixing PR is in that binary, excluding reverts. It reuses `phone-build`'s build and fix evidence, comment overrides, supplied-file checks and prerequisite checks. The install record never reduces the backlog. Still-open issues from the previous plan cannot disappear without explicit revert evidence; reverted issues stay visible as blocked. GitHub failure leaves the previous plan intact.

One read-only Claude call proposes the walkthrough. The SessionKit `PhoneValidationPlan` audits complete coverage, exact control names from the selected commit, concrete sources, actions, expected results and time estimates. It groups checks on the same concrete source into one step. Two fixes share a check only when its expected result proves both. A missing source, label or written check becomes a named block for the coordinator to resolve, rather than invented instructions. Every check carries issue numbers. Plans can exceed ten minutes rather than hide outstanding checks.

The daily job holds the rolling builder's lock and its disk/memory gates. `daily-ready` pins one existing binary, which rolling retention preserves. The Desktop installer chooses that binary while the pass is pending; subsequent rolling builds still update `latest` normally. After all runnable checks have explicit results the pin is released, provided it still names that pass's binary. At most one extra binary is retained. No app uninstall, reset, reseed, migration or owner data operation is added.

## Deploy on the Mac

This PR does not install a job or change the Desktop copy of the shortcut.

1. From the main checkout, compile the Foundation-only tool once:
   `swift build --package-path Packages/SessionKitTools -c release --product phone-plan --disable-sandbox`
   It lands in `Packages/SessionKitTools/.build/release/phone-plan`. A binary built before #1873 at `Packages/SessionKit/.build/release/phone-plan` is still used until this one exists.
2. Configure the authenticated project-chat relay in the LaunchAgent environment: `SM_DAILY_RELAY_URL` and `SM_DAILY_RELAY_TOKEN`. It uses the existing Dial/lane-open `/fire` contract (`ops/lane/README.md`); `SM_LANE_OPEN_URL` and `SM_LANE_OPEN_TOKEN` are accepted too. Keep the token out of git. Authenticate the Claude CLI under this Mac login as for the audit. `SM_DAILY_CLAUDE` and `SM_DAILY_VALIDATOR` can override executable paths.
3. Refresh the Desktop **Install Spoken Margins on iPhone.command** from `scripts/install-phone-build.command` so it honors the daily pin. Keep the existing Desktop name. The rolling LaunchAgent is unchanged.
4. Render the job with `ops/install-launchd.py --print daily-phone-plan`, add the relay variables to its `EnvironmentVariables`, save it as `~/Library/LaunchAgents/com.spokenmargins.daily-phone-plan.plist`, then run:
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.daily-phone-plan.plist`
5. Run `scripts/daily-phone-plan --on-request` for a first attended delivery. Confirm one project-chat announcement, one Mac notification with the duration, and the same commit in the plan, binary and Settings > Version. Run the walkthrough on the phone without deleting existing content.

A missing relay or validator is a visible error in `~/SpokenMargins-phone/daily-plan.log`. A failed writer is never automatically retried for that slot; correct the evidence and use `--on-request`. A delivery retry reuses its audited proposal. Per-channel receipts prevent routine duplicate announcements. An interrupted relay response has the normal network ambiguity: the coordinator must deduplicate using the pass ID supplied in the message.

## One owner reply

The relay hands the coordinator the full walkthrough and instructions to post it once, deduplicated by pass ID. The plan's fenced reply names the pass, full commit and each runnable issue. The owner replaces TODO with PASS, FAIL plus what happened, or SKIP. PASS means every assertion for that issue passed. Missing results, TODO and silence never close an issue; blocked issues cannot be marked PASS.

The coordinator saves the exact pasted owner reply in a temporary text file and runs:

```sh
scripts/daily-phone-plan --results /tmp/phone-pass-reply.txt
```

Explicit passes use `~/.claude/bin/sm-gh close-issue` with the merged fixing PR and the owner's evidence. Failures create a `bug,found-on-phone` issue in Solid Ground with build number, commit, original issue, steps, expected and actual behavior; the original issue remains open. Local action receipts and a failure marker searched on GitHub prevent repeat processing. SKIP stays open. If a manual merge has no fixing PR, the coordinator supplies that evidence before closing it. The command resets the unanswered count when a reply is processed.

## Cost and catch

1. Per delivered plan: one short Claude writing pass and a small Swift audit; no app build and no Actions minutes. Typical owner budget is about ten minutes; the actual estimate includes every runnable check. One initial release compilation of the plan tool is required at deployment. Tokens and runtime depend on backlog size; the raw Claude response, including usage, stays in `daily-plans/<pass>/writer.json`.
2. Once daily, twice when at least five new fixes wait. The five-minute tick normally performs only a clock/state check; a deferred resource gate retries without invoking Claude. A 17:00 pass with fewer than five new fixes is skipped for that day, so later ticks do not repeat its GitHub queries.
3. Intended catch: hardware-only failures in audible content, AirPods/Bluetooth, Lock Screen and heat. Evidence for batching: #1600 records 19 of 25 open Solid Ground issues waiting on the owner's phone. The host fixtures prove two fixes share a source step and that an open issue cannot be lost from the previous plan; they do not prove an actual hardware catch. Filed phone failures provide that evidence.
4. Waste signal: three consecutive delivered daily plans without owner results. State records the unanswered days and switches permanently to on-request delivery at three. An on-request reply does not re-enable automatic delivery. `scripts/lane_ledger.py` records writer runtime and its normal waste alarm in `daily-plan-ledger/step-ledger.json`; this is a job (PR 0), not a per-PR gate. Hardware failures are kept as owner result evidence rather than counted as writer catches. Build retention remains bounded to one pin plus normal rolling builds. Per-pass receipts, writer usage and result actions let the coordinator audit skipped plans, duplicate delivery and hardware catches.
