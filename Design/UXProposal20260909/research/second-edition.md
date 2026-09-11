# Second edition · September 10, 2026

## Trigger and decision model

The product owner rejected the first proposal's claim to human-centered design: decorative and explanatory text consumed space needed for actual tasks. This is product-owner critique, not a recruited usability study. The previous browser QA established rendering, not useful composition.

The second edition uses these separate layers:

- People and tasks: a returning listener choosing an item; a person capturing a fleeting thought; the same person retrieving a note; a sender reviewing disclosure.
- Resources and constraints: reachable phone area, attention, readable text, saved source position, original recording, note identity, and source ownership.
- Mechanisms: visible item rows, stable playback controls, two-step capture, searchable note excerpts, explicit playback switching, and selective sharing.
- Failure modes: introductory copy before useful content; critical transport scrolling away; wrong-item play actions; a note opening the wrong source; typed capture implying a recording; decorative compression masking accessibility failure.
- Decision criteria: useful content before a preliminary scroll, meaningful labels, stable identity, complete critical actions, and understandable state. Counts of visible rows are geometry evidence, not proof of comprehension or value.

## Changes

The main book now opens with Library, Player, and Margins screens. A separate `try.html` presents the working concept directly, including a viewport-filling phone layout on narrow screens. The first edition is preserved in `edition-one.html` with its own stylesheet and script for comparison.

All 20 proposed states were revised. Removed ornamental headings and redundant explanatory blocks from routine tasks. Library uses a current-item row instead of a large resume card. Margins shows multiple actual note excerpts with item/position attribution. Source context is expandable. Playback position, transport, speed, capture, and navigation sit in fixed control regions while long content scrolls. Capture saves a sample note attached to its source; typed capture stores the entered words and is labeled as written text. Opening a note preserves current playback; Play this moment explicitly changes it.

Search, filter, sorting, star, follow/add, inclusion controls, source matching, preparation, and core navigation have local demo state. OS actions, actual audio, transcription, storage deletion, voice cleanup, and native sharing remain simulated or explanatory boundaries. Typed capture, broader search, and root naming remain native design proposals, not release authorization.

## Browser evidence

Actual browser checks, not DOM simulation alone:

- Compared Library plates with equal 346 × 742 CSS-pixel inner frame dimensions at a 1440 × 1000 desktop viewport. Edition 1's first Up next row starts 621 px from the frame top; no Up next row is fully visible. Edition 2's first item row starts 196 px from the frame top; all four item rows are fully visible. Edition 1 still offered a visible resume card, so this is not a claim that it had no usable action.
- All 20 states rendered at 375 × 667 with no horizontal overflow in the phone content. Checked footer primary actions and the playback dock: all measured controls remained in the viewport.
- At 375 × 667 with the long-title fixture and larger text together, Pause occupied y=426–495 and Add a Margin y=552–612; both were visible. The title remained complete in the scrollable content. Measurements describe this browser viewport, not native points or Dynamic Type.
- Standard 390 × 844 Library and Player, 1440 × 1000 book cover, and source-note detail inspected visually.
- Library → play → Add a Margin → Save & resume → View opened the captured note at 8:42.
- Typed a distinct thought, saved it, and confirmed the exact words, Written note label, and source position in detail.
- Opened a note on On keeping a notebook while The art of paying attention played. The persistent player retained The art of paying attention at 8:42.
- The 50-note sample found the single note containing “quiet street.”
- Empty Library → Add → Paste text → Play retained the entered item title; the new text has its own paragraph count and an inspectable source-text panel.
- No browser script errors during these checks.

## Fair comparison and stopping rule

Use both editions with the same intended tasks. Separate visually measured layout from human task performance. Record assistance, mistaken selections, scrolling to reach controls, lost context, and whether someone can explain a saved note. Compare the compact current-item row against the earlier resume card; reconsider if resume becomes harder to recognize. Check empty, long-title, many-note and larger-text samples before accepting visual preference.

This iteration stops at a coherent, browser-checked proposal. Native VoiceOver, Dynamic Type, actual recording/transcription, one-handed physical use, headset behavior, and recipient sharing require native implementation and product-owner use. No native flow is declared human_validated, and no runtime app files were changed.
