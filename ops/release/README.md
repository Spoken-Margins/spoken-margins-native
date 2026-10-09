# Release cut

`cut_candidate.py` cuts a Build N release candidate from `next` with no one watching. It replaces the one-time Claude scheduled task that stalled on a permission prompt at 21:00 on 2026-10-01, so Build 30 missed the Friday window (#687).

It does these steps in order and stops at the first one that fails:

1. Fetches. With `--wait-for`, it waits until those PRs merge or `--deadline` passes, then records whether each PR is in the candidate. A PR that didn't make it doesn't stop the cut.
2. Pushes `release/build-<N>` at `next`'s tip, or at `--commit`. If that branch already exists at another commit, it stops without pushing.
3. Holds the rolling phone-build job (`com.spokenmargins.phone-build`): it unloads and disables it, so nothing moves `~/SpokenMargins-phone/latest` off the candidate, even after a restart. Then it runs `scripts/phone-build --commit <sha>` and checks that `latest/build.json` names that commit.
4. Adds a "Build N candidate" section to that build's `test-plan.md`: the PRs it waited for and your known-issues file. Then it copies the plan to Files > iCloud Drive > Spoken Margins test plans, as "Build N test plan <commit>.md".
5. Asks the Test Desk for T5 on #184, posts the candidate note on #337, and sends a Mac notification.

If a step fails, it posts what stopped and what was already done on #337, and sends a notification. If it held the phone-build job and the build hadn't finished, it turns the job back on; after a good build, the job stays held so `latest` keeps the candidate. Once the branch is pushed, the retry command in the note names the same commit, because `next` will have moved on. It never retries. It never bumps the version, archives, uploads, tags or touches `main`. Those stay your call.

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
launchctl enable gui/$(id -u)/com.spokenmargins.phone-build && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.phone-build.plist
```

## Tests

```zsh
python3 -m unittest discover -s ops/release -t ops/release
```

The tests use a scratch git origin and fake `gh`, phone-build, `launchctl` and notification commands. Nothing reaches GitHub, launchd or a phone.

## Archive and upload

`AGENTS.md` ("Releasing a build") keeps the guardrails; these are the steps. The owner decides when a build goes to testers. Once they say to upload, archive and upload a normal App Store Connect build, then assign it only to the authorized tester groups. Normal uploads remain eligible for external TestFlight and App Store review; that eligibility does not authorize external distribution, review submission or public release. Never select TestFlight Internal Only unless the owner explicitly requests that restriction.

Apple build numbers identify uploads, not product milestones. Each replacement upload needs a new, unused build number even when its functionality stays at the same milestone. Preserve historical tags and uploaded build identities.

1. Bump `CURRENT_PROJECT_VERSION` in `project.yml` (every target), run `xcodegen generate`, and commit.
2. Verify through layer 3 (journeys, in `AGENTS.md` "Verification") and list anything not verified.
3. Archive (`artifacts/` is git-ignored):
   `scripts/xcodebuild-lane -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -configuration Release -destination generic/platform=iOS -archivePath artifacts/SpokenMargins-<build>.xcarchive -allowProvisioningUpdates archive`
   Check the archive's `CFBundleVersion` is the new build number.
4. Upload with external-review eligibility retained (`testFlightInternalTestingOnly` is false in the default plist), then assign only the authorized tester groups:
   `PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive -archivePath artifacts/SpokenMargins-<build>.xcarchive -exportOptionsPlist scripts/TestFlightUploadOptions.plist -exportPath artifacts/export-<build> -allowProvisioningUpdates`
   The PATH prefix matters: Homebrew's rsync breaks Xcode's packaging step. A warning that onnxruntime.framework has no dSYM is expected and harmless.
   Check App Store Connect does not mark the uploaded build `Internal`. Confirm its version, build number and group assignment before calling the upload complete. External review and tester notification remain separate owner decisions.
5. Tag the archived commit `testflight/0.1-build-N`, push the tag, and fast-forward `main` to the release (ask before merging if it isn't a fast-forward).
6. Delete the archive and export folders unless the owner wants them kept.

Give the owner a short test checklist: the journeys to try, what changed, and known issues.
