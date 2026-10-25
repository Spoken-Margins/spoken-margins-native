#!/bin/bash
# Pack and unpack Xcode's compilation cache for the Actions cache (#2617).
#
#   CAS=<store> PACK=<folder> scripts/ci-cas-cache.sh pack     before actions/cache/save of $PACK
#   CAS=<store> PACK=<folder> scripts/ci-cas-cache.sh unpack   after actions/cache/restore of $PACK
#
# Why not cache $CAS itself: its data files are sparse (mapped at a size far beyond what they hold), and
# actions/cache archives with plain tar, which writes every hole out as zeros. The 481 MB archive of a store
# expanded until gtar filled the runner's 36 GB disk, before the build began. Here the store is archived with
# GNU tar --sparse, so the holes stay holes and the restore costs what the store really uses.
#
# Both modes always exit 0: a store that can't be packed or unpacked costs a cold build, never a red check.
# What they refuse, each with a line in the step summary:
#   pack    a store that uses more than CAS_MAX_KB on disk (Xcode is told to hold it near 1 GB);
#   unpack  an extraction that takes the volume below CAS_MIN_FREE_KB free, watched every CAS_POLL seconds
#           (the extraction is stopped and the half-written store deleted), and a store that comes out larger
#           than CAS_MAX_KB.
set -u
set -o pipefail

MODE="${1:?usage: ci-cas-cache.sh pack|unpack}"
: "${CAS:?CAS is the compilation cache folder}" "${PACK:?PACK is the folder the Actions cache holds}"
TAR="${TAR:-gtar}"
MAX_KB="${CAS_MAX_KB:-4194304}"
MIN_FREE_KB="${CAS_MIN_FREE_KB:-6291456}"
POLL="${CAS_POLL:-1}"
ARCHIVE="$PACK/cas.tar.zst"

note() {
  echo "$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >> "$GITHUB_STEP_SUMMARY"; fi
  return 0
}

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; fi
  return 0
}

warn() {
  echo "::warning title=Compilation cache::$*"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "Compilation cache: $*" >> "$GITHUB_STEP_SUMMARY"; fi
  return 0
}

mb() { echo $(( $1 / 1024 )); }

free_kb() { df -kP "$1" | tail -1 | awk '{print $4}'; }

disk_kb() { du -sk "$1" | awk '{print $1}'; }

pack() {
  rm -rf "$PACK"
  if [ ! -d "$CAS" ]; then
    note "Compilation cache not saved: the build left no store."
    output "ok=false"
    return 0
  fi
  used=$(disk_kb "$CAS")
  if [ "$used" -gt "$MAX_KB" ]; then
    note "Compilation cache not saved: the store uses $(mb "$used") MB on disk, over the $(mb "$MAX_KB") MB limit."
    output "ok=false"
    return 0
  fi
  mkdir -p "$PACK"
  if "$TAR" --sparse -C "$(dirname "$CAS")" -cf - "$(basename "$CAS")" | zstd -T0 -3 -q -o "$ARCHIVE"; then
    size=$(( $(wc -c < "$ARCHIVE") / 1048576 ))
    note "Compilation cache saved: $(mb "$used") MB on disk, $size MB archived."
    output "ok=true"
  else
    rm -rf "$PACK"
    note "Compilation cache not saved: packing the store failed."
    output "ok=false"
  fi
  return 0
}

unpack() {
  if [ ! -f "$ARCHIVE" ]; then
    note "Compilation cache: nothing saved to restore, so this build starts cold."
    return 0
  fi
  rm -rf "$CAS"
  mkdir -p "$(dirname "$CAS")"
  "$TAR" -xf "$ARCHIVE" --use-compress-program=unzstd -C "$(dirname "$CAS")" &
  pid=$!
  stopped=0
  while kill -0 "$pid" 2>/dev/null; do
    free=$(free_kb "$PACK")
    if [ "$free" -lt "$MIN_FREE_KB" ]; then
      stopped=1
      kill "$pid" 2>/dev/null
      break
    fi
    sleep "$POLL"
  done
  wait "$pid" 2>/dev/null
  status=$?
  rm -rf "$PACK"
  if [ "$stopped" -eq 1 ]; then
    rm -rf "$CAS"
    warn "Restore abandoned: it would have left under $(mb "$MIN_FREE_KB") MB of disk free. This build starts cold."
  elif [ "$status" -ne 0 ]; then
    rm -rf "$CAS"
    warn "Restore failed (tar exit $status). This build starts cold."
  else
    used=$(disk_kb "$CAS")
    if [ "$used" -gt "$MAX_KB" ]; then
      rm -rf "$CAS"
      warn "Restored store uses $(mb "$used") MB on disk, over the $(mb "$MAX_KB") MB limit; deleted. This build starts cold."
    else
      note "Compilation cache restored: $(mb "$used") MB on disk."
    fi
  fi
  return 0
}

case "$MODE" in
  pack) pack ;;
  unpack) unpack ;;
  *) echo "usage: ci-cas-cache.sh pack|unpack" >&2; exit 2 ;;
esac
exit 0
