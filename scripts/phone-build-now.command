#!/bin/zsh
# Build Spoken Margins for iPhone now (owner's Desktop shortcut, 2026-11-25). Copy to the Desktop and double-click.
#
# It fetches the newest origin/main into the ops checkout (~/SpokenMarginsOps/repo, the one the scheduled phone-build
# job runs from, never a development checkout), then runs `scripts/phone-build --no-tests` there: a signed Release
# build of that exact commit, on this Mac, with no host tests, no simulator build and no main-t3 gate. The build lands
# in ~/SpokenMargins-phone/latest like every phone build. When it succeeds it runs the usual installer with
# SM_PHONE_INSTALL_LATEST=1, which puts that build (never the daily pass) on the iPhone plugged into this Mac (it keeps
# the Library and recordings, and never uninstalls). It says "Done" only when this run made a new latest and
# installed.txt names its commit.
#
# A build takes about 5 to 15 minutes. Close the window when it says it is done.
# Tests: SM_OPS_REPO replaces the ops checkout, SM_PHONE_DIR the phone folder, SM_PHONE_NOW_NO_INSTALL=1 skips installing.
set -u

repo="${SM_OPS_REPO:-$HOME/SpokenMarginsOps/repo}"
phone_dir="${SM_PHONE_DIR:-$HOME/SpokenMargins-phone}"
env_wrapper="$HOME/.claude/bin/sm-agent-env"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export SM_TRUNK=main SM_AGENT_AS_APP=1

echo "Building Spoken Margins for your iPhone from the newest main, with no tests."
echo
if [[ ! -d "$repo/.git" ]]; then
  echo "Stopped: the ops checkout $repo is missing, so there is nothing to build from."
  exit 1
fi
cd "$repo" || exit 1

echo "Step 1 of 3: getting the newest main."
/usr/bin/python3 scripts/ops_checkout.py --repo "$repo" || echo "(could not update the ops checkout; building what it has)"
if ! grep -q -- "--no-tests" scripts/phone-build; then
  echo "Stopped: this checkout's phone-build has no --no-tests option yet, so the shortcut can't build without tests."
  exit 1
fi
echo "Building commit $(git rev-parse --short HEAD): $(git log -1 --format=%s)"
echo

# Which build latest points at before this run. "Done" needs a new one: phone-build can end well without building
# (another phone build held the lock), and the installer would then put the old latest on the phone (#5440 audit).
latest_of() { /usr/bin/python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$phone_dir/latest" 2>/dev/null; }
latest_before=$(latest_of)

echo "Step 2 of 3: building and signing the app. This takes about 5 to 15 minutes."
if [[ -x "$env_wrapper" ]]; then
  "$env_wrapper" /usr/bin/python3 scripts/phone-build --no-tests
else
  /usr/bin/python3 scripts/phone-build --no-tests
fi
result=$?
echo
if [[ $result -eq 75 ]]; then
  echo "No build was made: another phone build is running, or a guard said not now (the reason is in the lines above)."
  echo "The app on your phone is unchanged. Double-click this shortcut again once that build is done."
  exit $result
fi
if [[ $result -ne 0 ]]; then
  echo "The build did not finish (exit code $result). The reason is in the lines above."
  echo "The build log of the last attempt is in $phone_dir/.work, and the app on your phone is unchanged."
  exit $result
fi

if [[ -z "$(latest_of)" || "$(latest_of)" == "$latest_before" || ! -f "$phone_dir/latest/build.json" ]]; then
  echo "No new build was made: the build step ended without putting a build in $phone_dir/latest."
  echo "The app on your phone is unchanged. The reason is in the lines above; double-click this shortcut again."
  exit 75
fi

if [[ -n "${SM_PHONE_NOW_NO_INSTALL:-}" ]]; then
  echo "Done. The build is in $phone_dir/latest."
  exit 0
fi
echo "Step 3 of 3: installing on the iPhone plugged into this Mac."
SM_PHONE_INSTALL_LATEST=1 /bin/zsh "$phone_dir/install-phone-build.command"
installed=$?
echo
# The installer stops with a non-zero exit and changes nothing when no iPhone is on a cable, the phone is locked,
# or devicectl fails. The shortcut used to say "Done" anyway (#5343, 2026-11-26 run: phone paired over the network
# only, nothing installed), so the build and the install are reported apart.
if [[ $installed -ne 0 ]]; then
  echo "The build is ready, but it is not on your phone yet: the install stopped (the reason is in the lines above)."
  echo "Fix that, then double-click this shortcut again."
  exit $installed
fi
# The installer can also end well without putting this build on the phone (an installer that ignores
# SM_PHONE_INSTALL_LATEST and picks the daily pass), so "Done" is said only when installed.txt names the commit this
# run built.
built_sha=$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("sha", ""))' \
  "$phone_dir/latest/build.json" 2>/dev/null)
phone_sha=$(head -1 "$phone_dir/installed.txt" 2>/dev/null | cut -d' ' -f1)
if [[ -z "$built_sha" || "$built_sha" != "$phone_sha" ]]; then
  echo "The build is ready (commit ${built_sha:0:7}), but your phone has a different one (commit ${phone_sha:0:7})."
  echo "Double-click this shortcut again to put the newest build on it."
  exit 1
fi
echo "Done: your phone runs commit ${built_sha:0:7}, the one just built. You can close this window."
