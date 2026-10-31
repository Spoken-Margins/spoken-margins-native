# Private ops separation plan (#1390)

Plan only, written 2026-10-16. Nothing here has moved yet: no file, no launchd job, no runner, no VPS unit. The live ops copy on the Mac (`~/SpokenMarginsOps/repo`) pulls `next` every 10 minutes, so files leave this repo only after each job already runs from its new home (step 5 below).

Related: #1381 (open-source plan), #1383 (public audit), #1385 (repo topology: one repo), #1388 (app snapshot), #1389 (hosted CI), #1719 (self-hosted runner gaps), `docs/scheduled-jobs.md` (every scheduled job and where it lives).

## In short

1. **Mechanism: a private companion repo, `spoken-margins-ops`, checked out next to the public one.** Owner automation (agent workers, the audit, the Dial, the Mac monitors, phone builds, signing and upload) lives there with its own history and reviews. It finds the public checkout through one setting (`SM_REPO`), so neither repo hard-codes the other's path.
2. **The public repo keeps everything a contributor needs** to build, test and run the app: the app, SessionKit, contracts, validators, the product server's source, and portable examples of the dev tooling with no owner paths or hostnames.
3. **The switch is job by job.** Each job is copied, re-pointed and checked in the private repo while the old copy keeps running; only then does a public PR delete the old files.
4. **Every automation that reads GitHub text gets an author filter** before the repo is public. Today only the lane runner has one in review (#1797); the audit, the Dial, the integration run, the phone build, the Mac worker and the cloud routines have none.

## 1. Inventory

Buckets:

- **Public**: stays in the public repo as it is.
- **Example**: stays public, but as a portable example. Owner paths, hostnames, disk names and accounts move into a config file or environment variable whose real values live in the private repo.
- **Private**: moves to the private repo (or is deleted if it is already retired).

"Outside" rows already live outside this repo; they are listed so the plan covers them.

### `ops/`

| Path | What it is | Bucket | Why |
|---|---|---|---|
| `ops/audio-loopback/` | Audio loopback harness for host and hosted CI audio tests | Public | No owner values; a contributor can run it. |
| `ops/claude/` (worker + plist) | Claude Mac worker: takes `ready` issues and stalled PRs with a full-tool headless agent | Private | Agent automation with Bash and Edit rights on the owner's Mac and account. |
| `ops/codex/sm_codex_audit.py`, `codex_limits.py`, audit plist, README | The merge-gating audit (headless Claude, read-only) | Private | Owner's account posts the verdict; the runner trusts it. |
| `ops/dial/` (gate, deploy.sh, systemd units) | The Dial: paces threads from #589, deploys to the VPS | Private | Owner pacing, owner VPS. |
| `ops/disk/` (disk relief, lane prune, plist) | Frees disk; moves artifacts to `SlawBulk` | Private | Names the owner's external drives and home layout. |
| `ops/lane/sm_lane_power_guard.py` + plist | Pauses runner services on battery or lid closed | Private | The owner's Mac and runner service names. |
| `ops/lane/sm_lane_open.py` | Pings the Dial relay when a runner is idle | Private | Uses the relay URL and token secrets. |
| `ops/lane/sm_lane_stall.py` | Lane stall detection | Example | Goes with the lane (see `scripts/` lane row). |
| `ops/ledger/` | Claude and Codex plan usage reports | Private | The owner's subscriptions and session logs. |
| `ops/power/` (Amphetamine, keep-awake plist) | Keeps the Mac awake for builds | Private | The owner's Mac and apps. |
| `ops/testdesk/` (integration run, revert, plist) | Integration run on `next`'s tip; reverts a culprit | Private | Acts with the owner's account (reverts, labels). |
| `ops/runner-guard/` (PR #1791, not merged) | Job-started hook that refuses fork jobs | Example | Useful to any self-hosted runner; holds no secrets. |

### `scripts/`

| Path | What it is | Bucket | Why |
|---|---|---|---|
| `verify-tests.py`, `run-sessionkit-tests.sh`, `run-sessionkit-linux-tests.sh`, `sessionkit_pass.py`, `test-scope.py`, `test_inventory.py`, `research_tests.py` | Host test plans | Public | What a contributor runs. |
| `validate-*.py`, `check-*.sh`/`.cjs`/`.py`, `verify-bundle.py`, `flow-map-check.py`, `hot_file_ratchet.py`, `split_move.py`, `audit-gate1-readiness.py`, `verify-gate*.sh` | Validators and checks | Public | No owner values. |
| `build29-db-reader`, `check-build29-database.sh`, `freeze-shipped-reader.sh`, `generate-prior-build-fixture.py` | Shipped-build database compatibility | Public | Protects every user's data; contributors need it. |
| `normalize-embedded-framework-minimum-os.sh`, `remove-embedded-static-onnxruntime.sh` | Build phases | Public | Part of the app build. |
| `bootstrap-python-tools.sh`, `setup-worktree.sh` | Dev setup | Example | `setup-worktree.sh` links the main checkout's `.venv`; a fresh clone needs a bootstrap path that doesn't assume one. |
| `xcodebuild-lane`, `lane-sim-boot`, `host-test-lane`, `smoke-simulator.sh`, `host_audio.py` | Build slots and simulator guard | Example | Built for one shared Mac; useful to anyone running many agents, harmless for one person. |
| `lane-runner.py`, `lane_*.py`, `integration-precheck.py`, `merge_audit.py`, `install-lane-guard.py` + `scripts/tests/test_lane_*` | The self-hosted test lane | Example until #1389, then decide | `lane.yml` runs this from the PR's merge commit, so it can't leave the public repo while the self-hosted lane is live. After hosted CI takes routine runs (#1389) it either retires or moves private. |
| `phone-build`, `com.spokenmargins.phone-build.plist`, `install-phone-build.command` | Rolling phone build for the owner's phone | Private | Signs with the owner's identity, writes to his home folder. |
| `daily-phone-plan` + plist | Daily owner test plan | Private | Owner workflow; calls Claude on his account. |
| `sm_status.py`, `sm_sweep.py`, `sm_project_sync.py`, `desk-batch.py` | Coordinator status, sweeps, board sync, Test Desk batching | Private | Owner coordination on his account and project board. |
| `TestFlightUploadOptions.plist` | Upload export options with the team ID | Private | Upload is the owner's act; a public copy invites a fork to try it. The team ID itself is not secret (it is in every signed binary). |
| `deploy-spoken-margins-site.sh` | Deploys the product website | Example | Already reads the host from `SPOKEN_MARGINS_VPS_REMOTE`; the default `root@ptp` alias moves to private config (PR #1800 covers part). |
| `run-podcast-anchor-benchmark.sh`, `fixtures/` | Benchmarks and fixtures | Public | Check `fixtures/sm_sweep/` goes private with `sm_sweep.py`. |

### Repo root, config and docs

| Path | Bucket | Why |
|---|---|---|
| `project.yml` `DEVELOPMENT_TEAM` (5 targets) | Example | Done (#1841): every target reads the team from the untracked `Config/Local.xcconfig` through `Config/Signing.xcconfig`; `Config/Local.xcconfig.example` shows the line. A simulator build needs no team; a device build needs the contributor's own. |
| `Config/ExportOptions-*.plist` | Example | Same team ID; keep as examples with a placeholder. |
| `App/.../SpokenMarginsApp.entitlements` associated domain | Public | Product domain, already shipped in the app. |
| `research/B4/server/`, `contracts/`, `DESIGN.md`, `scripts/demo.sh` | Public | Product backend source. Public source makes the privacy claims checkable. |
| `research/B4/deploy/` (deploy.sh, remote-install.sh, units, Caddy) | Example | Deploy recipe for the product server; the real host, keys and env files stay private. |
| `.github/workflows/lane.yml`, `linux-t1.yml`, `shipped-build-compat.yml`, `merge-audit.yml` | Example until #1389 | Name the owner's self-hosted runner labels. Hosted workflows (PR #1793) replace them for routine runs; the owner's merge tap. |
| `.github/ISSUE_TEMPLATE/agent-task.md` | Example | Rewrite as a contributor template; agent task text is an injection surface (section 3). |
| `.claude/skills/lane-request/` | Example until #1389 | Tied to the self-hosted lane. |
| `.claude/skills/journey/` | Example | Portable agent-driven journey instructions; drop the owner's Test Desk session name. |
| `AGENTS.md` | Example | Done as a public split (#3033, owner 2026-10-30): the guide keeps the rules that change behaviour, and the dated standing calls moved verbatim to `docs/decisions.md`. The private overlay of #1854 (PR #2946) was the other option; it stays open for the lead to close or rebase. |
| `docs/scheduled-jobs.md`, `docs/workstreams/` (dispatch, kickoff, daily-phone-plan, test-lane) | Private | Describe owner automation. Keep a short public `docs/contributing/automation.md` that says private automation exists and is optional. |
| `docs/legal/attorney-questions.md`, `docs/growth/`, `docs/launch/` | Private | #1383 lists these as the owner's own text. |

### Outside this repo (already private; listed for completeness)

| Item | Where | Bucket |
|---|---|---|
| `~/.claude/bin/sm-gh`, user hooks (lane guard, token hook), Claude settings | Owner's Mac | Outside |
| Mac tick, Mac finisher, Test Desk, scheduled tasks | Owner's Mac, Claude Code | Outside |
| Project routines: hourly dispatch, daily triage, Dial relay | Owner's Claude project | Outside |
| Runner registrations `sm-lane-mac*`, `sm-vps`, `sm-vps-t1`; repo secrets `SM_LANE_OPEN_URL`, `SM_LANE_OPEN_TOKEN` | GitHub, Mac, VPS | Outside |
| Signing identity, App Store Connect login, provisioning | Owner's login keychain | Outside |
| `/etc/smserver/maps.env` (API key), `/etc/sm-dial`, VPS SSH keys | VPS | Outside |

**Counts** (rows above): Public 8, Example 14, Private 17 (2 of them deleted rather than moved), Outside 6.

## 2. Mechanism

### Picked: a private companion repo next to the public one

- A private GitHub repo `spoken-margins-ops`, with history carried over by `git filter-repo --path` of the private paths, so blame and past fixes survive.
- On the Mac: `~/SpokenMarginsOps/ops` (private) next to `~/SpokenMarginsOps/repo` (public, unchanged). On the VPS: the Dial deploys from the private repo, as it now deploys from this one.
- Each private script reads `SM_REPO` (default: the sibling `repo` folder) for the public checkout, and `SM_OPS_HOME` for its state folders. State folders (`~/SpokenMarginsOps/<job>/`, locks, logs) don't move.
- Plists become templates rendered by a small installer (`install-launchd.py`) that fills in `$HOME`, so no plist carries `/Users/colemiller` (#1383's open item).
- The private repo's own tests (the `test_*.py` beside each script) run on the Mac before a push, or on a runner registered to the private repo. Private-repo Actions minutes ran out on 2026-10-07 (#1023), so hosted minutes are not the plan.

### Alternatives

| Option | Cost |
|---|---|
| 1. Private companion repo (picked) | One more repo to pull; scripts need `SM_REPO`. Cross-repo changes (a lane change plus its ops change) are two PRs. |
| 2. Git submodule in the public repo | Outsiders can't fetch it, so `--recursive` clones fail; every ops change needs a pointer-bump commit in the public repo; the pointer names the private repo. |
| 3. Untracked overlay folder on the Mac | No history, no review, no tests in CI, easy to lose. Earlier agents have lost the owner's data; this repeats that risk. |
| 4. Keep it all public, scrubbed | Cheapest today. Publishes the agent prompts, the audit's merge rules and the Dial's pacing, which tells an attacker exactly what text to write. #1390's "Done when" asks for these to be private. |

What would show the pick is wrong: if most ops changes over a month need a matching public change (two PRs each time), the split is in the wrong place, and the lane should move private together with its callers.

**History note.** #1385 keeps one repo, and the #1383 hand-over recommends flipping this repo public without a history rewrite. In that case everything in ops/ up to the flip stays readable in public history. The move protects later changes only. That is acceptable: nothing secret was found in it (#1383), but say so plainly rather than claim the history is private.

## 3. GitHub text is untrusted

Once the repo is public, anyone can file an issue, comment, or open a fork PR. These automations read that text and act on it:

| Automation | Reads | Can do | Guard today | Needed before public |
|---|---|---|---|---|
| Lane runner (`lane-runner.py` via `lane.yml`) | PR comments (`/lane` requests, lane reports), labels | Runs tests on the Mac, lifts the T3 hold, merges | Same-repo PRs only; a maintainer adds the label | PR #1797: trust only OWNER, MEMBER, COLLABORATOR and `github-actions[bot]` comments |
| `linux-t1.yml`, `lane.yml` lane-open jobs | PR code | Runs a PR's code on the VPS | `linux-t1` has no fork guard | PR #1791: same-repo guard plus the runner-side job-started hook (not installed). Owner's merge tap. |
| `merge-audit.yml` | Pushes to `next` | Labels | Only writers can push | None |
| Audit (`sm_codex_audit.py`) | PR title, description, diff, comments | Posts the verdict that lets audio, persistence, packet and lane PRs merge | Read-only tools, `dontAsk` | Audit only same-repo PRs by collaborators; quote PR text inside a marked data block; never let text in the PR set the verdict wording. |
| Claude Mac worker (`sm_claude_worker.py`, not live) | `ready` issue body, PR comments, hand-off notes | Full agent: Bash, Edit, Write, opens and arms PRs | Only labelled issues; budget and turn caps | Take only issues opened by, or labelled `ready` by, the owner or a collaborator (check the label event's actor); trust hand-off notes only from its own account. |
| Codex worker | `ready` issues | Workspace-write agent | Deleted (#1853) | Unloaded 2026-10-17. |
| Integration run (`sm_integration_run.py`) | Merged code, comments on #184 | Reverts a culprit, removes `automerge` | Merged code is already reviewed; Claude is read-only | Same author filter on #184 comments. |
| Dial gate (`dial_gate.py`) | #589 boxes, #337 tick, claim and stop notes on any issue | Sets how many threads run, fires the relay | None | Author filter on comments; a stranger's fake claim note or tick changes pacing. |
| Phone build (`scripts/phone-build`) | Integration reports on #184 | Builds sooner | None | Author filter. |
| Daily phone plan | Merged PRs and issues | Writes the owner's test plan (Claude, no tools) | No tools | Only merged PRs and owner or collaborator issues, so a stranger can't put a step on his phone plan. |
| Board sync, sweep, status | Issues and labels | Board fields, labels | None | Low risk; same author filter for any comment it parses. |
| Cloud daily triage routine | Every new issue | Adds `ready`, starts threads | None | **The widest door.** An outside issue gets `needs-triage-review`, never `ready`, until the owner or the coordinator reads it. Thread prompts quote issue text as data. |
| Hourly dispatch routine | Lane reports, audits, `automerge` PRs | Labels, comments, thread starts | None | Same author filter as the lane. |
| Mac finisher, Test Desk | `needs-mac` PRs, T4/T5 lane requests (journey scenario text) | Commits to PR branches; drives the simulator | None | Act only on requests from collaborators; scenario text is data. |

Rule for all of them: GitHub's `author_association` decides who is trusted, not anything the text says about itself. Before the flip, set "Require approval for all outside collaborators" for fork PR workflows (`docs/scheduled-jobs.md`).

## 4. A clean public checkout without the private services

What a contributor gets with nothing private running: no runners, no Dial, no audit, no VPS, no owner hooks.

1. Clone, then `scripts/bootstrap-python-tools.sh`.
2. Host tests: `swift test` in `Packages/SessionKit`, then `.venv/bin/python scripts/verify-tests.py --plan fast`.
3. Simulator build: plain `xcodebuild ... -destination 'generic/platform=iOS Simulator' build-for-testing` (the raw-`xcodebuild` block is an owner hook, not part of the repo). No team needed.
4. Device build: the contributor's own `DEVELOPMENT_TEAM` in `Config/Local.xcconfig`.
5. Local listening, capture and export: import an article and a PDF, play with Kitten (bundled) or an iOS voice, record a spoken and a written Margin, export a `.spokenmargins` packet and import it on a second simulator. None of this should need the product server; the check below is what proves it.

How to prove it, not just claim it: the hosted workflows in PR #1793 (Linux SessionKit, macOS app build) run on GitHub's machines with none of the owner's services. Add one agent-driven journey run of step 5 with the product server's host blocked, and record the result on #1390. Until both are done, the status is `implemented`, not `verified`.

Not yet checked: whether every Library path stays offline-safe when the server is unreachable (share-link creation and map lookups should fail with a message, never block playback). The journey above is the check.

## 5. Personal dev infrastructure vs product backend

They share one VPS today, so it is worth naming which is which.

| | Personal dev infrastructure | Product backend |
|---|---|---|
| What | Runners (`sm-lane-mac*`, `sm-vps`, `sm-vps-t1`), the Dial, Mac jobs, usage ledger, routines, Test Desk | `smserver` (share links, Listening Maps, attestation, anonymous tokens), the website, Caddy |
| Who it serves | The owner's agents | Listeners |
| Source | Private repo | Public repo (`research/B4/`) |
| Deploy values | Private | Private (host, SSH key, `maps.env`) |
| If it stops | Development slows | Optional features stop; local listening, capture and export keep working |
| Public gate | None | Share links, maps and a public App Store release wait for the attorney (owner, 2026-10-16) |

Keep them on separate system users and units as now (`smserver`, `smt1`, the Dial's own user). If the VPS is ever split, the product server moves first: a runner compromise shouldn't reach listener data.

## 6. Order of steps

Each step is its own PR or owner action. Only step 1 deletes files from this repo, and they were dead jobs.

1. **Retire the dead jobs** (no move needed). Done: the owner unloaded the Codex worker and the release cut was not loaded (2026-10-17), and #1853 deleted both jobs' files.
2. **Make the private scripts location-independent while they are still here:** `SM_REPO` and `SM_OPS_HOME`, plist templates and `install-launchd.py`. Behaviour stays the same, so the 10-minute pull keeps working.
   - Done (#1844): `scripts/sm_paths.py` (and `sm_paths.sh` for shell scripts) gives `repo()` and `ops_home()`. The scripts in `ops/` (except the retired Codex worker and release cut, and the public audio loopback), `phone-build`, `daily-phone-plan` and `sm_status.py` use it; `sm_sweep.py` reaches the checkout through `sm_status`. `scripts/tests/test_sm_paths.py` pins both the defaults and the settings.
   - Limits: `ops/power/amph` (AppleScript, untested off the Mac) still writes its hold file under `~/SpokenMarginsOps`, and the integration run's evidence still lands in `artifacts/` of the checkout, so they ignore `SM_OPS_HOME`.
   - Still open: plist templates and `install-launchd.py` (#1843).
3. **Add the author filters** in section 3 (PR #1797 for the lane; one PR each for the audit, Dial, integration run, phone build and worker). The routine changes are the owner's or the coordinator's.
4. **Create `spoken-margins-ops`** (owner's account, owner's tap), carry history over with `git filter-repo`, clone it to `~/SpokenMarginsOps/ops`, and extend the existing 10-minute pull to it.
5. **Switch jobs one at a time,** lowest risk first: ledger (no job), disk relief, keep-awake, power guard, Dial on the VPS, integration run, phone build and daily plan, and last the audit. For each: render the new plist, `launchctl bootout` the old label, `bootstrap` the new one, and confirm one normal tick in its log before the next. Interval jobs miss at most one tick. The audit goes last and is confirmed by a real audit comment on a real PR, because merges wait on it.
6. **After every job has run from the private copy for two days,** one public PR removes the moved files and adds `docs/contributing/automation.md`.
7. **Split `AGENTS.md`** into the public guide and the private overlay (owner's yes first).
8. **Runners stay registered** until the hosted CI cutover (#1389). Unregistering them, or shutting any service down, is a separate owner decision (#1390 "Must not change").

## Needs the owner

1. Creating the private `spoken-margins-ops` repo on his account (step 4).
2. ~~Unloading the retired jobs on the Mac (step 1).~~ Done 2026-10-17.
3. The merge taps for #1791 and anything else touching `.github/` or `scripts/lane-runner.py`.
4. A yes to splitting `AGENTS.md` (step 7).
5. The cloud routine changes (triage never marks an outside issue `ready`) are in his project instructions.
