# D5 · player: a Now Playing screen that makes Margins easy

**Outcome.** The playback screen is clear, reachable with one hand, and built around what makes Spoken Margins different:
- Skim forward to the next chapter or the next Margin, with a lead-in that a second press skips.
- "Play this moment": a lead-in, the Margin inline, then carry on.
- See which Margin is coming up next.
- Tapping a shared Margin plays its moment.

**Why.** The owner calls the playback screen another screen that needs a UI/UX overhaul, and Skim-to-Margin is the heart of reviewing other people's Margins (F1).

**Where.** Mac.

**Waits for.** A2 M2 (the playback coordinator) and D1 (the look). The Sep 24 failure came from bolting Margin navigation onto the old playback paths, so don't start the behavior milestones before the coordinator exists.

**Seams.** Uses I14 (speech), I15 (identifiers), and the A2 coordinator's state.

## Starting points

- `PlaybackScreen` (about 1,460 lines, moving to its own file in A2 M1) has transport, Skim, record and write a Margin, sleep timer, speed, Mix, Text, Timeline, Conversation and More.
- Skim today: plays the current scene's summary, then seeks. Pressing again while the summary plays skips it. It needs a prepared listening map with summaries, and says so when it's missing.
- The parked branch tried Skim-to-Margin with a 120 s lead-in and stranded the source (the 19:08 stall). Take the idea, not the code.

## Milestones

**M1: The redesigned screen, same abilities.**
- Done when:
  - Now Playing follows D1's spec. Every existing ability is still reachable.
  - Primary controls are within one-handed reach and at least 44 pt (#148, #149, #151).
  - The current chapter is highlighted (#134).
  - Lane T4 runs J1, J2 and J3 green.
  - (owner) The owner accepts the feel on the phone.

**M2: Margin navigation.**
- Done when:
  - Skim moves to the next chapter or Margin, with a lead-in that a second press skips (#182).
  - "Play this moment" plays lead-in → Margin → continues (#159).
  - The next Margin is previewed (#167). Tapping a shared Margin in the timeline plays its moment (#158).
  - All of it runs through the A2 coordinator, adding no playback state to the model.
  - Coordinator-level host tests cover each path, including interruption and seeking while paused.
  - Lane T4 runs J3 and J5.
  - (owner) The owner checks by ear (T6).

## Must not break

J2, J3, J5. The Live Activity and Lock Screen controls. Podcast-anchor capture.

## Out of scope

Book-club features beyond single-item Margin navigation (F1).

## Related

#115, #134, #137, #148, #149, #151, #158, #159, #167, #180, #181, #182.
