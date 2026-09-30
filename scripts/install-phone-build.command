#!/bin/zsh
# Install Spoken Margins on iPhone (#384). Copy this file to the Desktop and double-click it.
#
# It installs the newest phone build (~/SpokenMargins-phone/latest, made by scripts/phone-build)
# over the app already on the one iPhone plugged into this Mac. Installing over the app keeps its
# Library and recordings. It never uninstalls or deletes the app. Then it records the installed
# commit in ~/SpokenMargins-phone/installed.txt, so the next build's test plan starts from here,
# and opens this build's test-plan.md.
#
# If installed.txt already names the newest build, it says so and changes nothing, unless the
# owner types R to reinstall (#500). It also says whether a newer build is being made right now
# (a scratch folder in ~/SpokenMargins-phone/.work) or the newest attempt failed (last-attempt.json).
#
# Tests: SM_PHONE_DIR replaces ~/SpokenMargins-phone; scripts/tests put a fake xcrun on PATH.
set -u

phone_dir="${SM_PHONE_DIR:-$HOME/SpokenMargins-phone}"
latest="$phone_dir/latest"
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

print -r -- "Spoken Margins: install the newest phone build"
print -r -- ""

[[ -d "$app" && -f "$latest/build.json" ]] || stop "There is no phone build yet in $phone_dir. Ask for one: scripts/phone-build makes it."
latest="${latest:A}"
app="$latest/SpokenMarginsApp.app"

sha=$(/usr/bin/plutil -extract sha raw -o - "$latest/build.json" 2>/dev/null)
built=$(/usr/bin/plutil -extract built_at raw -o - "$latest/build.json" 2>/dev/null)
[[ "$sha" == [0-9a-f]* && ${#sha} -eq 40 ]] || stop "The newest build's build.json has no commit. Make a fresh build with scripts/phone-build."
# First line: "same" when installed.txt names this build, else "new". Then the lines to show.
build_status=$(/usr/bin/python3 - "$phone_dir" "$sha" "$built" <<'PY'
import datetime, json, re, sys
from pathlib import Path

phone, sha, built = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
now = datetime.datetime.now()

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
                    f'{result[len("failed"):].lstrip(": ")}. The next change on next gets a fresh try.')

try:
    words = (phone / 'installed.txt').read_text().split()
except OSError:
    words = []
at = parse(built)
print('same' if words and words[0] == sha else 'new')
print(f'Newest build: commit {sha[:7]}, built {when(at) if at else "at an unknown time"}.')
if words and words[0] == sha:
    at = parse(words[1] if len(words) > 1 else None)
    name = ' '.join(words[2:]) or 'Your iPhone'
    print(f'{name} already has this build: commit {sha[:7]}, installed {when(at) if at else "earlier"}.')
    print(progress or 'No newer build yet. One starts within about 10 minutes of a change landing on next, '
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
print -r -- "Done: $name now runs commit ${sha[1,7]}. Opening the test plan."
open "$latest/test-plan.md"
