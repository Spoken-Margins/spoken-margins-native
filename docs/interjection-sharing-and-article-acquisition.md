# Interjection Sharing and Visible Article Acquisition

Status: implemented behind the `sharingExperienceEnabled` development flag. Contract and focused automated checks may establish `verified`; only the product owner can establish `human_validated`.

## Product boundary

The `.spokenmargins` transport contains reviewed user commentary, bounded source-anchor evidence, source identity, lineage, integrity metadata, and an explicit redaction record. It never contains complete source text, source audio, raw captures, diagnostics, API data, filesystem paths, or unrelated turns. SHA-256 integrity is presented as **Integrity checked · Unsigned sender** and is not identity authentication.

Article acquisition always begins with a publisher page visibly loaded in the app's isolated persistent `WKWebView`. Extraction runs in that loaded page. The only Spoken Margins confirmation for an article package is **Create Item & Add Shared Interjections**. Podcast packages use the podcast resolver, create a confidently matched local item without autoplay or download, and remain context-only when no safe match exists.

## Direct-share attribution and excerpt matrix

This matrix is the engineering gate for issue #14. It is not a legal conclusion; rights copy still requires product-owner/legal approval before external enablement.

| Field or representation | Private local capture | Direct `.spokenmargins` share | Public/creator edition |
|---|---:|---:|---:|
| Canonical URL and source title | Retained | Required | Policy review required |
| Publisher/author/show and publication date | Retained when known | Included when known | Policy review required |
| Sender-reviewed transcript | Private | Included by explicit selection | Policy review required |
| Deterministically cleaned audio | Derived, immutable revision | Default audio representation after preview | Policy review required |
| Raw audio or raw transcript | Private | Always excluded | Always excluded by this contract |
| Sender-shortened anchor excerpt | Retained | Bounded to 500 characters before/after | Policy review required |
| Complete article/transcript/source audio | May exist locally under source rules | Always excluded | Out of scope |
| Diagnostics, API data, paths, unrelated turns | Private | Always excluded | Always excluded |

The recipient preview enumerates every outgoing field and attachment. Text-only sharing is explicit when timing or source audio is insufficient; raw audio is never silently described as cleaned. No AI cleanup is used.

## Deterministic cleanup v1

The app preserves timed speech segments and chunk offsets. `cleanup.v1` proposes case-insensitive removal of `um`, `uhm`, `uh`, `ah`, `ahh`, `er`, and `erm`. It proposes “you know” only at punctuation, utterance, or measurable-pause boundaries and preserves semantic uses. It does not remove “like.” Internal silence over 750 ms is reduced to 250 ms. Removed ranges use at most 40 ms padding and retained audio joins use 15 ms fades. Decisions are versioned and individually restorable without mutating the raw capture.

## Recipient behavior

Imported layers remain separate from local interjections and have recipient-local enable, mute, delete, and Fresh/Companion/Guided controls. Companion is the default. Resolved boundaries produce one versioned double chime for a cluster and show the sender label with **Interjection X of Y**. **Listen** is opt-in; ignoring the cue continues the source. Commentary playback pauses the source at the actual tap position, exposes **Return to Source**, and resumes the source at most once.

Replies target an immutable imported interjection. Their child package keeps the parent's `conversationId`, adds the parent package digest, and uses the parent's package-scoped interjection ID. It never re-exports or rewrites the parent's audio.

## Conservative anchoring

Article placement uses normalized-content digest and range, then unique exact quote with context, then a unique normalized candidate with a clear runner-up margin. Ambiguous and unresolved notes never cue inline.

Podcast evidence keeps episode identity, human anchor evidence, optional versioned machine evidence, and recipient-local resolution separate. Acoustic placement remains disabled until issue #27's held-out benchmark includes at least 200 eligible anchors, has zero false confident placements, and achieves p95 error no worse than 1.5 seconds. Until then, only exact-edition and transcript-verified placements cue inline.

## Audit and stopping rules

- Falsification target: a confidently wrong inline cue, an undisclosed outgoing field, source redistribution, or more than one source resume stops rollout.
- Omission check: malformed ZIP paths/symlinks/duplicates, size and expansion bounds, missing timing, semantic “you know,” dynamic ads, repeated material, source absence, duplicate handoffs, missing parents, and reply forks.
- Diagnostics remain local/exportable and record only package stage/failure, extractor provenance, anchor evidence class, cue count, and the resume invariant.
- External rollout remains blocked until package privacy/security and cleanup pass, one-way exchange is verified, the product owner validates the enumerated device flows, replies pass separately, and rights copy is approved.

## Human-validation checklist

- [ ] iMessage opens the attachment in Spoken Margins.
- [ ] Signal opens the attachment in Spoken Margins.
- [ ] Article flow shows the publisher page and needs one in-app create action.
- [ ] Podcast import creates a matched local item without autoplay/download.
- [ ] Companion tone, Listen, and Return to Source behave as specified.
- [ ] Safari fallback preserves and completes the pending package without duplication.
- [ ] Parent/child reply exchange converges when imported in either order.
