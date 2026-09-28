# E2 · reflect: a week of Margins becomes a note worth keeping

**Outcome.** Once a week, or whenever they like, the listener opens a review of what they listened to and said.
- The Margins are gathered by item and topic.
- The listener quickly keeps or drops them, individually or a whole topic at once ("not that interesting, bring none of these in").
- They answer a few short prompts by voice or text, and add anything new.
- They can listen to it: the week's Margins played back with their source moments, speaking replies as they go.
- They finish with a well-made note in their notes app of choice: their "week in media".

**Why.** People who add lots of Margins are doing real thinking. Giving it back to them, curated and interactive, is what makes the app a place for reflection rather than just a player.

**Where.** Mac.

**Waits for.**
- D4 M2 (notes destination and export format).
- A2 M2, and D5 M2's "play this moment", for the audio mode.
- E1 makes it better (grouping by kind and topic) but isn't required: group by item and date without it.

**Seams.** A Home card provider (I6). Reads I4 (what was listened to), I7 (structure, if present) and I12 (where the note goes).

## Starting points

- Margins have transcripts and source context. There's session "Summarize Notes" (Foundation Models) and per-Margin Markdown export (`SessionExportMarkdownRenderer`).
- No review, triage or weekly surface exists.

## Milestones

**M1: Review and triage, then a note.**
- Done when a listener with 25 Margins across 6 items in a week (a seeded library on the lane) can:
  - triage all of them with at most one tap per Margin, and drop a whole item or topic in one tap (the lane counts taps, since an agent's clock isn't a listener's);
  - answer at least one prompt;
  - export the note in two taps.
- The note is Markdown with frontmatter, sources, kept Margins with their context, and the listener's reflections.
- (owner) The owner rates two real weeks' notes as worth keeping (T6).
- With on-device AI, prompts and a short synthesis are generated on device. Without it, sensible fixed prompts and grouping still produce a good note.

**M2: Listen to your week.**
- Done when an audio mode plays each kept Margin with its source moment (lead-in → Margin), accepts a spoken reply that becomes part of the note, and survives interruptions. It runs on the A2 coordinator. Lane T4.
  - (owner) A device pass by ear.

## Must not break

The listener's Margins. Triage marks Margins as "not in this review" but never deletes them. Anything written to the notes folder follows D4's rule: files edited outside the app are never touched, and nothing is deleted.

## Out of scope

Sending anything to a server or a remote AI. Multi-week trend analytics. Suggest them if M1 users ask.
