#!/bin/zsh
# Install Spoken Margins on iPhone (#384). Copy this file to the Desktop and double-click it.
#
# It installs the newest phone build (~/SpokenMargins-phone/latest, made by scripts/phone-build)
# over the app already on the one iPhone plugged into this Mac. Installing over the app keeps its
# Library and recordings. It never uninstalls or deletes the app. Then it records the installed
# commit in ~/SpokenMargins-phone/installed.txt, so the next build's test plan starts from here,
# and opens this build's test-plan.md. It also copies the plan to iCloud Drive (folder "Spoken Margins
# test plans", the newest five kept), so the owner can read it on the phone away from the Mac.
#
# The daily pin (~/SpokenMargins-phone/daily-ready) is installed instead of latest, unless the phone already has
# a newer build or the pin is over 24 hours old (the daily plans stopped refreshing it, #2529).
#
# If installed.txt already names the newest build, it says so and changes nothing, unless the
# owner types R to reinstall (#500). It also says whether a newer build is being made right now
# (a scratch folder in ~/SpokenMargins-phone/.work) or the newest attempt failed (last-attempt.json).
# It names how far the build is behind main, and why, from trunk.json, which scripts/phone-build writes (#2782).
# Any copy of this file (the Desktop's) runs ~/SpokenMargins-phone/install-phone-build.command when that differs:
# scripts/phone-build keeps it equal to main's, so the Desktop copy never goes stale.
#
# Tests: SM_PHONE_DIR replaces ~/SpokenMargins-phone, SM_PHONE_ICLOUD the iCloud Drive folder,
# SM_PHONE_NOW the clock; scripts/tests put a fake xcrun on PATH.
set -u

phone_dir="${SM_PHONE_DIR:-$HOME/SpokenMargins-phone}"
# scripts/phone-build keeps main's installer in the phone folder. A copy that differs, like the one on the
# Desktop, runs that one instead: an old Desktop copy kept installing a 4-day-old daily pin (#2782).
current="$phone_dir/install-phone-build.command"
if [[ -z "${SM_PHONE_INSTALLER_CURRENT:-}" && -f "$current" && "${0:A}" != "${current:A}" ]] \
    && ! /usr/bin/cmp -s "${0:A}" "$current"; then
  export SM_PHONE_INSTALLER_CURRENT=1
  exec /bin/zsh "$current" "$@"
fi
latest="$phone_dir/latest"
pinned=""
if [[ -L "$phone_dir/daily-ready" && -f "$phone_dir/daily-ready/build.json" ]]; then
  # The daily walkthrough and binary must agree (#1600), but the pin never goes over a newer build
  # already on the phone (#1691). "newer" when the installed build was built after the pinned one,
  # or, once its folder is pruned, when a different build was installed after the pin was set:
  # the installer only installs the pin or latest, and latest is never older than the pin.
  phone_is_newer=$(/usr/bin/python3 - "$phone_dir" <<'PY'
import datetime, json, os, sys
from pathlib import Path

phone = Path(sys.argv[1])
# Tests pin the clock with SM_PHONE_NOW (an ISO local time).
now = datetime.datetime.fromisoformat(os.environ['SM_PHONE_NOW']) if os.environ.get('SM_PHONE_NOW') else datetime.datetime.now()

def build(folder):
    try:
        info = json.loads((folder / 'build.json').read_text())
    except (OSError, ValueError):
        return None, None
    try:
        return info.get('sha'), datetime.datetime.fromisoformat(info.get('built_at'))
    except (TypeError, ValueError):
        return info.get('sha'), None

try:
    words = (phone / 'installed.txt').read_text().split()
except OSError:
    words = []
pin_sha, pin_built = build(phone / 'daily-ready')
installed = words[0] if words else ''
newer = False
if installed and pin_sha and installed != pin_sha:
    found = [built for sha, built in map(build, phone.glob(f'*-{installed[:7]}')) if sha == installed]
    if found:
        newer = bool(found[0] and pin_built and found[0] > pin_built)
    else:
        try:
            at = datetime.datetime.fromisoformat(words[1])
            pinned_at = datetime.datetime.fromtimestamp(os.lstat(phone / 'daily-ready').st_mtime)
            newer = at > pinned_at
        except (IndexError, OSError, ValueError):
            newer = False
# A pin the daily plans have stopped refreshing (three unanswered days, a failed writer) must not hold
# the installer back (#2529): past 24 hours old, and behind latest, it is skipped.
stale = False
latest_sha, _ = build(phone / 'latest')
if latest_sha and pin_sha and latest_sha != pin_sha:
    try:
        pinned_at = datetime.datetime.fromtimestamp(os.lstat(phone / 'daily-ready').st_mtime)
        stale = now - pinned_at > datetime.timedelta(hours=24)
    except OSError:
        stale = False
print('yes' if newer else 'stale' if stale else 'no')
PY
)
  if [[ "$phone_is_newer" == yes ]]; then
    pinned=passed
  elif [[ "$phone_is_newer" == stale ]]; then
    pinned=stale
  else
    latest="$phone_dir/daily-ready"
    pinned=yes
  fi
fi
app="$latest/SpokenMarginsApp.app"
work=$(mktemp -d "${TMPDIR:-/tmp}/sm-install.XXXXXX")
trap 'rm -rf "$work"' EXIT

stop() {
  print -r -- ""
  print -r -- "$1"
  print -r -- ""
  print -r -- "Nothing on the phone was changed. You can close this window."
  exit 1
}

if [[ "$pinned" == yes ]]; then
  print -r -- "Spoken Margins: install the daily phone pass"
else
  print -r -- "Spoken Margins: install the newest phone build"
fi
print -r -- ""
if [[ "$pinned" == passed ]]; then
  print -r -- "Your phone already has a newer build than this morning's daily pass, so this uses the newest build instead."
  print -r -- ""
fi
if [[ "$pinned" == stale ]]; then
  print -r -- "The daily pass is more than a day old and a newer build exists, so this uses the newest build instead."
  print -r -- ""
fi

[[ -d "$app" && -f "$latest/build.json" ]] || stop "There is no phone build yet in $phone_dir. Ask for one: scripts/phone-build makes it."
latest="${latest:A}"
app="$latest/SpokenMarginsApp.app"

sha=$(/usr/bin/plutil -extract sha raw -o - "$latest/build.json" 2>/dev/null)
built=$(/usr/bin/plutil -extract built_at raw -o - "$latest/build.json" 2>/dev/null)
[[ "$sha" == [0-9a-f]* && ${#sha} -eq 40 ]] || stop "The newest build's build.json has no commit. Make a fresh build with scripts/phone-build."
# First line: "same" when installed.txt names this build, else "new". Then the lines to show.
build_status=$(/usr/bin/python3 - "$phone_dir" "$sha" "$built" "$pinned" <<'PY'
import datetime, json, os, re, sys
from pathlib import Path

phone, sha, built, pinned = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
# Tests pin the clock with SM_PHONE_NOW (an ISO local time), so "today" and "yesterday" don't depend on when they run.
now = datetime.datetime.fromisoformat(os.environ['SM_PHONE_NOW']) if os.environ.get('SM_PHONE_NOW') else datetime.datetime.now()

def when(at):
    if at.date() == now.date():
        return f'today at {at:%H:%M}'
    if at.date() == (now - datetime.timedelta(days=1)).date():
        return f'yesterday at {at:%H:%M}'
    return f'{at:%b %-d} at {at:%H:%M}'

def parse(stamp):
    try:
        return datetime.datetime.fromisoformat(stamp)
    except (TypeError, ValueError):
        return None

# A build running now keeps a scratch folder named <date-time>-<sha7>; older than 90 minutes is a leftover.
progress = None
work = phone / '.work'
for folder in sorted(work.iterdir(), reverse=True) if work.is_dir() else []:
    found = re.fullmatch(r'(\d{8}-\d{6})-([0-9a-f]{7})', folder.name)
    started = found and datetime.datetime.strptime(found.group(1), '%Y%m%d-%H%M%S')
    if started and found.group(2) != sha[:7] and now - started < datetime.timedelta(minutes=90):
        progress = (f'A newer build is being made right now: commit {found.group(2)}, started {when(started)}. '
                    'It takes about 5 to 15 minutes, and a Mac notification says when it is ready.')
        break
if progress is None:
    try:
        attempt = json.loads((phone / 'last-attempt.json').read_text())
    except (OSError, ValueError):
        attempt = {}
    result = str(attempt.get('result', ''))
    if attempt.get('sha') and attempt['sha'] != sha and result.startswith('failed'):
        at = parse(attempt.get('at'))
        progress = (f'The newest attempt, commit {attempt["sha"][:7]}, failed{" " + when(at) if at else ""}: '
                    f'{result[len("failed"):].lstrip(": ")}. The next change on main gets a fresh try.')

# How far this build is behind main, and why (#2782): "newest" used to mean only "newest in this folder", so a
# stale folder looked current. scripts/phone-build writes trunk.json every time it looks at main.
at = parse(built)
try:
    trunk = json.loads((phone / 'trunk.json').read_text())
except (OSError, ValueError):
    trunk = None
behind = note = None
if not isinstance(trunk, dict) or not re.fullmatch(r'[0-9a-f]{40}', str(trunk.get('sha', ''))):
    note = ("This Mac has no record of main's newest commit yet, so I can't tell how far behind main this build "
            'is. scripts/phone-build writes one each time it runs.')
else:
    checked = parse(trunk.get('checked_at'))
    if trunk['sha'] != sha:
        merged = parse(trunk.get('committed_at'))
        days = int((merged - at).total_seconds() // 86400) if merged and at and merged > at else 0
        gap = (f'This build is {days} day{"" if days == 1 else "s"} behind main' if days else
               "This build is not main's newest commit")
        why = (trunk.get('problem') or
               ('it is the daily pass, which stays until it is a day old so its test plan matches the app'
                if pinned == 'yes' else
                'the next phone build will pick main up (hosted builds come twice a day)'))
        behind = (f'{gap}: main is at commit {trunk["sha"][:7]}'
                  f'{", merged " + when(merged) if merged else ""}. Why: {why}.')
    if checked and now - checked > datetime.timedelta(hours=3):
        note = (f'The phone-build job last looked at main {when(checked)}, so it may have stopped. '
                'Its log is ~/SpokenMargins-phone/launchd.log.')

try:
    words = (phone / 'installed.txt').read_text().split()
except OSError:
    words = []
print('same' if words and words[0] == sha else 'new')
print(f'Newest build: commit {sha[:7]}, built {when(at) if at else "at an unknown time"}.')
for line in (behind, note):
    if line:
        print(line)
if words and words[0] == sha:
    at = parse(words[1] if len(words) > 1 else None)
    name = ' '.join(words[2:]) or 'Your iPhone'
    print(f'{name} already has this build: commit {sha[:7]}, installed {when(at) if at else "earlier"}.')
    if progress or not behind:
        print(progress or 'No newer build yet. A hosted one comes twice a day once a change lands on main, '
              'and a Mac notification says when it is ready.')
else:
    if words and re.fullmatch(r'[0-9a-f]{7,40}', words[0]):
        at = parse(words[1] if len(words) > 1 else None)
        print(f'Your phone has commit {words[0][:7]}{", installed " + when(at) if at else ""}. This build is newer.')
    else:
        print('No install is recorded on this Mac yet.')
    if progress:
        print(progress)
PY
)
if [[ "${build_status%%$'\n'*}" == same ]]; then
  print -r -- "${build_status#*$'\n'}"
  print -r -- ""
  print -r -- "Nothing on the phone was changed."
  if [[ "$pinned" == yes && -f "$latest/test-plan.md" ]]; then
    # A daily pass can add checks without changing the already-installed binary.
    daily_icloud="${SM_PHONE_ICLOUD:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Spoken Margins test plans}"
    if [[ -d "$daily_icloud" ]] || mkdir "$daily_icloud" 2>/dev/null; then
      cp "$latest/test-plan.md" "$daily_icloud/Test plan ${sha[1,7]}.md" 2>/dev/null || true
    fi
    open "$latest/test-plan.md"
  fi
  print -r -- "To reinstall this build anyway (say, after installing from Xcode or TestFlight), type R and press Return. Otherwise close this window."
  answer=""
  read -r answer || answer=""
  [[ "$answer" == [Rr]* ]] || exit 0
  print -r -- ""
else
  print -r -- "${build_status#*$'\n'}"
fi

xcrun devicectl list devices --json-output "$work/devices.json" >"$work/list.log" 2>&1 \
  || stop "Couldn't list devices (xcrun devicectl failed). Is Xcode installed? Details: $(tail -3 "$work/list.log")"

phones=$(/usr/bin/python3 - "$work/devices.json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get('result', {}).get('devices', [])
for d in devices:
    hw, conn, props = d.get('hardwareProperties', {}), d.get('connectionProperties', {}), d.get('deviceProperties', {})
    kind = hw.get('deviceType') or hw.get('productType', '')
    if hw.get('platform') != 'iOS' or not str(kind).startswith('iPhone'):
        continue
    if conn.get('transportType') != 'wired':
        continue
    print('\t'.join([d.get('identifier', ''), props.get('name', 'iPhone'), conn.get('pairingState', 'unknown')]))
PY
)
count=$(print -r -- "$phones" | grep -c .)
if (( count == 0 )); then
  stop "No iPhone is plugged in. Connect it with a cable, unlock it, tap Trust if it asks, and double-click this again."
elif (( count > 1 )); then
  stop "More than one iPhone is plugged in:
$(print -r -- "$phones" | cut -f2 | sed 's/^/  - /')
Unplug all but the one to update, then double-click this again."
fi

device=$(print -r -- "$phones" | cut -f1)
name=$(print -r -- "$phones" | cut -f2)
pairing=$(print -r -- "$phones" | cut -f3)
[[ "$pairing" == "paired" ]] || stop "$name isn't paired with this Mac yet. Unlock it, tap Trust on the phone, and double-click this again."

print -r -- "Installing on $name over the existing app (your Library stays)..."
if ! xcrun devicectl device install app --device "$device" "$app" >"$work/install.log" 2>&1; then
  details=$(tail -5 "$work/install.log")
  hint="Unlock the phone and try again."
  case "$details" in
    *[Dd]eveloper\ [Mm]ode*) hint="Turn on Developer Mode: Settings > Privacy & Security > Developer Mode, then restart the phone." ;;
    *[Ll]ocked*) hint="Unlock the phone, keep it unlocked, and double-click this again." ;;
    *[Pp]rofile*|*[Pp]rovision*|*[Ss]ignature*) hint="This phone isn't in the build's signing profile. Tell the agent: the next build needs the phone registered." ;;
  esac
  stop "The install didn't finish. $hint
What devicectl said:
$details"
fi

print -r -- "$sha $(date '+%Y-%m-%dT%H:%M:%S') $name" > "$phone_dir/installed.txt"
print -r -- ""
print -r -- "Done: $name now runs commit ${sha[1,7]}. In the app, Settings shows the version ending in · ${sha[1,7]}."
print -r -- "Opening the test plan."

# The phone reads the plan from iCloud Drive (Files app > iCloud Drive > Spoken Margins test plans).
# Only "Test plan <commit>.md" files are ours; anything else in the folder is left alone.
icloud="${SM_PHONE_ICLOUD:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Spoken Margins test plans}"
if [[ -f "$latest/test-plan.md" ]] && { [[ -d "$icloud" ]] || mkdir "$icloud" 2>/dev/null; } \
    && cp "$latest/test-plan.md" "$icloud/Test plan ${sha[1,7]}.md" 2>/dev/null; then
  old=("$icloud"/Test\ plan\ *.md(Nom[6,-1]))
  (( ${#old} )) && rm -f -- "${old[@]}"
  print -r -- "The test plan is also on your phone: Files > iCloud Drive > Spoken Margins test plans > Test plan ${sha[1,7]}."
else
  print -r -- "(I couldn't copy the test plan to iCloud Drive, so it's only on this Mac.)"
fi
open "$latest/test-plan.md"
