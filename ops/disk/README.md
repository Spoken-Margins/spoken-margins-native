# Disk relief

`sm_disk_relief.py` keeps the Mac from running out of room for builds. Every 15 minutes it checks free space on `/System/Volumes/Data`. Below **50 GiB** it frees space in this order and stops as soon as free space reaches **70 GiB**. One app build takes 8 to 9 GiB, so it starts well before builds run out of room. Steps 1 to 5 only delete things that rebuild or are finished, so they run whether or not the external drive is plugged in. Only step 6 needs the drives.

1. **Finished worktrees**, removed whole with `git worktree remove` (never `--force`, so git itself refuses a worktree with changes, untracked files or a lock). A worktree qualifies only when all of these hold:
   - it sits in a checkout's `.claude/worktrees/` folder (worktrees elsewhere, such as `~/SpokenMarginsOps`, are only listed);
   - it is clean and its HEAD is already in `origin/next`;
   - it is idle as in step 2, and no live Claude Code session has its working folder there;
   - nothing in it changed in the last 24 hours;
   - its ignored files are all ones that rebuild: `.build` and `.swiftpm` folders, `__pycache__`, `.DS_Store`, the `.venv` and `node_modules` links, and `.claude/settings.local.json`. A worktree holding `artifacts/` or anything else ignored is kept and listed.

   The branch stays; only the folder goes.
2. **Build caches in idle worktrees** of this repo: `.build/dd`, `.build/verification` (everything in `.build/` except lock files) and `Packages/SessionKit/.build`. They rebuild on the next build. A worktree is idle when no process works inside it, no `xcodebuild`, `swift-build` or `verify-tests` command names it, no live agent holds its worktree lock, and the cache hasn't changed for 30 minutes.
3. **Scratch folders of Claude Code sessions that ended**, in `/private/tmp/claude-<uid>/<project>/<session id>/` (each session's `scratchpad/`, `tasks/` and so on). They're deleted, not moved. A session counts as ended only when all of these hold:
   - it isn't in Claude Code's list of running sessions (`~/.claude/sessions/<pid>.json` with a live pid; read only);
   - no running process names its session id;
   - no process has a file, folder or working directory open inside it (`lsof` for your user; if `lsof` fails, nothing counts as ended);
   - nothing in it changed in the last 12 hours;
   - it isn't the session running the job.

   Each folder is checked again just before it's deleted. Other files in `/private/tmp/claude-<uid>/` are left alone.
4. **Ad-hoc test folders in `/private/tmp`** named `spoken-margins-*`, your own, when no process works in or holds a file open in them and nothing in them changed for 12 hours. A Test Desk copy there held 4.2 GiB on 2026-10-09.
5. **Old iOS DeviceSupport folders.** It keeps the newest one and the one with the highest iOS version.
6. **Moves to the external drives.** It moves `artifacts/` folders in the main checkout untouched for 2 days, older phone builds (never `latest`, the installed one, or the newest two), and Claude and Codex session logs untouched for 3 days. Each goes to `/Volumes/SlawBulk/Codex-Offload/<date>-disk-relief/<path under your home folder>`, plus a second copy on the separate mirror disk at `/Volumes/SlawArchiveMirror/Current/SlawBulk/...`. Each copy is written under a `.partial` name and checked by size and file count. The original is deleted only after both copies match and the original hasn't changed. Without SlawBulk or the mirror disk, moves are skipped and the other steps still run. A `MANIFEST.txt` on each drive lists every move. Moved artifacts and phone builds also get a `MOVED-TO-SLAWBULK.txt` note in their old folder.

It never touches the self-hosted runner folders, `~/.codex/worktrees`, simulators (CoreSimulator), app data, or the external drives' existing files. It never removes a standing checkout (the main one, `-test-desk`, `-finisher` and the other `spoken-margins-native*` folders). Stale worktrees it may not remove are listed in the log with the reason, for you to remove.

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
cp ~/Documents/GitHub/spoken-margins-native/ops/disk/com.spokenmargins.disk-relief.plist ~/Library/LaunchAgents/
```

```zsh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.disk-relief.plist
```

To turn it off:

```zsh
launchctl bootout gui/$(id -u)/com.spokenmargins.disk-relief
```

```zsh
rm ~/Library/LaunchAgents/com.spokenmargins.disk-relief.plist
```

## When free space looks stuck

A Time Machine local snapshot can keep deleted files on disk, so free space doesn't rise. The routine counts what it cleared and stops at the target by that count, so it doesn't clear everything chasing a number that won't move. The log and notification say when this happens. `tmutil listlocalsnapshots /` shows the snapshots. Deleting one is your call; the routine never does it.

## Tests

```zsh
python3 -m unittest ops/disk/test_sm_disk_relief.py
```

The tests use temporary folders and the real `rsync` only.
