# D4 · share: two taps to share, two taps to get your notes out

**Outcome.** Sending a Margin, or all of an item's Margins, to a friend takes two taps from wherever you are looking at it. Getting Margins out as a good-quality note (to the clipboard, the Files app, or the notes folder you chose) takes two taps too. The note has proper frontmatter, source links, and a link back into the app.

**Why.** "If it takes five or six clicks to share something with a friend, you're never going to do it." Today sharing a Margin takes about 8–10 taps, and the sharing screens are the oldest in the app.

**Where.** Mac.

**Waits for.** A2 M1 for its own files. D1 for the final look; the flow and tap count can be built first.

**Seams.** Owns **I12** (notes destination). Follows I10 (packet rules). Provides the share action D2 and E2 call.

## Starting points

- Today's sender flow: Item → ⋯ → Export latest session → Share Margins → choose Margins (with name, evidence and rights toggles) → Review → Preview package → Share verified package → share sheet → destination. The code is in `Build23SenderSharingExperience.swift`, `Build23SenderSharingComponents.swift`, `Build23SharingSeams.swift` and `SharingExperience.swift`.
- Copy one Margin with context: 2–3 taps (long-press → "Copy with Context").
- Session export: about 5 taps (`ExportScreen` in `Gate1RootView.swift`).
- The notes folder: `AutomaticMarginWriter` writes `Margin-<sha>.md` files on a 60 s loop while the app is active. There's no frontmatter, no tags and no link back (see `SessionExportMarkdownRenderer.renderMargin`). The docs say "about every 15 seconds", which is stale.
- The packet reader in the last shipped build accepts only `commentary-layer.v1` and `embedded-text-item.v1` as required capabilities. `spoken-margins-package.schema.json` has drifted from what the Swift manifest writes.

## Milestones

**M1: Two-tap share** (target: Build 30 if it's ready; otherwise the first build after A2 M1).
- Done when:
  - From a Margin (in Margins, the timeline or the player) and from an item, the system share sheet is **at most two taps** away, with sensible defaults: starred or all, sender name remembered, evidence included.
  - The review step is available but not required.
  - #168 (private feed URLs leaking in packets) is fixed, with a test.
  - #150 (a debug action in release builds) is gone.
  - The package schema matches what's written.
  - A packet from this build imports into Build 29 (keep a test).
  - Lane T4 runs J5 and counts the taps.

**M2: Notes worth keeping.**
- Done when:
  - Exported Markdown has YAML frontmatter (source, author, date, item link, tags), the Margin text with its context, and an app deep link.
  - One Margin, an item's Margins, and a date range can each go to the clipboard or the notes folder in two taps.
  - An Obsidian vault opened on a Mac shows correct links and frontmatter. The agent verifies the files; the owner verifies Obsidian.
  - I12 is published, with read access as a separate opt-in that nothing uses yet.

## Must not break

J5. Build 29 importing new packets. Existing notes-folder files: never overwritten or deleted, as `AutomaticMarginWriter` promises today.

## Out of scope

Group or book-club sharing (F1). Links that open the app or an install page (#169). Consider it after M2, since it needs a web endpoint (B4 M1).

## Related

#16, #125, #142, #147, #150, #168, #169, #171, #172.
