#!/usr/bin/env bash
# Proves BUILDING.md is true (#1840): clones the committed HEAD into an empty temp folder, with no link to any
# other checkout (no .venv, no node_modules, nothing from the owner's folders), and runs BUILDING.md's host steps
# from there. It stops at the first failing step and names it.
#
#   scripts/check-fresh-clone.sh               host steps; steps whose tool is missing are skipped and counted
#   scripts/check-fresh-clone.sh --app-build   also the simulator build (needs Xcode; takes many minutes)
#   scripts/check-fresh-clone.sh --keep        keep the clone and logs afterwards (always kept on a failure)
#
# Only committed files are in the clone. Commit your change first to check it.
# A run that skipped steps prints PARTIAL PASS, never PASS, so a Linux run is not read as a full one.
set -uo pipefail

app_build=0
keep=0
for arg in "$@"; do
  case "$arg" in
    --app-build) app_build=1 ;;
    --keep) keep=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
work="$(mktemp -d "${TMPDIR:-/tmp}/sm-fresh-clone.XXXXXX")"
clone="$work/clone"
failed=0
ran=0
skipped=()

cleanup() {
  if [[ $keep -eq 0 && $failed -eq 0 ]]; then
    rm -rf "$work"
  else
    echo "Clone and logs kept in $work"
  fi
}
trap cleanup EXIT

if [[ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]]; then
  echo "note: uncommitted changes are not in the clone; this checks the committed HEAD ($(git -C "$root" rev-parse --short HEAD))."
fi

# The Supertonic and Kitten model files are Git LFS objects; without git-lfs a clone holds pointer files and the
# contract validators fail. A local clone takes its objects from this checkout's LFS store, so fill that first.
if ! git lfs version >/dev/null 2>&1; then
  echo "FAILED: git-lfs is not installed. Install it and run 'git lfs install' (BUILDING.md, Before you clone)."; failed=1; exit 1
fi
echo "running: fetch this checkout's LFS objects (so the local clone can use them)"
git -C "$root" lfs fetch >"$work/lfs-fetch.log" 2>&1 || { echo "FAILED: git lfs fetch (see $work/lfs-fetch.log)"; failed=1; exit 1; }

# A shallow clone through file:// copies no .venv, node_modules or build folders, because git doesn't track them.
git clone --quiet --depth 1 "file://$root" "$clone" || { echo "FAILED: git clone"; failed=1; exit 1; }
for leftover in .venv node_modules; do
  if [[ -e "$clone/$leftover" ]]; then
    echo "FAILED: the clone already has $leftover, so the check would prove nothing"; failed=1; exit 1
  fi
done

# step <name> <tool that must be installed, or -> <shell command run inside the clone>
step() {
  local name="$1" tool="$2" command="$3" log
  if [[ "$tool" != "-" ]] && ! command -v "$tool" >/dev/null 2>&1; then
    echo "skipped: $name ($tool not installed)"
    skipped+=("$name")
    return 0
  fi
  log="$work/$(echo "$name" | tr -c 'A-Za-z0-9' '-').log"
  echo "running: $name"
  if (cd "$clone" && env -u VIRTUAL_ENV -u PYTHONPATH bash -c "$command") >"$log" 2>&1; then
    ran=$((ran + 1))
  else
    failed=1
    echo "FAILED: $name"
    echo "  command: $command"
    echo "  last lines of $log:"
    tail -n 20 "$log" | sed 's/^/    /'
    exit 1
  fi
}

step "LFS files (git lfs pull)" git-lfs 'git lfs pull'
step "Python tools (scripts/bootstrap-python-tools.sh)" python3 'scripts/bootstrap-python-tools.sh'
step "contract validators" python3 '.venv/bin/python scripts/validate-contracts.py && .venv/bin/python scripts/validate-surface-contracts.py'
step "Node packages (npm ci)" npm 'npm ci'
step "browser extraction tests" node 'npm run test:browser-extraction'
if [[ "$(uname -s)" == "Linux" ]]; then
  step "SessionKit core tests (Linux)" swift 'scripts/run-sessionkit-linux-tests.sh'
else
  step "SessionKit tests (swift test)" swift 'cd Packages/SessionKit && swift test'
  step "fast plan (scripts/verify-tests.py)" swift '.venv/bin/python scripts/verify-tests.py --plan fast'
fi
if [[ $app_build -eq 1 ]]; then
  step "simulator build" xcodebuild "xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsApp -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing"
else
  echo "skipped: simulator build (pass --app-build; needs Xcode)"
  skipped+=("simulator build")
fi

echo
if [[ ${#skipped[@]} -eq 0 ]]; then
  echo "PASS: $ran steps ran from a fresh clone."
else
  echo "PARTIAL PASS: $ran steps ran, ${#skipped[@]} skipped: $(printf '%s; ' "${skipped[@]}")"
  echo "A skipped step was not checked. This is not a full pass."
fi
