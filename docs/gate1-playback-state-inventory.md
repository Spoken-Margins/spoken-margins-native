# Gate 1 Playback State Inventory

> Historical evidence: this inventory predates the Build 21 prepared-audio architecture. Kokoro/MLX references below describe retired experimental code only.

This inventory records the current Gate 1 playback behavior that should be preserved while the playback state model is cleaned up. If a future formal state machine disagrees with this behavior, treat that as a review point rather than assuming either side is automatically correct.

## Playback Targets

- `item_text_tts`: source item playback. If a Listening Map overview exists, playback starts with the summary preface before the source text.
- `summary_turn_tts`: generated interjection-summary playback.
- `assistant_turn_tts`: generated assistant-response playback.

The primary progress ring shows progress through the current playback target. Source progress remains available separately as article/source progress.

## Source Flow

- Starting a session on an item with a Listening Map overview speaks the summary before the source text.
- Timeline chapter jumps skip the summary preface and start at the selected source chapter.
- Tapping `Summary` in the timeline restarts source playback from the summary preface.
- Source item completion is based on audio completion. Once complete, the source session phase becomes `finished`, and prepared generated turns may autoplay.

## Interjections

- Interjections made during source playback target the source item.
- Interjections made during an interjection summary target that summary turn.
- Interjections made during an assistant response target that assistant turn.
- The interjection button remains `Interject` across source, summary, and assistant playback.

## Interjection Summaries

- The summarize button is enabled only when there is at least one active interjection for the current playback target that is not already covered by a non-failed summary.
- Clicking summarize creates or refreshes one interjection-summary turn for the current playback target.
- Clicking summarize again without adding a new interjection for that target is rejected.
- If the user adds another interjection for the same playback target and clicks summarize again, the existing summary turn for that target is replaced with a new pending/deferred summary job. The timeline should keep one summary card for that target rather than accumulating old summary cards.
- Source-targeted summaries should autoplay after source audio finishes.
- Turn-targeted summaries should not interrupt the active generated turn. They should queue until the active generated turn finishes or the user leaves playback.

## Discussion Turns

- Clicking Discuss records a user follow-up turn and creates a pending assistant-response turn.
- User follow-up turns appear in the timeline as `YOU`.
- Assistant response turns appear in the timeline as `AI`.
- A generated turn's parent timeline card is tappable. Fallback `0% Play full generated response` rows are not shown when the parent card already provides playback.
- Assistant response chapters, when provider-supplied, appear under the assistant response and are tappable.

## Pending Autoplay Queue

- Generated turns that complete while another target is actively playing are queued.
- The pending queue drains when the active audio target finishes or otherwise leaves `playing`.
- Manual navigation or manual generated-turn playback clears the pending autoplay queue, because the user has chosen a new target.
- The queue is FIFO so source summary, discussion response, and later generated turns preserve completion order.

## Gate 1 Deferrals

- Real Kokoro playback is not required for Gate 1 validation. Gate 1 can use system speech, with Kokoro retained for later device evidence.
- Real device transcription evidence may be supplied manually; simulator validation should not block on Speech framework or microphone hardware.
