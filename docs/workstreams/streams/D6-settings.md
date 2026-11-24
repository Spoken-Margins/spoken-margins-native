# D6 · settings: calm settings, diagnostics kept

**Outcome.** A tester opening Settings sees a short, plain-language list of the things they might actually change. Everything the owner uses for troubleshooting still exists, one level down in a clearly labeled Diagnostics area. Help describes the current app.

**Why.** The owner calls Settings "incredibly intimidating", though very useful for troubleshooting. Help still describes screens that no longer exist.

**Where.** Mac. Small.

**Waits for.** D1 for the look. A2 M1 moves `SettingsScreen` into its own file.

## Starting points

- `SettingsScreen.swift` has, in release builds since #4781: Help & Diagnostics (Share Diagnostics first); Voice; Storage; Notes Folder; Hidden senders and Hidden Margins when they have entries; Import & Export (the Import Inbox is one row and a page, `ImportInboxScreen.swift`); Privacy & Legal (About & Legal collapsed last). There's also a DEBUG-only Developer section.
- There are about 13 adjustable settings and 15 actions.
- `HelpScreen` names the Library and lists what the Link field takes (fixed in #782).

## Milestones

**M1: Reorganized.**
- Done when:
  - The top level of Settings has no more than 5 groups, ordered by how often testers need them, each setting with a one-line plain description.
  - Troubleshooting tools sit under Diagnostics, two taps from Settings.
  - Nothing is removed without the owner's OK.
  - Help matches the app (or links to G1's guides once they exist).
  - Lane T4 visits every setting and screenshots each group. T3 green.

## Must not break

Any setting's stored value across the upgrade. Test with a populated library from Build 29.

## Out of scope

New settings. Voice selection logic (C2).
