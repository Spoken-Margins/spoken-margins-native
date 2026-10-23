# Spoken Margins experience overhaul

This folder is an isolated design study. It does not change the Swift app, SessionKit, contracts, project settings, or release-lane implementation.

The prototype reframes Spoken Margins as a quiet, offline-first listening library with three stable places:

- **Library** — sources the listener has deliberately added.
- **Sources** — new entries from explicitly followed sources; following never imports or downloads.
- **Margins** — the listener's own thoughts and deliberately imported commentary layers.

Now Playing is a persistent context, not a fourth content silo. Add Source, Item Detail, Timeline, Share Preview, Onboarding, and Offline Storage are task-focused routes over those three places.

## Explore the prototype

The left-hand scene picker opens eleven representative states:

1. Library
2. First run
3. Add source
4. Item detail
5. Now playing
6. Recording
7. Timeline
8. Source inbox
9. Your margins
10. Share preview
11. Offline storage

Within the phone, the main journey is clickable:

`Library → Now Playing → Interject → Timeline → Review & Share`

The Library tabs also connect to Sources and Margins. The plus button opens the intake router. The profile mark opens Offline Storage.

## Run locally

This project requires Node 22.13 or newer.

```bash
npm install
npm run dev
```

The current prototype build passes `npm run build` with Node 24. It is a design artifact, not a functional product implementation.

## Research documents

- [Use cases and user flows](research/use-cases-and-flows.md)
- [Overhaul proposal and audit plan](research/overhaul-proposal.md)

## Status language

- `implemented`: the static prototype contains the representative route or state.
- `verified`: the prototype compiles in the Sites/Vinext build.
- `human_validated`: reserved for product-owner use of the proposed flow and explicit acceptance.

The prototype is **implemented** and its build is **verified**. None of these redesigned product flows are claimed as **human_validated**.

## Native Build 22 disposition

The prototype is now also an implementation hypothesis for the private Build 22 experience on `codex/experience-overhaul`. The native implementation deliberately keeps the prototype and the shipping app distinct: this folder remains useful research material, while SwiftUI, persisted app state, accessibility semantics, and the existing SessionKit runtime determine the product behavior.

Adopted in the native app:

- adaptive Library, Sources, and local Margins roots, with Now Playing retained as persistent context rather than another content root;
- a typed Add Source router over the existing link/podcast, pasted text, document/book, audiobook, and Quick Folder handlers;
- one persisted Continue item, deterministic type covers, metadata-only Library controls, and recoverable destructive actions;
- explicit follow-versus-add consent, feed/folder provenance, local Margin attention states, nested canonical source navigation, and a labeled Timeline;
- exclusive recording presentation with an immutable anchor and model guards against navigation or session replacement;
- an app-facing offline-storage ledger that separates protected, reproducible, reserved, clearable, and residual-overage bytes;
- two genuine starter items whose actions use the same item, playback, Margin, and Timeline paths as user-added content;
- native bone, evergreen, ochre, coral, and plum semantics with Dynamic Type, VoiceOver, light/dark appearance, Increased Contrast, Reduce Motion, and minimum control targets.

Changed from the prototype:

- no profile or account affordance, fabricated artwork, fabricated metadata, engagement count, or “New for you” framing;
- no literal CSS measurements or web-navigation model; system typography and controls carry interaction semantics, with serif limited to editorial headings;
- deletion lives behind context actions with confirmation and undo instead of occupying the primary row surface;
- a partially prepared text-audio prefix never advertises a full scrubber, and intake or historical Margin navigation never replaces another active listening session;
- raw Listening Map JSON is developer-only diagnostics rather than primary item-detail UI.

Deferred by release-lane boundary:

- Share Preview, imported people, replies, and recipient-side layers remain in `codex/sharing-next`. Build 22 implements only the local provenance portion of [issue #68](https://github.com/uncomposed/spoken-margins-native/issues/68).
- The canonical playback, scrubbing, and recording-continuity fixes from [#83](https://github.com/uncomposed/spoken-margins-native/issues/83), [#84](https://github.com/uncomposed/spoken-margins-native/issues/84), and [#85](https://github.com/uncomposed/spoken-margins-native/issues/85) are preserved rather than reimplemented.
- Future Scenes and Skim work in [#88](https://github.com/uncomposed/spoken-margins-native/issues/88), [#89](https://github.com/uncomposed/spoken-margins-native/issues/89), and [#90](https://github.com/uncomposed/spoken-margins-native/issues/90) may compose with the transport later; this branch adds no placeholder controls, command IDs, or schemas for it.
- Watch, publisher-artwork dependencies, remote execution, analytics, accounts, and deployment behavior remain out of scope.

The native paths are `implemented`. Automated checks may establish `verified`; only the product owner can mark them `human_validated`.

Note: the package files (`package.json`, `package-lock.json`) were removed on 2026-10-22 to clear Dependabot alerts. The source here is reference only; git history has the files.
