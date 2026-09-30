#!/bin/zsh
# Install Spoken Margins on iPhone (#384). Copy this file to the Desktop and double-click it.
#
# It installs the newest phone build (~/SpokenMargins-phone/latest, made by scripts/phone-build)
# over the app already on the one iPhone plugged into this Mac. Installing over the app keeps its
# Library and recordings. It never uninstalls or deletes the app. Then it records the installed
# commit in ~/SpokenMargins-phone/installed.txt, so the next build's test plan starts from here,
# and opens this build's test-plan.md.
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
print -r -- "Build: commit ${sha[1,7]}, built ${built:-at an unknown time}."

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
