# Disk relief

`sm_disk_relief.py` keeps the Mac from running out of room for builds. Every 15 minutes it checks free space on `/System/Volumes/Data`. Below **50 GiB** it frees space in this order and stops as soon as free space reaches **70 GiB**. One app build takes 8 to 9 GiB, so it starts well before builds run out of room. Steps 1 to 5 only delete things that rebuild or are finished, so they run whether or not the external drive is plugged in. Only step 6 needs the drives.

1. **Finished worktrees**, removed whole with `git worktree remove` (never `--force`, so git itself refuses a worktree with changes, untracked files or a lock). A worktree qualifies only when all of these hold:
   - it sits in a checkout's `.claude/worktrees/` folder or is a Codex worktree in `~/.codex/worktrees/<id>/` (or directly in `~/.codex/worktrees/`) (worktrees elsewhere, such as `~/SpokenMarginsOps`, are only listed). Codex worktrees follow the same rules as Claude's (owner, 2026-10-19), and the emptied `<id>/` folder goes too;
   - it is clean and its HEAD is already in `origin/main`;
   - it is idle as in step 2, and no live Claude Code session has its working folder there;
   - nothing in it changed in the last 24 hours;
   - its ignored files are all ones that rebuild: `.build` and `.swiftpm` folders, `__pycache__`, `.DS_Store`, the `.venv` and `node_modules` links, and `.claude/settings.local.json`. A worktree holding `artifacts/` or anything else ignored is kept and listed.

   The branch stays; only the folder goes.
2. **Build caches in idle worktrees** of this repo, Codex's included: `.build/dd`, `.build/verification` (everything in `.build/` except lock files) and `Packages/SessionKit/.build`. They rebuild on the next build. A worktree is idle when no process works inside it, no `xcodebuild`, `swift-build` or `verify-tests` command names it, no live agent holds its worktree lock, and the cache hasn't changed for 30 minutes.
   - **Worktrees under `~/Documents` keep these folders in `~/Library/Caches/SpokenMarginsBuilds/<slot>/`**, because this job can't read `~/Documents` (below). Their `.build` and `Packages/SessionKit/.build` are links to that slot's `root/` and `sessionkit/`; `scripts/xcodebuild-lane`, `verify-tests.py` and `setup-worktree.sh` make the links (`scripts/sm_build_cache.py`), and move an idle existing folder in. Only linked worktrees are linked: the main checkout and other clones keep their folders in place, because the daily phone-plan job runs the main checkout's prebuilt `Packages/SessionKit/.build/release/phone-plan`. The job empties an idle slot's folders and keeps the folders, so the links keep working. It skips a slot while `verify-tests` holds its `verification.lock`, and while a live agent holds its worktree's lock. A slot whose worktree no longer exists (the first line of its `owner.txt` names it) goes whole; a worktree macOS won't let it look at counts as still there. A new worktree made at a removed one's path finds a different folder identity on `owner.txt`'s second line and starts with the slot emptied, so it never builds against another branch's DerivedData.
3. **Scratch folders of Claude Code sessions that ended**, in `/private/tmp/claude-<uid>/<project>/<session id>/` (each session's `scratchpad/`, `tasks/` and so on). They're deleted, not moved. A session counts as ended only when all of these hold:
   - it isn't in Claude Code's list of running sessions (`~/.claude/sessions/<pid>.json` with a live pid; read only);
   - no running process names its session id;
   - no process has a file, folder or working directory open inside it (`lsof` for your user; if `lsof` fails, nothing counts as ended);
   - nothing in it changed in the last 12 hours;
   - it isn't the session running the job.

   Each folder is checked again just before it's deleted. Other files in `/private/tmp/claude-<uid>/` are left alone.
4. **Ad-hoc test folders in `/private/tmp`** named `spoken-margins-*`, your own, when no process works in or holds a file open in them and nothing in them changed for 12 hours. A Test Desk copy there held 4.2 GiB on 2026-10-09.
5. **Old iOS DeviceSupport folders.** It keeps the newest one and the one with the highest iOS version.
6. **Moves to the external drives.** It moves `artifacts/` folders in the main checkout untouched for 2 days, older phone builds (never `latest`, the installed one, or the newest two), and Claude and Codex session logs untouched for 3 days. Each goes to `/Volumes/SlawBulk/Codex-Offload/<date>-disk-relief/<path under your home folder>`. When the mirror disk happens to be mounted, a second copy goes to `/Volumes/SlawArchiveMirror/Current/SlawBulk/...`; it isn't required, because the mirror is for highly sensitive data and is stored away from the desk (owner, 2026-10-09). Each copy is written under a `.partial` name and checked by size and file count. The original is deleted only after every copy matches and the original hasn't changed. Without SlawBulk, moves are skipped and the other steps still run. Without Full Disk Access, macOS also reports SlawBulk as "not writable", so moves are skipped (see below). A `MANIFEST.txt` on each drive lists every move. Moved artifacts and phone builds also get a `MOVED-TO-SLAWBULK.txt` note in their old folder.

## Ready-made simulator builds (not in the order)

`~/SpokenMarginsOps/sim-builds` holds the integration run's last two simulator apps of `main`'s tip, about 690 MB each on 2026-10-18 (1.4 GB in all), for desks to install instead of building (`scripts/sim_builds.py`). It sits outside the relief order on purpose: it caps itself at two builds, copies nothing below 10 GB free, and deleting it only makes the next desk build for 5 to 10 minutes. Relief never touches it. By hand it is the first thing safe to delete, before step 1; the next integration run refills it.

## The lane folder (every run)

Before it looks at free space, every run also keeps `~/Library/Caches/SpokenMarginsLane` under **16 GiB** and ages out lane evidence, with `sm_lane_prune.py` (#1775). Free space doesn't decide: on 2026-10-16 the folder grew from 10 to 23 GB in a day while free disk fell from 73 to 31 GB, and nothing here was due to act. The rules and their reasons are under "Lane folder cap" in `docs/workstreams/test-lane.md`. In short:

- Lane evidence goes 7 days after it last changed, except the latest run of each open PR.
- Over the cap, idle warm builds go, oldest first, but never a cache a job holds and never the newest of each checkout. Warm builds of a checkout nothing on the Mac maps to go once idle.
- State files and `compilation-cache/` are never touched.
- `artifacts/lane/` is in `~/Documents`, which this job can't read, so its evidence is pruned when the lane runner or a Claude session runs `sm_lane_prune.py`. `--dry-run` lists what it would do.

A failure in this step is logged and never stops the rest of the run.

It never touches the self-hosted runner folders, simulators (CoreSimulator), app data, or the external drives' existing files. It never removes a standing checkout (the main one, `-test-desk`, `-finisher` and the other `spoken-margins-native*` folders). Stale worktrees it may not remove are listed in the log with the reason, for you to remove.

**No Full Disk Access (owner, 2026-10-14).** The job runs without Full Disk Access. Granting it to `python3` was tried, didn't take, and was reverted; don't ask the owner for it again. (The `/usr/bin/python3` in the privacy list only launches Xcode's own Python, and macOS checks that one.) Without it, macOS refuses the job `~/Documents` and the external drives. A folder it can't open is skipped with a `skip ...: macOS will not let this job read it` line in the log, and the other steps still run. Before 2026-10-14 one refused `.build` folder crashed every run from 10-11 on, before anything was freed. In practice this means step 1 does little from launchd for Claude worktrees (git needs the repository in `~/Documents`), and step 6 does little. Step 2 works: worktree build folders now live in `~/Library/Caches/SpokenMarginsBuilds`, and Codex worktrees sit in `~/.codex`, which the job can read. A worktree's old in-place `.build` moves to the cache folder on its next build; until then it stays where the job can't reach it. The Mac tick, a Claude session that can read `~/Documents`, clears worktree build caches when free disk drops under 20 GB, and it alerts when this job exits with an error.

Every action, with the bytes freed, goes to `~/SpokenMarginsOps/disk-relief/log.txt`. You get a notification only when it did something. A lock file stops two runs from overlapping.

## Check what it would do

```zsh
python3 ~/Documents/GitHub/spoken-margins-native/ops/disk/sm_disk_relief.py --dry-run
```

It lists every item in order with sizes and a running total, and changes nothing. With plenty of room free, it shows the order it would take starting from 50 GiB. Add `--free-gib 30` to pretend a number.

## Install

The PR doesn't install it. To turn it on:

```zsh
mkdir -p ~/SpokenMarginsOps/disk-relief
```

```zsh
/usr/bin/python3 ~/Documents/GitHub/spoken-margins-native/ops/install-launchd.py --install disk-relief
```

To turn it off:

```zsh
launchctl bootout gui/$(id -u)/com.spokenmargins.disk-relief
```

```zsh
rm ~/Library/LaunchAgents/com.spokenmargins.disk-relief.plist
```

## Time Machine local snapshots

A Time Machine local snapshot keeps deleted files on disk, so free space doesn't rise. On 2026-10-04 the routine cleared 17 GiB and free space didn't move.

- **Overnight clearing** (owner, 2026-10-09: "We can delete snapshots overnight"). Once a night, on the first run between 02:00 and 05:00, it deletes every local snapshot of the Mac's disk with `tmutil deletelocalsnapshots <date>`, whatever the free space. It skips a run while a backup is running, or when `tmutil status` can't be read, and tries again later in the window. Each deletion goes to the log, and `snapshots-cleared.txt` records the night. Backups on the Time Machine drive aren't touched. Excluding folders from Time Machine wouldn't help: a local snapshot holds the whole disk.
- **During the day** the routine counts what it cleared and stops at the target by that count, so it doesn't clear everything chasing a number that won't move. The log and notification say when space is held. `tmutil listlocalsnapshots /` shows the snapshots.

## Tests

```zsh
python3 -m unittest ops/disk/test_sm_disk_relief.py
```

The tests use temporary folders and the real `rsync` only. The lane folder rules have their own: `python3 -m unittest ops/disk/test_sm_lane_prune.py`.
