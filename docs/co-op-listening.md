# Co-op listening — first slice

Owner direction: September 22, 2026. Implementation lane: `codex/co-op` from
`82e61bcec35e309dd9ad38eb64f824ae5e45766b`. This is conversation navigation,
not recursive replies or hosted delivery. No distribution or merge is included.

## Product behavior

A listening session owns its captures and history. The item timeline additionally
shows active source-attached local Margins from every session, alongside imported
contributions. Reading an earlier Margin does not move it into the new session.
Existing session export and derivative-response ownership remain unchanged.

Skim navigates selected source events: All, Margins, or New Margins. Chapters,
generated scenes, and contributions retain separate provenance. New is local to
this installation; it does not imply group read receipts. Disabled or muted
imported layers do not become automatic Skim targets. Unresolved imported Margins
remain visible and directly listenable; they cannot supply a guessed source seek.

The existing second tap during a summary lands at its fixed destination. The same
interaction skips original-source context to a fixed Margin destination. Ordinary
chapter navigation without a prepared summary seeks directly. A prepared summary
is reused only when its destination matches the selected event, never to skip an
intervening contribution. Context is selectable: none, 30 seconds, one, two, or
five minutes. Two minutes is the default. Forward context does not rewind already
passed source. Explicit backward navigation may replay it.

Native audio uses recipient source milliseconds. Native text, including extracted
PDFs and prepared narration, uses source character positions. Text context is an
approximate 180-word/minute budget trimmed to a sentence or paragraph boundary;
it is not promised to last an exact number of seconds with every voice/rate.

A Margin exposes its transcript and available voice. Text-only contributions are
readable without inventing a synthetic voice. Return to original position restores
the starting source position; selecting another event is explicit. This slice does
not automatically assemble/advance an entire reel. Recording replies while a
Margin plays remains deferred; return to source to attach a new source Margin.

## PDF identity

Existing exact extracted-text and normalized-content digests establish matching
content; quoted passage and surrounding text establish local positions. A similar
title or approximate document resemblance does not verify an anchor.

Preparation removes an explicitly labeled download/retrieval/access date only
when it is a standalone stamp in a physical page margin. Dates in body prose stay
intact. Cleanup applies to new imports, not existing Library text or anchors.
General fuzzy document matching, OCR repair, and changed-edition approval UI remain
future work. Existing reviewed embedded-text transport can handle linkless text;
this slice does not upload original PDFs or change sharing consent.

## Verification and owner exercise

Developer checks must cover fresh sessions with older Margins, duplicate local IDs
across sessions, same-position contributions, manual seek cancellation, second-tap
landing, natural context arrival, new-only filtering, unresolved/muted layers,
chapter fallback, PDF stamp variation and preservation of body dates. Existing
summary-bridge tests protect accepted behavior. App/fast, relevant playback, and
phone/iPad UI checks provide implementation evidence only.

The owner exercise is to finish an item, import another person's Margins, begin a
new session, select Margins, Skim to context, tap again to hear the contribution,
and return to the starting source position. Repeat with native text/PDF and
confirm older local Margins remain accessible. Only owner acceptance establishes
`human_validated`; handoff evidence belongs under `artifacts/validation/gate-1/`.

## Deferred architecture

Recursive replies need stable contribution and parent identities, deterministic
union on import, missing-parent handling, and explicit forwarding consent. A
server may later deliver packets and membership updates; device playback and
source matching remain separate. No VPS or bucket resources are required by this
slice. AI context selection should be compared against the fixed-context baseline
only after the basic listening loop is accepted.
