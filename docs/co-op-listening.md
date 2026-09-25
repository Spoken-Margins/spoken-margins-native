# Co-op listening and recursive replies

Owner direction: September 22, 2026. Implementation lane: `codex/co-op` from
`82e61bcec35e309dd9ad38eb64f824ae5e45766b`. The September 22 follow-up adds recursive replies and optional context editing.
Hosted delivery remains deferred. No distribution or merge is included.

## Product behavior

September 24 owner correction (target, not yet verified): Margin playback remains
part of navigation through the episode. A Skim to a verified Margin moves the
canonical source bookmark to that Margin's verified position, plays the Margin
without a blocking source lead-in, and resumes from that destination after the
Margin finishes or is skipped. Unresolved imported positions cannot authorize a
podcast seek; their voices remain directly playable with a clear unavailable
source-position state. Keep the podcast scrubber visible, show distinct Margin
progress and a skip-to-end action during its voice, and use a compact way to
return to the episode rather than a large “Continue Source” button. The
cue-triggered shared-Margin auto-play preference must not be confused with
explicit user-invoked Skim or Listen. Locally authored Margins are familiar on
their originating installation without a user marking step; exact parents may
still play as context for a new reply. These requirements supersede the older
return-to-origin owner exercise below. The exported 22-Margin packet contains
cleaned-audio representations, but the owner heard retained pauses and fillers;
cleanup quality remains under investigation.

A listening session owns its captures and history. The item timeline additionally
shows active source-attached local Margins from every session, alongside imported
contributions. Reading an earlier Margin does not move it into the new session.
Existing session export and derivative-response ownership remain unchanged.

Skim navigates selected source events: All, Margins, or New Margins. Chapters,
generated scenes, and contributions retain separate provenance. New is local to
this installation; it does not imply group read receipts. Disabled or muted
imported layers do not become automatic Skim targets. Unresolved imported Margins
remain visible and directly listenable; they cannot supply a guessed source seek.

Importing a shared podcast packet matches an existing Library episode or adds the
referenced episode automatically from the packet. The recipient does not have to
add the podcast separately. The existing publisher-link resolver remains the
first path; when that lookup fails and the validated packet contains a canonical
HTTPS page and HTTPS audio enclosure, the same source-persistence path uses the
packet's exact episode reference. This creates the Library association and starts
the normal podcast download; it does not verify a Margin's source position or
promise that the remote audio is available. Packet voice stays directly playable
when placement is unresolved.

The existing second tap during a chapter summary lands at its fixed destination.
An explicit Skim tap targeting a Margin starts its available recording directly;
it does not wait for a source-context seek or a separate Listen prompt. A second
tap advances to the next Margin. Ordinary
chapter navigation without a prepared summary seeks directly. A prepared summary
is reused only when its destination matches the selected event, never to skip an
intervening contribution. "Play with context" remains a separate optional action.
Context is selectable: none, 30 seconds, one, two, or five minutes. Two minutes
is the default for that action. Forward context does not rewind already passed
source. Explicit backward navigation may replay it. If media context fails to
advance, the app plays the Margin directly after a bounded wait.

Native audio uses recipient source milliseconds. Native text, including extracted
PDFs and prepared narration, uses source character positions. Text context is an
approximate 180-word/minute budget trimmed to a sentence or paragraph boundary;
it is not promised to last an exact number of seconds with every voice/rate.

A Margin exposes its transcript and available voice. Text-only contributions are
readable without inventing a synthetic voice. Return to original position restores
the starting source position; selecting another event is explicit. This slice does
not automatically assemble/advance an entire reel. A playing Margin offers explicit voice and written replies. The capture retains
its source position and separately references the exact parent revision. Voice
ancestors advance in order; text ancestors expose Next reply. This is a selected
conversation path, not an automatically assembled whole-item reel.

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
new session, select Margins, tap Skim once to hear the contribution,
and continue from that verified Margin's source position. Repeat with native text/PDF and
confirm older local Margins remain accessible. Only owner acceptance establishes
`human_validated`; handoff evidence belongs under `artifacts/validation/gate-1/`.

## Recursive conversation contract

Each contribution has an installation-scoped author ID, stable contribution ID,
and immutable revision ID. Author labels remain unverified; packet integrity is
not authentication. Replies reference an exact revision. Edits create a new
revision, keeping the prior transcript/audio available to existing replies. Local
recordings used by snapshots are retained in ConversationAudio by digest.

Import unions exact revisions, retains sibling replies, rejects conflicting bodies
for the same revision, and permits missing ancestors to arrive later. No last-write
wins or automatic conflict resolution is used. Import validation and writes are
atomic in SQLite. Re-importing overlapping packets adds only new revisions.
Packages with this metadata require `spoken-margins.conversation.v1`; older clients
must reject that required capability. Old packages still import, and acquire a
stable legacy reference when first used as a reply target.

September 24 extension: a reply may target an ordered list of two to four exact
revisions. Such packets additionally require `spoken-margins.conversation.v2`;
the `parents` array replaces the singular `parent` field for that reply. A packet
must not carry both fields on the same contribution. Existing zero- and
one-parent records retain their v1 encoding and stable identity. All referenced
parents must belong to the same item when known; duplicate links, self-links,
cycles and conflicting immutable revisions are rejected. Missing parents remain
visible and may arrive later. Listening visits shared ancestors once, in target
order, before the reply. Source anchors remain the author's capture evidence,
separate from the reply links.

The optional Response & Context sheet is available from a source Margin and item
sharing. It can redirect a response to another Margin, or choose source context.
Text selection uses source characters and a quoted passage; podcasts use a range
within the preceding five minutes. These are listening hints, separate from the
portable matching anchor. A recipient uses its resolved anchor and verifies the
selected text before using the range; uncertain selections fall back to normal
context. The Play Margin now action bypasses an optional lead-up. Parent context plays
the complete exact parent revision; trimming parent audio/text is deferred.

The item Share path remains unchanged. The optional disclosure lists exact parent
versions and requires an explicit Include referenced Margins choice before adding
those bodies. Without it, links are sent and the recipient uses versions already
present locally. Missing versions stay visible as missing. Forwarded audio is
labeled as a forwarded copy, not as newly recorded or newly cleaned audio.

A recent completed Margin can suggest attaching a newly captured source Margin
as a reply for 30 seconds. This never changes the parent without a tap. Seeks and
item changes clear the suggestion. Explicit Reply starts with the parent visibly
identified; cancellation or microphone failure clears that pending target.

Verification must include real archive round trips, overlapping three-person
packets, reverse arrival order, conflict rollback, store reconstruction, retained
capture anchors, corrected parents, and exact parent-chain playback. App test
compilation is not test execution. Current simulator-incident restrictions apply;
see the second-slice handoff for the checks actually performed.

## Deferred architecture

A server may later deliver packets and membership updates; device playback and
source matching remain separate. No VPS or bucket resources are required by this
slice. AI context selection should be compared against the fixed-context baseline
only after the basic listening loop is accepted.
