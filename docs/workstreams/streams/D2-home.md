# D2 · home: one place a listener could live in

**Outcome.** A Home screen that answers "what should I do now?" at a glance. It shows what to pick back up, one good thing to start next, one source worth following if you don't follow much yet, your latest Margins (shareable in one tap), and your book club's activity, if you're in one. Library, Following and Margins can then specialize instead of each trying to be everything.

**Why.** Owner's words: the Home screen can be the Jack of all trades, so the specialized screens can actually specialize.

**Where.** Mac.

**Waits for.** A2 M1 (its own files) and D1 (the look). Card plumbing can start before D1 lands.

**Seams.** Owns **I6** (Home cards). Reads I2 (catalog, for the follow nudge), I4 and I5 (suggestions, from D3), and later E2 and F1 cards.

## Starting points

- There's no Home screen today. `Gate1RootView` contains a dead private `HomeScreen` that A2 removes. Don't revive it.
- `LibraryPresentation.continueItem` picks one "Continue listening" item: the most recent `lastListenedAt` between 0% and 99% progress.
- The Following inbox is newest-first (`quickAddCandidates`).
- "Follow this source" suggestions exist (`offerFollowSuggestionIfEligible`).

## Milestones

**M1: Home with what exists.**
- Done when:
  - Home shows: resume (up to 3 items), latest Margins with one-tap share (via D4's share action, or a stub until it lands), and, for a listener following fewer than 3 sources, one follow suggestion from B1's catalog.
  - Cards come through I6, so a new provider needs no layout edit. Show it by adding one test provider.
  - It renders quickly with a 500-item library. Measure the time to first render on the lane and state it.
  - Lane T4: a fresh install and a populated library both show a sensible Home.

**M2: Suggestions and the rest.**
- Done when:
  - Home shows "start this next" from D3's ranking, with its reason.
  - Book club (F1) and week-in-review (E2) cards appear when those providers exist.
  - The owner uses Home for a week of builds and accepts it (T6).

## Must not break

The mini-player. Deep links and packet opens landing on the right screen. Performance with long histories.

## Out of scope

The ranking itself (D3). The review experience itself (E2).
