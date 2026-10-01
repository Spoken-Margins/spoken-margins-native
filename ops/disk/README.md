# Disk relief

`sm_disk_relief.py` keeps the Mac from running out of room for builds. Every 15 minutes it checks free space on `/System/Volumes/Data`. Below **35 GiB**, and only while `/Volumes/SlawBulk` is plugged in, it frees space in this order and stops as soon as free space reaches **60 GiB**:

1. **Build caches in idle worktrees** of this repo: `.build/dd`, `.build/verification` (everything in `.build/` except lock files) and `Packages/SessionKit/.build`. They rebuild on the next build. A worktree is idle when no process works inside it, no `xcodebuild`, `swift-build` or `verify-tests` command names it, no live agent holds its worktree lock, and the cache hasn't changed for 30 minutes.
2. **Old iOS DeviceSupport folders.** It keeps the newest one and the one with the highest iOS version.
3. **Moves to the external drives.** It moves `artifacts/` folders in the main checkout untouched for 2 days, older phone builds (never `latest`, the installed one, or the newest two), and Claude and Codex session logs untouched for 3 days. Each goes to `/Volumes/SlawBulk/Codex-Offload/<date>-disk-relief/<path under your home folder>`, plus a second copy on the separate mirror disk at `/Volumes/SlawArchiveMirror/Current/SlawBulk/...`. Each copy is written under a `.partial` name and checked by size and file count. The original is deleted only after both copies match and the original hasn't changed. Without the mirror disk, moves are skipped. A `MANIFEST.txt` on each drive lists every move. Moved artifacts and phone builds also get a `MOVED-TO-SLAWBULK.txt` note in their old folder.

It never touches the self-hosted runner folders, `~/.codex/worktrees`, simulators (CoreSimulator), app data, or the external drives' existing files. It never removes a worktree. Instead it lists stale ones (clean, already in `origin/next`, and not a standing checkout) for you to remove.

Every action, with the bytes freed, goes to `~/SpokenMarginsOps/disk-relief/log.txt`. You get a notification only when it did something. A lock file stops two runs from overlapping.

## Check what it would do

```zsh
python3 ~/Documents/GitHub/spoken-margins-native/ops/disk/sm_disk_relief.py --dry-run
```

It lists every item in order with sizes and a running total, and changes nothing. With plenty of room free, it shows the order it would take starting from 35 GiB. Add `--free-gib 30` to pretend a number.

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
