# Scheduled jobs, and what a public repo would expose

One place for every job that runs on a clock or an event and drives the project, so nobody has to guess where a routine lives (#1601). Last checked 2026-10-14 from a cloud session (the counts in the readiness note were taken once, not re-run). When a job is added, moved or paused, change its row in the same PR.

"Checked" below means read from the real source that day. A row marked **not checked** names what the cloud session could not reach; the Mac and VPS state needs a read-only look from there.

## Where each kind of job lives

| Kind | Where | How it is configured |
|---|---|---|
| Project routines | Claude routines on the owner's project | The routine list (`list_triggers`). Not in this repo. |
| Claude scheduled tasks and loops | The owner's Mac, `~/.claude/scheduled-tasks/` and long-running threads | Outside this repo. |
| Mac launchd jobs | `~/Library/LaunchAgents/`, one plist per job | Plist templates in this repo (`ops/`, `scripts/`), rendered and installed with `ops/install-launchd.py` (`--list`, `--print JOB`, `--install JOB`, `--remove JOB`). The templates hold `@HOME@`; nothing is installed or reloaded by merging one. |
| VPS systemd | The owner's VPS | Units in this repo (`ops/dial/`, `research/B4/deploy/`), installed by `deploy.sh`. |
| GitHub Actions | `.github/workflows/` | Workflow files in this repo. |

## The table

Times are UTC unless a zone is named. "Pause" is the way to stop that one job without touching the others.

### Project routines (checked with `list_triggers`, 2026-10-14 19:3x)

| Job | Schedule | Reads | Writes | Config owner | Pause |
|---|---|---|---|---|---|
| Dial relay | None. Fired by the Dial gate and by lane-open pings through the routine's fire endpoint | The fire payload | A project-chat post only on a state change (Off, Holding, a new thread count); otherwise the payload goes to the coordinator | Routine; project instructions say how it behaves | Disable the routine, or set the Dial to Off on #589 |
| Hourly dispatch | `20 */3 * * *` (every 3 hours; last fired 18:20, next 21:20) | Latest Mac tick on #337, lane reports, audits, `automerge` PRs | Labels, comments, thread starts | Routine, with the project instructions' HOURLY DISPATCH list | Disable the routine |
| Spoken Margins daily routine | `CRON_TZ=America/New_York 30 21 * * *`; last fired 01:36, so it ran about 6 minutes after 21:30 Eastern | Issues filed since its last run, and the project board. The owner-side prompt change to "every open issue with no milestone" is pending (#337, 2026-10-16) | Labels, the Area field, new `ready` issues, thread starts | Routine, with FILING NEW ISSUES in the project instructions | Disable the routine |
| Six disabled routines | None. Four one-shot reminders from 2026-09-30 and two `limit_wake` retries from 2026-10-10 | | | | Already off. Safe to delete. |

### Claude work on the Mac (not checked: lives outside this repo)

| Job | Schedule | Reads | Writes | Config owner | Pause |
|---|---|---|---|---|---|
| `SM Mac tick` scheduled task (`~/.claude/scheduled-tasks/sm-mac-tick/SKILL.md`) | Every 2 hours (`docs/workstreams/kickoff.md`) | Claude and Codex usage, runners, disk, memory, the main checkout, the Test Desk work list | One comment on #337 (breaker, pacing advice, scorecard, `- Test Desk: GO` line); fast-forwards the main checkout | Owner | Disable the scheduled task |
| `SM integration run` scheduled task | Understudy only (`docs/workstreams/test-lane.md`). `ops/testdesk/` replaces it once the launchd job has posted a real report (#1178) | | Reports on #184 | Owner | Disable the scheduled task |
| [Mac finisher](workstreams/finisher.md) | A loop in the thread "Mac finisher" | `needs-mac` PRs | Commits to those PR branches, comments | Owner, and the project instructions | Pause is built in: HALT, disk under 20 GB, Dial Off |
| Managed Test Desk | Started by hand or by the coordinator when the tick says `Test Desk: GO` | The work list the tick names | Reports on #184 | Coordinator | End the session |
| Claude Mac worker | Not live. #1599 (PR #1604) | | | | |

### Mac launchd jobs (plists in this repo; loaded state **not checked**)

| Job (label `com.spokenmargins.*`) | Schedule | Reads | Writes | Config owner | Pause |
|---|---|---|---|---|---|
| `phone-build` (`scripts/`) | Every 10 min; `scripts/phone-build` coalesces to at most one build an hour, or sooner after an integration PASS | `next`'s tip, integration reports on #184 | `~/SpokenMargins-phone/` builds, `latest/build.json`, `test-plan.md` | Owner | `launchctl bootout gui/$(id -u)/com.spokenmargins.phone-build` |
| `integration-run` (`ops/testdesk/`) | Every 10 min, and at load; waits for a quiet lane | `next`'s tip, #184 | `Lane report integration-<sha7>` on #184, culprit and revert on a real FAIL | Owner | `launchctl bootout` of the label |
| `codex-audit` (`ops/codex/`) | Every 5 min | Lane and risky PRs | `**Claude audit on <sha7>**` on the PR. The name is old; it calls headless Claude (#1195) | Owner | `launchctl bootout` of the label. Nothing merges an audio, persistence, packet or lane PR without it. |
| `disk-relief` (`ops/disk/`) | Every 15 min, and at load | Free space, worktrees, session folders | Deletes rebuildable caches and finished worktrees, moves old artifacts to the external drive | Owner | `launchctl bootout` of the label |
| `keep-awake` (`ops/power/`) | Every 60 s, and at load | Running builds, agent transcripts | Starts Amphetamine sessions | Owner | `launchctl bootout` of the label, or take out `--lid` for heat |
| `lane-power-guard` (`ops/lane/`) | Every 15 s, and at load | Power source, lid, runner state | Stops and starts the lane runner services it paused | Owner | `launchctl bootout` of the label |
| `lane-tools-refresh` (`ops/lane/`, #2536) | Hourly, and at load | The lane tools copy (`SM_LANE_TOOLS`), `origin/main`, the lane's running jobs | Moves the copy to `main`; refreshes its `.venv` and `node_modules` when requirements or the lockfile changed; comments on #337 (once a day per problem) when it cannot | Owner | `launchctl bootout` of the label |
| GitHub Actions runner services `actions.runner.uncomposed-spoken-margins-native.*` | Always on | Queued jobs | Run `lane.yml` (`lane`, `automerge`, `release`) and `shipped-build-compat.yml` jobs for labels `sm-lane`, `sm-lane-build`, `sm-lane-priority` | Owner; not in this repo | `launchctl bootout` of the service. The power guard restarts only runners it paused itself. |

### VPS (plists and units in this repo; live state **not checked**)

| Job | Schedule | Reads | Writes | Config owner | Pause |
|---|---|---|---|---|---|
| `sm-dial-gate.timer` and `.service` (`ops/dial/`) | `OnCalendar=*:2/15` with up to 60 s of random delay, plus a 3-hour fallback wake-up | The Dial boxes on #589, the tick on #337, the ready queue, claim and stop notes | One status comment on #589; a fire to the Dial relay | Owner, with the Dial boxes | Set Mode to Off on #589, or (my suggestion, not in the repo's README) `systemctl disable --now sm-dial-gate.timer` |
| Runner `sm-vps` (service name not in repo) | Always on, but no CI job targets it since #2383 | Nothing | Nothing (the `lane-open-*` jobs moved to `ubuntu-latest` and keep their 10-minute limit on the `lane-open-state` branch) | Owner | Stop the runner service (nothing depends on it) |
| Runner `sm-vps-t1` (not in repo) | Always on, but no CI job targets it since #2442 | Nothing | Nothing | Owner | Stop the runner service (nothing depends on it) |
| `smserver.service` (`research/B4/deploy/`) | Always on, restarts on failure | Requests, `/etc/smserver/maps.env` | Share links, maps, attestation, an hourly request summary to its own journal namespace | Owner | `systemctl stop smserver` |
| VPS crontab | Not checked | | | | The repo contains no cron entries |

### GitHub Actions (checked: `actions/workflows` shows all four `active`, 2026-10-14)

| Workflow | Trigger | Runs on | Does |
|---|---|---|---|
| `lane.yml` | `pull_request` into `next` or `lane-check/**` (labels `lane:queued`, `automerge`); `workflow_dispatch` from the lane job after a T3 PASS | `route`, `lane-open-*` on `ubuntu-latest`; `lane`, `automerge`, `release` on the Mac | Tests the PR, merges `automerge` PRs on PASS, pings the Dial when a runner is idle |
| `hosted-portable.yml` | `pull_request` into `main` | GitHub-hosted `ubuntu-latest` | The portable fast checks, then the `owner-tap-alert` job (`linux-t1.yml` was retired in #2442) |
| `shipped-build-compat.yml` | `pull_request` into `next` touching persistence, sharing or stored types | Mac `sm-lane` | Build 29 can still open the database this PR writes |
| `verify-tests.py` step `shipped-compat` (#1899) | Every automerge run of `--plan fast` or `--plan fast-mac-rest` whose diff matches that workflow's `paths` | Mac `sm-lane` | The same two checks, inside the plan the runner merges on, because a required check can't stand on the merge commit the runner pushes |
| `merge-audit.yml` | `push` to `next` | `ubuntu-latest` | Labels merges that skipped the merge check |

No workflow has a `schedule:`. GitHub runs scheduled workflows only from the default branch, and `main` doesn't carry them. Repo secrets `SM_LANE_OPEN_URL` and `SM_LANE_OPEN_TOKEN` (`ops/lane/README.md`) and runner status **could not be checked**: the cloud proxy blocks the Actions secrets and runners endpoints.

## To fill the unchecked rows (read-only, on the Mac and the VPS)

On the Mac:

```zsh
launchctl list | grep -E 'spokenmargins|actions.runner'
ls ~/Library/LaunchAgents | grep -E 'spokenmargins|actions.runner'
plutil -lint ~/Library/LaunchAgents/com.spokenmargins.*.plist
ls ~/.claude/scheduled-tasks/
```

On the VPS:

```sh
systemctl list-timers --all | grep -E 'sm-|smserver'
systemctl list-units 'actions.runner*' --no-pager
crontab -l; sudo crontab -l; ls /etc/cron.d
```

From any machine with repo admin: `gh api repos/uncomposed/spoken-margins-native/actions/runners` and `gh secret list -R uncomposed/spoken-margins-native`.

## Needs a fix

Found while building the table. Routine and plist changes are the owner's or the coordinator's; none was made here.

1. **"Hourly" dispatch runs every 3 hours.** The routine's cron is `20 */3 * * *`, but its own prompt, AGENTS.md ("dispatches lane results every hour") and the project instructions say hourly at 20 past. #1601 records the same gap on Oct 9. Fix: set the cron to `20 * * * *`, or if 3 hours is the owner's choice, change the three texts.
2. **Two checkouts on the Mac, two update paths.** `disk-relief`, `keep-awake`, `lane-power-guard` and `phone-build` run from `~/Documents/GitHub/spoken-margins-native` (the Mac tick fast-forwards it). `codex-audit` and `integration-run` run from `~/SpokenMarginsOps/repo` (the phone-build job keeps it on `next`, per `ops/testdesk/README.md`). A change to an ops script reaches the two sets at different times. Fix: say in each README which checkout runs it, or move all to one.
3. **`scripts/com.spokenmargins.phone-build.plist` says the "hourly Mac tick".** The tick is every 2 hours (`kickoff.md`). (Its header comment used to contain `--if-changed`, a double hyphen that is not allowed inside an XML comment; #1843 reworded it.) Fix the tick wording in the next change to that file. #1600 is about to edit it, so it was left alone here.
4. **`docs/workstreams/kickoff.md` still describes a standing Test Desk "in a loop".** Current practice (project instructions, 2026-10-13) is a managed desk started on a `Test Desk: GO` tick line. Fix: update `kickoff.md` the next time that table changes.
5. **Six dead routines.** See the routine table. Fix: delete them.
6. **`codex-audit` is named for Codex but calls Claude.** Documented in `ops/codex/README.md`, kept so the loaded job, log and lock carry on. No action unless the owner wants a rename after 2026-10-15.

## Public-repo readiness note

The owner wants the repo public for unlimited GitHub Actions runners. That is his call; this is what a public repo would show and what it would and wouldn't replace. Checked from a full clone (3,569 commits, about 785 branches, 17 tags) and from the 1,604 issues and PRs and 9,768 comments through the GitHub API on 2026-10-14.

### What the scans found

| Check | Result |
|---|---|
| Secret-shaped strings (AWS, GitHub, Anthropic, Slack, Google keys, private-key headers) across the working tree and every commit of every branch | None. One test constant (`sk-ant-test-0123456789-SECRET` in `research/B4/server/cmd/smserver/main_test.go`). A pattern scan, not an entropy scan: run `gitleaks detect` on the Mac before deciding. |
| The same patterns in issue and PR bodies and comments | None. No email addresses, no IP addresses except compiler version strings and documentation-range test values. |
| **Committed build output in history** | **8,994 paths under `artifacts/`** (first 2026-06-14; tracking stopped 2026-09-24 in `f677ded`). They are on `main` and `next`, in 88 commits. They include an Xcode archive of build 0.1-4 with `embedded.mobileprovision` files whose `ProvisionedDevices` list holds the owner's device identifiers, and simulator diagnostics. `artifacts/` is now git-ignored and nothing under it is tracked. |
| The owner's Mac username and paths | `/Users/colemiller/` in 12 other tracked files (the plists above, `validation/gate1-behaviors.json`, one prototype export), and **4,961 times in 2,297 comments and 25 issue bodies**, mostly lane reports. |
| The owner's own text | A prototype session export `references/prototype-exports/ai-jobs-and-next-generation-session-export.json` that holds a third party's full article text (Microsoft blog). `AGENTS.md` (dozens of lines about "the owner", his subscriptions, his phone, and `/Users/colemiller/.claude/bin/sm-gh`), `docs/design/*` ("Cole's answers", a script for his recorded greeting), `docs/legal/attorney-questions.md`, `docs/growth/invite-beta-plan.md`, `docs/launch/app-store-submission.md`. |
| Issues that mention a diagnostics export | 15 issues and 9 comments mention a diagnostics export by name. The one read (#1337) says the full export was not pasted; the rest were not read. |
| VPS details | No host, IP or SSH target in the tree. The unit files and `ops/dial/` name paths (`/opt/sm-dial`, `/etc/sm-dial`, `/etc/smserver/maps.env`) and the production domain `spokenmargins.proximitytoprogress.com` (78 mentions), which the shipped app's terms already carry. The relay URL and token are read from files on the VPS, not in the repo. |
| Terms contact | `resists.fabric-0o@icloud.com`, a relay address already shown in the app. |
| Third-party content in fixtures | `Contracts/fixtures/` and `docs/sharing-test-kit/` hold real feed responses and article text (about 5,000 `mzstatic.com` artwork URLs, Substack and podcast feeds). Their terms are not checked. |
| Licenses of bundled models | Kitten TTS (Apache-2.0), the CMU lexicon, misaki, and ONNX Runtime (MIT) have notices in the tree. **Supertonic's model is OpenRAIL-M** (`App/SpokenMarginsApp/Resources/Supertonic/licenses/SUPERTONIC_MODEL_OPENRAIL-M.txt`), whose use restrictions must travel with a redistributed copy; since #1820 Supertonic's model files are a download and not in the tree, so only Kitten's `.onnx` (Apache-2.0) is tracked and a public repo redistributes no Supertonic model. `docs/design/first-run.md` already lists whether the in-app wording is enough as a legal question. The repo has no `LICENSE` file, so a public repo would be "all rights reserved" by default. |
| Past Actions run logs | Become public with the repo. **Not checked.** They hold the same paths as the lane reports. |

### What flipping this repo public would mean

- It exposes all 785 branches, 17 tags, every issue and every comment, not only `next`. The provisioning profiles and device identifiers stay reachable in history unless history is rewritten.
- Rewriting history (`git filter-repo` on `artifacts/`) changes every commit hash. Lane reports, audit comments (`Claude audit on <sha7>`), `Closes` links, `testflight/*` tags and the merge-audit rule all name hashes. Open PR branches would have to be rebased by hand.
- **Self-hosted runners and fork PRs.** On a public repo anyone can open a fork PR. `lane.yml` and `shipped-build-compat.yml` already skip fork PRs (`head.repo.full_name == github.repository`). At the time of writing, `linux-t1.yml` and `merge-audit.yml` did not, and `linux-t1` would have run a stranger's code on the VPS. Since #2442 `linux-t1.yml` is gone and only the two `lane-open-*` jobs still run on `sm-vps`, each behind the same-repo guard. Before going public: set "Require approval for all outside collaborators" for fork PR workflows. A change to `.github/` is the owner's tap.

### What public runners would and wouldn't replace

Whether GitHub's free hosted runners for public repos include enough macOS capacity and an Xcode that builds the iOS 26 SDK was **not checked**.

| Job today | On a public hosted runner |
|---|---|
| `linux-t1` (VPS), `merge-audit`, `route`, `lane-open-*` | Replaced with no loss. These are plain Linux jobs that moved to the VPS only because the free minutes ran out on 2026-10-07 (#1023). Done in #2442 for all but the two `lane-open-*` jobs, which share a ping-limit state file and stay on `sm-vps`. |
| Host tests (`--plan fast`) and the app build for the simulator and device | Likely, on a hosted macOS runner: no simulator audio, no owner machine. Slower than the Mac and with no warm build cache. |
| T3 app-hosted tests and the integration run (`--plan app`) | Possible on a hosted macOS runner's simulator, but the lane's one-simulator rules and its audio-device handling (#1556) were built around the owner's Mac. |
| T4 and T5 journeys (iOS simulator tool), the phone build, the owner's phone check, signing, TestFlight upload | Not replaceable. They need the owner's Mac, his login keychain and his phone. |
| The usage breaker, the Dial, the Mac tick, disk relief, keep-awake | Not Actions jobs at all. Unaffected. |

### The owner's answer (2026-10-14)

Not now. The repo stays private until Solid Ground ships and the owner gives an explicit go. Licence questions have to be settled first (the missing `LICENSE`, Supertonic's OpenRAIL-M terms, third-party fixture content). Nothing on this page is a decision to go public.

Still open for when he gives the go: whether the public copy is a new repo from a cleaned snapshot of `next` (no history, no issues, every hash here stays valid, this repo stays the private working one) or this repo flipped after its history is rewritten (every hash changes and the issue and comment history goes public).
