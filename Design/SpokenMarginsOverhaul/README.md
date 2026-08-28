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
