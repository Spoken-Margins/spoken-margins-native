# D3 · following: 60 feeds without drowning

**Outcome.** Someone following 12, 30 or 60 sources sees the new items most worth their time first. They can see why each item is ranked where it is ("high because you've made 12 Margins on this show"), nudge it ("more like this", "less of this source"), filter by kind (podcasts, articles, papers, news) and by per-feed keyword or regex rules, and hand the whole policy to their own AI as a file and bring back a changed one. A clearly labeled "custom" ranking can always be reset in one tap.

**Why.** A chronological list stops working as soon as people follow more than a handful of feeds. Spoken Margins knows more than a podcast player does about what each listener values.

**Where.** Scoring logic in SessionKit, so it's host-testable, and cloud-testable if A1 M4 lands. UI on the Mac.

**Waits for.** A2 M1 for the UI. Signals and scoring can start immediately.

**Seams.** Owns **I4** (engagement signals) and **I5** (ranking policy file). Reads I2 (source kinds and categories).

## Starting points

- Today the inbox (`quickAddCandidates`) merges Quick Folder files and feed entries newest-first, with All/Feeds/Folder chips and per-feed Mute and Unfollow. There are no tags, no per-feed view and no listening statistics.
- #176 has the owner's intent and constraints: on-device only, explainable, overridable, and good by default for a new user with no signals. Its suggested first step is to log signals for a few weeks, then check whether a simple score beats date order.
- The owner's `Digest` repo prototypes the power-user end: source and domain tags, deterministic classifiers (contains, regex, has_tag, domain), digest filters and lenses, and a YAML/JSON **patch → preview → trial → accept/reject → rollback** loop validated by JSON Schema. See `src/types.ts`, `src/patchSchema.ts` and `MVP_IMPLEMENTATION_PLAN.md` there. Port the ideas; the TypeScript stays behind.
- Build 30 reach items: #141 (feed management pushes items below the fold), #146 (discoverable swipes, undo dismiss, unfollow from an episode, keep scroll position).

## Milestones

**M1: Signals and kinds.**
- Done when:
  - I4 is recording: listened time per item and source, Margins (kind and length), shares, exports, imports from others, dismissals, finishes. There's no per-tick main-thread I/O.
  - The previous build still opens the database (test with the build-25 fixture approach in `docs/testing.md`).
  - Sources carry a kind tag (auto-assigned, user-editable), and Following can filter by it.
  - #141 and #146 are addressed.
  - T3 green, and lane T4 on a library with 30+ feeds.

**M2: Ranking that explains itself.**
- Done when:
  - Following can be ordered by a transparent score, and every item shows its top reason.
  - "More like this" and "less of this source" change the order visibly and reversibly.
  - With no signals, the default order is at least as good as newest-first.
  - An offline evaluation on the owner's own logged history (exported with the owner's permission) shows the score would have put items the owner went on to finish or make Margins on higher than date order did. Report the metric.

**M3: The policy file and filters.**
- Done when:
  - The ranking policy exports as a readable file with its schema and a plain-language explanation an AI can edit.
  - Importing shows a preview of what changes in the inbox before applying. Invalid files are rejected with the reason.
  - Per-feed keyword and regex exclusion rules work.
  - "Reset to default" is always visible while a custom policy is active and restores the default in one tap.
  - Host tests cover valid, invalid and adversarial policies (for example catastrophic regexes: bound their cost).

## Must not break

Following's current behavior when nothing has been customized. Mute and Unfollow. Import dedupe.

## Out of scope

Server-side anything: signals never leave the device. Time-of-day patterns (note them as a follow-up if M2's data suggests they help).

## Related

#76, #77, #130, #141, #146, #170, #176.
