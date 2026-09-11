# M1A frozen-candidate review

## Scope and evidence

- Reviewed `artifacts/reviews/second-edition/m1a/candidate.patch`, the M1/second-edition requirements, and the affected Library, Player, Margins, model, and UI-test seams.
- Verified the four SHA-256 identities in `inputs.json` exactly match the frozen source/test-plan files.
- No build, test, simulator, screenshot, or accessibility-tree evidence was supplied or run in this review. The fixed dock and Dynamic Type layout are therefore unverified, not human-validated.

## Finding

### P1 — Player's Margins sheet masks the Timeline requested from a Margin

**Location:** `App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1RootView.swift:2113`, `App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceMarginsScreen.swift:54`, `App/SpokenMarginsApp/Sources/SpokenMarginsApp/ExperienceMarginDetailView.swift:43`.

The new fixed `Margins` control presents `ExperienceMarginsScreen` in `isPlaybackMarginsPresented`. That screen presents its Margin detail as a second sheet. Its `Open in Timeline` action dismisses only the detail sheet, then changes `model.screen` to `.timeline`. It has no binding or dismissal path for the outer Player-owned Margins sheet. Consequently, this path leaves the Margins sheet covering the newly selected Timeline screen.

**Counterexample:** start an item → tap fixed **Margins** → open any Margin → tap **Open in Timeline**. The model has navigated to Timeline, but the user remains looking at the outer Margins sheet. They must discover and dismiss it manually before seeing the requested timeline/focused Margin. This violates the explicit navigation action and creates a presentation conflict rather than an identity-safe return.

**Blocking status:** block acceptance until the outer sheet is dismissed as part of this action (or the Player routes directly through the existing root/navigation path).

## Coverage assessment

The Library rewrite preserves the existing row callbacks for open, start/resume, completion, offline preparation, and deletion. `visibleContinueItem` correctly prevents a current row that fails the active query/filter from being displayed as a match. The Player continues to call existing model actions for transport, recording, rate, sleep timer, source text, mix controls, export, and imported-commentary return; I found no new direct session mutation in these view changes.

The added UI test meaningfully checks that the fixed play, capture, and options controls are present and hittable with a long title at an accessibility category. The updated existing test also checks that Export remains reachable through More. It does not exercise the Player → Margins → Margin detail → Timeline path above, nor does it establish iPad, default-size, VoiceOver, actual audio/session restoration, or rendered clipping behavior.

## Non-blocking observations

- `ExperienceLibraryScreen` still renders the "No matches" state whenever `compactItems` is empty, even if `visibleContinueItem` is the sole matching item (`ExperienceLibraryScreen.swift:271`). That behavior predates this candidate's item-first layout because `compactItems` has always excluded the continue item; it is not counted as a candidate regression. If addressed later, the empty-state condition should use the full visible list rather than the compact remainder.
- The candidate's duplicate `playback.timeline.button` identifiers occur in mutually exclusive surfaces (fixed dock and options sheet), so I found no simultaneous accessibility-identifier conflict.
