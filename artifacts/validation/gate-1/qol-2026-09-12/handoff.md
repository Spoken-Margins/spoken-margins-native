# Small quality-of-life bundle

Scope: #116 committed render frontier, #115 Skim destination, #109 Margins scope/direct actions and session-export relocation. The selection favors frequent everyday decisions, existing canonical data, no service costs, no migration, and independently testable boundaries. It corrects the previous agent-authored narrowing of the PKM work.

The native-text prepared region is a thin teal line below the position track. It measures contiguous committed source coverage from a compatible durable Supertonic manifest, including real file existence/size checks. Missing chunks stop the frontier. Queued work never advances it. Whole-item media duration and seek policy are unchanged. Live system speech has no fabricated prepared region. Asset identity is computed off the main actor and cached per voice; the visible playback surface refreshes durable state every two seconds.

Skim controls display the target from the same plan resolver used on activation, including the current bridge destination. They refresh with playhead/map changes and retain disabled behavior when no target exists.

Margins provides All items or a named item scope across private/shared notes, visible result counts, existing text search/star filters, and direct Play this moment / Copy with Context / Star menu actions. Item Detail's Review Margins opens that item's scope. The passive Needs attention filter is removed; per-note errors and existing repair actions remain. Pull to refresh replaces the refresh toolbar icon. Export Sessions is on the Margins toolbar and uses the existing canonical session exporter; it no longer appears in Library options. The export screen remains an explicitly selectable multi-session export, independent of the current search.

Excluded from this small bundle: new bookmark persistence/hardware capture, gesture-engine replacement, figure understanding, new reading-service adapters, and broad synthesis/scheduling changes. These remain distinct roadmap work, not silently reported as implemented here.

## Quick owner check

No whole-Library reset required. Use an existing long native-text/PDF item and a few disposable written Margins.

1. Select a local Supertonic voice and prepare part of a long native-text item. Open Now Playing: the thin prepared line must differ from the playhead. Let another chunk finish; it should advance. Stop preparation/relaunch: committed progress should remain. Change voice: old progress must disappear or recompute. Confirm the scrubber retains its normal touch behavior.
2. On an item with ready Skim summaries, note the displayed destination, activate Skim, and confirm it lands there. Repeat after entering another scene and during a summary bridge.
3. Open Margins → All items; search a note. Select one item and verify unrelated notes disappear. Switch Mine/Starred/Shared within that scope. Clear filters to return to the full collection. Open Item Detail → Review Margins and confirm the matching scope.
4. Long-press a Margin: copy with context, star/unstar, and explicitly play its saved position. Existing note-detail repair controls should remain available.
5. Use Margins → Export Sessions. Select the desired sessions and export through the existing destination picker. Confirm Library options no longer contain Export Sessions.

Device target: iPhone/iPad, iOS 18+. Automated UI checks target iOS 26.5; only the owner can mark these flows human_validated. Physical preparation timing and VoiceOver comprehension remain owner checks. Diagnostics: Settings → Developer tools → diagnostic export, with item and step. Restore by deleting only disposable test notes/items; no destructive migration or reset is introduced.

Development version 0.1 (27), based on commit `de9dc82`; the current uncommitted source is separate from the distributed Build 27. Fast checks and all 422 app tests passed. The first app run (`20260912-231908-591587-app`) hit a database-lock error in an existing feed-import test; a clean run passed without modifying that unrelated test. Final run identities are recorded in `verification.json` beside this file. No commit, upload, or release promotion is authorized by this handoff.

Final verification: fast plan passed; 422 app tests passed; all 13 phone UI tests passed. iPad passed 12 of 13 in the full run; the last test exceeded its unchanged two-minute allowance while opening the seeded source, before reaching Margins. One isolated retry after a simulator restart passed. Both generic simulator/device builds passed. The executable input hash matches across the final plans. The failed runs remain in the evidence record.

Screenshots: [phone](margins-phone.png), [iPad](margins-ipad.png). These show the empty collection controls; populated scope/private/shared isolation is covered by the app fixture tests and remains in the owner checklist.

Weekly usage meter: 49% → 53% used, 47% remaining (account-wide rounded readings). No reset credit used.
