# Simulator file-import failure and workaround

## Status

This is a development-environment issue in Apple's Simulator file-transfer
path, not expected app behavior.

Apple documents that sharing a file from Finder to Simulator should open the
Files app and let the developer choose where to save it. An Apple DTS engineer
has described the differing iOS 26 behavior as a bug-report candidate. Public
reports include `FB19888064` and `FB9832605`; no public resolution was found as
of September 2, 2026.

References:

- [Apple: Sharing data with Simulator](https://developer.apple.com/documentation/xcode/sharing-data-with-simulator)
- [Apple Developer Forums: Importing files to Files.app in iOS 26 Simulator](https://developer.apple.com/forums/thread/787297)

## Observed failure

The failure was reproduced on macOS 26.6.2, Xcode 26.6, and an iOS 26.5
Simulator in both supported host paths:

- dragging a file onto the Simulator reports that the device failed to open
  the host `file:///...` URL;
- Finder **Share > Simulator > Send** closes without transferring the file.

The second path records this sequence in the macOS unified log:

```text
SimulatorShareExtension: Cancel request ... NSPOSIXErrorDomain Code=1
SimulatorShareExtension: Change sharing status Editing -> Failed
SimulatorShareExtension: Service did complete with success 0 items
```

A small plain-text control file fails identically, so this failure is not
specific to the `.spokenmargins` extension, package size, archive contents, or
`com.spokenmargins.package` declaration.

## Workaround

Copy the package directly into the booted Simulator's local Files provider.
The command resolves the device and app-group UUIDs dynamically because they
can change when a Simulator is recreated or erased.

Prerequisites:

- boot exactly one iOS Simulator;
- install `jq` if it is not already available;
- save the `.spokenmargins` package to a normal Mac filesystem location first.

Run from a shell, replacing `package_path`:

```bash
set -euo pipefail

package_path="/absolute/path/to/package.spokenmargins"

simulator_udid="$(
  xcrun simctl list devices booted -j |
    jq -r '
      [
        .devices
        | to_entries[]
        | select(.key | startswith(
            "com.apple.CoreSimulator.SimRuntime.iOS-"
          ))
        | .value[]
        | select(.state == "Booted")
      ] |
      if length == 1 then .[0].udid
      else error("Boot exactly one iOS Simulator")
      end
    '
)"

files_url="$(
  xcrun simctl listapps "$simulator_udid" |
    plutil -convert json -o - - |
    jq -r '.["com.apple.DocumentsApp"].GroupContainers[
      "group.com.apple.FileProvider.LocalStorage"
    ]'
)"

files_directory="${files_url#file://}File Provider Storage"
destination="$files_directory/$(basename "$package_path")"

if [[ ! -f "$package_path" ]]; then
  echo "Package does not exist: $package_path" >&2
  exit 1
fi

if [[ "$files_url" != file://* || ! -d "$files_directory" ]]; then
  echo "Could not resolve Simulator Files storage" >&2
  exit 1
fi

if [[ -e "$destination" ]]; then
  echo "Refusing to overwrite existing Simulator file: $destination" >&2
  exit 1
fi

cp -p "$package_path" "$destination"
echo "Copied to Simulator Files: $destination"
```

Then, in Simulator:

1. Open **Files**.
2. Open **Recents** or **On My iPhone**.
3. Tap the `.spokenmargins` package.
4. Confirm that Spoken Margins presents **Review before importing**.

Stop before pressing **Import** when the goal is only to verify document
ownership and package staging.

## Interpreting the result

- If an ordinary text control file and a `.spokenmargins` package both fail in
  `SimulatorShareExtension` before appearing in Files, the host-to-Simulator
  transport is failing.
- If the injected package appears in Files and opens **Review before
  importing**, iOS document dispatch and Spoken Margins package staging work.
- If Spoken Margins opens but presents an in-app rejection, investigate the
  package contents or compatibility instead of the Simulator transport.
- If the injected package appears in Files but tapping it does not open Spoken
  Margins, investigate the installed app's document-type registration.

This workaround is developer evidence only. It does not validate Messages,
AirDrop, Share-extension behavior, or direct document opening on a physical
device, and it must not be recorded as `human_validated` product behavior.

## Optional diagnostic command

After a failed Finder transfer, inspect the Simulator sharing extension:

```bash
/usr/bin/log show --last 5m --style compact \
  --predicate 'process == "SimulatorShareExtension" AND (eventMessage CONTAINS[c] "Cancel request" OR eventMessage CONTAINS[c] "Change sharing status" OR eventMessage CONTAINS[c] "Service did complete")'
```
