#!/bin/bash
# Makes sure a hosted Mac has the iOS 26 simulator runtime the app targets, before main-t3 and branch-t3 test on it
# (#5221). The hosted image ships iOS 27 only; Xcode 27.0 downloads iOS 26.5 in about 2.5 min (8.5 GB download, 8 GiB
# of disk; spike #4842, run 45285363085). An image that already has an iOS 26 runtime downloads nothing.
#
# A download that fails is tried again (3 tries in all). If there is still no iOS 26 runtime, the step fails with a
# clear message: testing on iOS 27 instead would miss iOS 26-only breaks such as #3984's 43.99-point button, and a red
# run says so where a warning would be lost. In main-t3 the failure comes before `pending`, so no commit status is set
# and the next tick tries again; no "Main T3 failed" issue is opened for it.
#
# Usage: scripts/ci-ios-runtime.sh <workflow label>
set -uo pipefail

label=${1:-ci}
# The next step (SM_LANE_IOS_MAJOR, lane_sim.IOS_MAJOR) expects major 26.
version=26.5
major=26
tries=3

# Prints the newest available iOS runtime of $major ("26.5 (23F77)"), or nothing. Returns 2 when simctl can't list
# the runtimes, so a broken listing is never read as "no iOS 26" (which would start an 8.5 GB download).
runtime_of_major() {
  local listing
  listing=$(xcrun simctl list runtimes --json) || return 2
  printf '%s' "$listing" | /usr/bin/python3 -c '
import json, sys
major = sys.argv[1]
ok = [r for r in json.load(sys.stdin)["runtimes"]
      if r.get("isAvailable") and r.get("platform") == "iOS" and r["version"].split(".")[0] == major]
ok.sort(key=lambda r: [int(p) for p in r["version"].split(".") if p.isdigit()])
print("%s (%s)" % (ok[-1]["version"], ok[-1].get("buildversion", "?")) if ok else "")
' "$major" || return 2
}

found=$(runtime_of_major)
case $? in
  0) ;;
  *) echo "::error title=$label iOS::xcrun simctl could not list the simulator runtimes, so the run can't tell whether iOS $major is installed."
     exit 1 ;;
esac
if [ -n "$found" ]; then
  echo "iOS $found is already on this image; nothing to download."
  exit 0
fi

echo "No iOS $major simulator runtime on this image. Downloading iOS $version."
df -h / | tail -1
for try in $(seq 1 "$tries"); do
  start=$(date +%s)
  if xcodebuild -downloadPlatform iOS -buildVersion "$version" -architectureVariant arm64; then
    echo "Download $try of $tries finished in $(( $(date +%s) - start )) s."
    found=$(runtime_of_major) || found=''
    [ -n "$found" ] && break
    echo "::warning title=$label iOS::The download finished but simctl lists no iOS $major runtime yet."
  else
    echo "::warning title=$label iOS::Download $try of $tries of iOS $version failed after $(( $(date +%s) - start )) s."
  fi
  [ "$try" -lt "$tries" ] && sleep $(( try * 30 ))
done

if [ -z "$found" ]; then
  echo "::error title=$label iOS::Could not install the iOS $version simulator runtime after $tries tries. The run stops here rather than testing on iOS 27, which would miss iOS $major-only breaks (#5221)."
  exit 1
fi
echo "Installed iOS $found."
df -h / | tail -1
