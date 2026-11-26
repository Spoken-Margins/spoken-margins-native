#!/bin/zsh
# Build Spoken Margins for iPhone now (owner's Desktop shortcut, 2026-11-25). Copy to the Desktop and double-click.
#
# It fetches the newest origin/main into the ops checkout (~/SpokenMarginsOps/repo, the one the scheduled phone-build
# job runs from, never a development checkout), then runs `scripts/phone-build --no-tests` there: a signed Release
# build of that exact commit, on this Mac, with no host tests, no simulator build and no main-t3 gate. The build lands
# in ~/SpokenMargins-phone/latest like every phone build. When it succeeds it runs the usual installer, which puts it
# on the iPhone plugged into this Mac (it keeps the Library and recordings, and never uninstalls).
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

echo "Step 2 of 3: building and signing the app. This takes about 5 to 15 minutes."
if [[ -x "$env_wrapper" ]]; then
  "$env_wrapper" /usr/bin/python3 scripts/phone-build --no-tests
else
  /usr/bin/python3 scripts/phone-build --no-tests
fi
result=$?
echo
if [[ $result -ne 0 ]]; then
  echo "The build did not finish (exit code $result). The reason is in the lines above."
  echo "The build log of the last attempt is in $phone_dir/.work, and the app on your phone is unchanged."
  exit $result
fi

if [[ -n "${SM_PHONE_NOW_NO_INSTALL:-}" ]]; then
  echo "Done. The build is in $phone_dir/latest."
  exit 0
fi
echo "Step 3 of 3: installing on the iPhone plugged into this Mac."
/bin/zsh "$phone_dir/install-phone-build.command"
echo
echo "Done. You can close this window."
