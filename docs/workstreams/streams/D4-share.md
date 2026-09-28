# D4 · share: two taps to share, two taps to get your notes out

**Outcome.** Sending a Margin, or all of an item's Margins, to a friend takes two taps from wherever you are looking at it. Getting Margins out as a good-quality note (to the clipboard, the Files app, or the notes folder you chose) takes two taps too. The note has proper frontmatter, source links, and a link back into the app. Nothing private leaks through a shared packet.

**Why.** "If it takes five or six clicks to share something with a friend, you're never going to do it." Today sharing a Margin takes about 8–10 taps, and the sharing screens are the oldest in the app.

**Where.** Mac.

**Waits for.** Nothing to start: the sharing screens already have their own files (`Build23Sender*`). D1 sets the final look; build the flow and tap count first. `ExportScreen` moves out of the root view in A2 M1. If A2 M1 hasn't landed, keep edits there to thin call sites.

**Seams.** Owns **I12** (notes destination). Follows I10 (packet rules). Provides the share action D2 and E2 call.

## Starting points

- Today's sender flow:
  1. Item
  2. ⋯
  3. Export latest session
  4. Share Margins
  5. Choose Margins (with name, evidence and rights toggles)
  6. Review
  7. Preview package
  8. Share verified package
  9. Share sheet
  10. Destination

  The code is in `Build23SenderSharingExperience.swift`, `Build23SenderSharingComponents.swift`, `Build23SharingSeams.swift` and `SharingExperience.swift`.
- Copy one Margin with context: 2–3 taps (long-press → "Copy with Context").
- Session export: about 5 taps (`ExportScreen` in `Gate1RootView.swift`).
- The notes folder: `AutomaticMarginWriter` writes `Margin-<sha>.md` files on a 60 s loop while the app is active. It owns only files it generated: it rewrites its own files when their content changes, leaves alone any file edited outside the app, and never deletes. There's no frontmatter, no tags and no link back (see `SessionExportMarkdownRenderer.renderMargin`). The docs say "about every 15 seconds", which is stale.
- Build 29's packet reader accepts only `commentary-layer.v1` and `embedded-text-item.v1` as required capabilities, and rejects unknown keys in the manifest and its entries. `spoken-margins-package.schema.json` has drifted from what the Swift manifest writes.

## Milestones

**M0: Stop the leak** (target: Build 30). **Already implemented** on branch `private-feed-urls` (`ShareableLinkPolicy`, `PrivateFeedLinkTests`). What's left is getting it into `next`.
- Done when that branch is merged into `next` with lane T3 green and J5 passing.
  - A host test shows packets from items with private feeds carry no private URL in any string.
  - Packets from this build still import into Build 29 (test).
  - C4 builds #177 on this fix. Note it on #177 when this lands.

**M1: Two-tap share.**
- Done when:
  - From a Margin (in Margins, the timeline or the player) and from an item, the system share sheet is **at most two taps** away, with sensible defaults: starred or all, sender name remembered, evidence included.
  - The review step is available but not required.
  - The package schema matches what's written.
  - A packet from this build imports into Build 29 (keep a test).
  - Lane T4 runs J5 and counts the taps.

**M2: Notes worth keeping.**
- Done when:
  - Exported Markdown has YAML frontmatter (source, author, date, item link, tags), the Margin text with its context, and an app deep link.
  - One Margin, an item's Margins, and a date range can each go to the clipboard or the notes folder in two taps.
  - The generated files are checked against Obsidian's frontmatter and link conventions in a host test.
  - (owner) The owner opens them in their vault.
  - I12 is published, with read access as a separate opt-in that nothing uses yet.

## Must not break

- J5.
- Build 29 importing new packets.
- The notes-folder rule `AutomaticMarginWriter` keeps today: files edited outside the app are never touched, and nothing is deleted.

## Out of scope

Group or book-club sharing (F1). Links that open the app or an install page (#169). Consider them after M2; they need a web endpoint (B4 M1).

## Related

#16, #125, #142, #147, #168, #169, #171, #172.
