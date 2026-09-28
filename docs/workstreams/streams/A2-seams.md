# A2 · seams: split the app so streams stop colliding

**Outcome.** Four or more streams can change different parts of the app at the same time without editing the same file, and one well-defined component owns "what is playing and who has the audio session".

**Why now.** `Gate1AppModel.swift` (16.5k lines) and `Gate1RootView.swift` (5.5k lines) hold almost everything. Every UI stream in this plan would otherwise edit both, and merges would fail daily. The co-op collapse on Sep 24 came from four playback state machines sharing one player inside that model (`docs/repo-review-2026-09-24.md` §4 and §6).

**Where.** Mac. **Effort:** xhigh or max. This stream's mistakes land on everyone.

**Seams.** Owns I15 (stable UI identifiers). Creates the file boundaries D2, D3, D4, D5, D6 and B1 build in.

## Starting points

- `Gate1RootView` switches full-screen on `Gate1Screen` (home, item, playback, timeline, settings, offlineStorage, export, batchExport). `home` is a three-tab `TabView` (Library, Following, Margins) in `ExperienceRootViews.swift`.
- About 1,200 lines are dead: the private `HomeScreen` (roughly lines 680–1517) and `ItemScreen` (roughly 1571–1972) are never instantiated. Confirm with a search before deleting.
- `PlaybackScreen` is about 1,460 lines inside the root view. `SettingsScreen`, `ExportScreen` and `BatchExportScreen` also live there.
- `AppNavigationState` (in `ExperienceModels.swift`) keeps per-root paths that the root view mostly ignores.
- Playback today: source playback via `SessionEngine`, plus separate players for the Skim bridge (`startSkimBridge` / `completeSkimBridge`), Margin audio and imported commentary. The parked branch's playback work is reference only.

## Milestones

**M1: Screens out of the root.** Each screen lives in its own file with its own narrow view model or dependencies.
- Done when:
  - Home/tab shell, Library, Following, Margins, Item, Playback, Settings and Export each live in their own file.
  - `Gate1RootView.swift` is a thin router under about 800 lines, and the dead views are gone.
  - New screens receive what they need through small protocols or view models rather than the whole `Gate1AppModel`. Moved screens may keep the model for now, but no new code widens that dependency.
  - Stable accessibility identifiers (I15) exist on the controls J1–J7 touch.
  - T2 green, T3 for navigation tests green, and a T4 run of J1, J3 and J7 passes on the lane.
  - **Behavior is unchanged.** Say so in the PR, and show that no user-visible string or flow changed.

**M2: One playback coordinator.** A single component owns the source player, Margin playback, Skim summaries and the audio session.
- Done when:
  - That coordinator exists (not inside `Gate1AppModel`), and every play, pause, seek, Skim and Margin-play path goes through it.
  - It exposes one observable state that answers "what is playing, from where, and what resumes afterwards".
  - The "should the source resume" flags are gone from `Gate1AppModel`.
  - Host tests drive the coordinator through: Margin plays then source resumes; Skim summary then seek; seek while paused with no player; interruption by a phone call; a second Margin while the first is still playing.
  - T3 green, and a T4 run of J2, J3 and J5 passes.
  - The owner then checks J3 by ear (T6).

## Must not break

- Any journey. M1 is a move, not a redesign.
- Packets, the database, and the Live Activity and Lock Screen controls.
- The current podcast-anchor capture tap (`docs/podcast-anchor-plan.md`, slices 2–3). Coordinate with C4 before touching the player that carries the tap.

## Out of scope

Visual changes (D1 and the D streams). New features. Splitting `Gate1AppModel`'s non-playback logic beyond what M1 needs: do that opportunistically, in later streams, one type at a time.

## Owner decisions

None to start. M2 changes behavior at the edges (resume timing), so the owner's J3 pass is the acceptance.
