# Release cut

`cut_candidate.py` cuts a Build N release candidate from `next` with no one watching. It replaces the one-time Claude scheduled task that stalled on a permission prompt at 21:00 on 2026-10-01, so Build 30 missed the Friday window (#687).

It does these steps in order and stops at the first one that fails:

1. Fetches. With `--wait-for`, it waits until those PRs merge or `--deadline` passes, then records whether each PR is in the candidate. A PR that didn't make it doesn't stop the cut.
2. Pushes `release/build-<N>` at `next`'s tip, or at `--commit`. If that branch already exists at another commit, it stops without pushing.
3. Holds the rolling phone-build job (`com.spokenmargins.phone-build`), so nothing moves `~/SpokenMargins-phone/latest` off the candidate. Then it runs `scripts/phone-build --commit <sha>` and checks that `latest/build.json` names that commit.
4. Adds a "Build N candidate" section to that build's `test-plan.md`: the PRs it waited for and your known-issues file. Then it copies the plan to Files > iCloud Drive > Spoken Margins test plans, as "Build N test plan <commit>.md".
5. Asks the Test Desk for T5 on #184, posts the candidate note on #337, and sends a Mac notification.

If a step fails, it turns the phone-build job back on (if it held it), posts what stopped and what was already done on #337, and sends a notification. It never retries. It never bumps the version, archives, uploads, tags or touches `main`. Those stay your call.

A finished or stopped cut writes `~/SpokenMarginsOps/release/build-<N>.json`. Running again for the same build does nothing unless you add `--again`.

## Check what it would do

```zsh
python3 ~/Documents/GitHub/spoken-margins-native/ops/release/cut_candidate.py --build 30 --wait-for 604 --deadline 22:30 --known-issues ~/SpokenMarginsOps/release/known-issues.md --dry-run
```

It prints the candidate commit, the PRs' state, whether the branch push would work, and the T5 request it would post. It pushes, builds, holds and posts nothing.

## Cut now

The same command without `--dry-run`. Add `--at 21:00` to start at 21:00 instead; keep the Terminal window open until it finishes.

## Cut at a set time, with the window closed

1. Write the known issues, one per line, in `~/SpokenMarginsOps/release/known-issues.md`.
2. Copy the template:

   ```zsh
   mkdir -p ~/SpokenMarginsOps/release && cp ~/Documents/GitHub/spoken-margins-native/ops/release/com.spokenmargins.release-cut.plist ~/Library/LaunchAgents/
   ```

3. Open `~/Library/LaunchAgents/com.spokenmargins.release-cut.plist` and change the build number, `--at`, `--wait-for`, `--deadline` and the known-issues path. Use full dates, like `2026-10-04T21:00`.
4. Load it. It starts right away and waits for the `--at` time by itself:

   ```zsh
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.release-cut.plist
   ```

5. After the cut, remove it:

   ```zsh
   launchctl bootout gui/$(id -u)/com.spokenmargins.release-cut && rm ~/Library/LaunchAgents/com.spokenmargins.release-cut.plist
   ```

Its output goes to `~/SpokenMarginsOps/release/log.txt`. The Mac must be awake at the start time; if it was asleep, the cut starts when it wakes.

## After you've tried the build

The candidate note on #337 has the command that turns the rolling phone build back on:

```zsh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.phone-build.plist
```

## Tests

```zsh
python3 -m unittest discover -s ops/release -t ops/release
```

The tests use a scratch git origin and fake `gh`, phone-build, `launchctl` and notification commands. Nothing reaches GitHub, launchd or a phone.
