# D1 · design: choose where the app is going before building it

**Outcome.** The owner has tapped through two or three clickable phone prototypes of a redesigned Spoken Margins, picked a direction, and that direction is written down precisely enough for the Mac streams (D2–D6, D5, F1) to build it without guessing: navigation, each main screen's job, the key flows, and tap budgets for the tasks that matter.

**Why now.** Testers find the app hard to understand. The owner wants a Home screen, a Following screen that can handle 60 feeds, a Library and a Margins screen that can specialize, a calmer Settings, two-tap sharing, a better player, and eventually a book-club review flow. Designing those piecemeal inside five streams would give five different apps.

**Where.** Cloud. No Xcode needed. The deliverables are web prototypes, which the owner can open on the phone, and a short written spec.

**Seams.** Feeds the look and flow of D2, D4, D5, D6, and F1's review experience. I15 (UI identifiers) stays with A2.

## Starting points

- Today: full-screen swaps between screens, a three-tab `TabView` (Library, Following, Margins), no Settings tab, Settings reached from menus, a persistent mini-player. Now Playing is a roughly 1,460-line screen. See `ExperienceRootViews.swift` and `Gate1RootView.swift`.
- Two earlier design studies exist; build on what still holds:
  - `Design/UXProposal20260909`: an audit with 24 findings and 23 screenshots.
  - `Design/SpokenMarginsOverhaul`: a Next.js prototype with 11 states and research docs.
- Measured today: sharing a Margin takes about 8–10 taps. Session export takes about 5. Setting up the notes folder takes 6–8.
- Tester feedback: many moving parts; you have to use the app from several places to get podcasts in; no onboarding; no easy sharing.
- The owner's intent for Home: "a Jack of all trades so the other screens can specialize". It shows what to resume, one suggestion to start, one feed to follow for new users, recent Margins that are easy to share, and the book club, if any.
- Open UI issues to account for: #106–#109, #115, #141, #146–#149, #151, #165, #167.

## Milestones

**M1: Directions to choose from.**
- Done when two or three distinct directions exist as clickable phone-sized prototypes the owner can open from the phone (a Claude artifact or a page on the owner's static site).
  - Each covers: first run, Home, Following with a lot of feeds, Library, Margins, Now Playing (including recording a Margin and Skim), Share, Settings, and a sketch of reviewing other people's new Margins on an item.
  - Each comes with a tap-budget table for these tasks:
    - share a Margin to a friend;
    - follow what's playing;
    - follow a podcast on first run;
    - record a Margin;
    - export this week's Margins as a note;
    - open a shared packet and hear it.
  - A two-tap share is a requirement, not a stretch goal.

**M2: The chosen direction, specified.**
- Done when, after the owner picks, a spec lives in `Design/` covering:
  - the navigation structure;
  - each screen's job and the data it needs (naming the seams in `docs/workstreams/interfaces.md`);
  - component and state lists, including empty, loading and error states;
  - copy for key moments;
  - design tokens mapped onto `ExperienceDesignSystem.swift`;
  - the final tap budgets.
- The D-stream agents can each point to the section they build.

## Must not break

Nothing. There's no app code in this stream.

## Out of scope

Implementing in Swift. Marketing site design (G2 may reuse the direction).

## Owner decisions

Picking the direction (M1 → M2). If none fits, say what's wrong and M1 repeats once.
