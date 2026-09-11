# External TestFlight sharing decision — proposed September 11, 2026

Status: proposed for product-owner acceptance under issue #14. This is a concrete product policy, not an assertion that a warning, a private destination, a fingerprint, or a character limit supplies legal permission. Builds and tests do not approve this policy. External distribution remains gated until the owner records a decision for the exact candidate.

## Candidate and audience

Prepare the current `codex/provisional-next` development candidate, including the preserved second-edition work and September 11 stabilization. It is not the internally uploaded Build 26 binary. The intended sequence is verified internal Margins rollout, owner product and policy validation of that candidate, then external TestFlight review. Keep direct, user-initiated file exchange as the supported sharing model. Public posting, commercial creator editions, federation, classroom/co-op protocols and hosted redistribution remain outside this release's supported product scope. A file recipient can nevertheless copy or forward a file; the app cannot enforce a trusted audience after export.

## Representation and destination matrix

| Destination / material | Proposed default and consent | Attribution and disclosure | Evidence boundary |
| --- | --- | --- | --- |
| Private session/AI handoff or PKM export | Selected scope and visible export controls; source text inclusion is a separate explicit choice. Retain existing user-selected preferences; do not infer that a destination grants rights. | Source title/reference when available; note target identity, source versus assistant/summary target and bounded context remain distinct. | Session export isolation and prior-build persistence tests. Full conversation export is distinct from minimal selected-note export. |
| Direct `.spokenmargins` reference | Reviewed selected Margins and public source identity; recipient acquires source separately. | Title and actual available author/publisher/feed/episode/reference fields. Missing facts remain absent, never invented. | Verified archive round-trip and exact preview; no source audio or full podcast transcript payload. |
| Direct recipient-supplied item | Source omitted. Recipient supplies and verifies the matching edition. | Exact source identity/hash and bounded anchors where available; source ownership does not transfer on import. | Wrong-source, ambiguous-anchor, exact-local-audio and import-persistence checks. |
| Direct embedded linkless text | Only app-authored content or sender's explicit rights confirmation. Declining must still permit recipient-supplied export. | Preview states that complete listened-to text is included and gives its size; confirmation is the sender's assertion, not legal verification by the app. | Embedded-text versus recipient-supplied fixture and transport/rights rejection tests. |
| User voice and reviewed wording | Only the representation selected and reviewed for that Margin. Written/text-only notes send no recording. Original voice is permitted only when explicitly selected. | Distinguish original voice, deterministic cleanup, text, summary and synthetic TTS. Do not label synthetic voice as an authentic recording. | Per-representation fixture, original preservation and unselected-audio omission tests. |
| Source anchor excerpts | Bound to the existing maximum of 500 characters before, 500 after and 1,000 exact; sender can shorten. These are engineering limits, not a copyright safe harbor. | Exact outgoing excerpts must be inspectable before Share; ordinary reference transport does not waive rights in excerpts. | Bounded-context, stale-preview and digest-integrity tests. |
| Acoustic matching evidence | Existing default-on option remains explicitly visible and reversible before preview. Turning it off must omit both per-note signatures and edition-wide signature spines. | Matching evidence is not playable source audio; this does not establish legal permission, anonymity or absence of publisher restrictions. | Exact archive inspection with option on/off, including stored edition landmarks. |
| Listening Maps and transcript phrase sketches | Disclose their actual inclusion and size/content in the verified preview; do not imply that turning off acoustic signatures removes independent text-derived evidence. | Label map summaries and their provenance; disclose sketches/hashes and any supplied summary/TTS voice assets. | Optional artifact fixtures, generated preview and asset integrity checks. |
| Public / commercial / federated use | No new product authorization. A private-share rights assertion must not be described as permission for these destinations. | Separate rights review before adding these product modes. | Omission check: no new publishing service, account or remote deletion promise. |

## Sender/recipient copy

Show this before sending and in the app’s verified recipient preview. Keep the existing digest-verified `preview.md` wire rendering unchanged so previously created packages remain readable:

> Source material may be protected by copyright. Share only material you have permission or another lawful basis to share. Attribution, a short excerpt, or a private recipient does not by itself grant permission.

> Recipients can keep or forward this file. Deleting your local copy cannot revoke their copies. Review the source excerpts, matching evidence, and voice or generated content before sharing.

Retain visible unsigned/unverified sender identity. A digest proves integrity, not identity or rights. List actual representation provenance and the outgoing source/anchor fields; do not rely on a generic “only reviewed Margins” sentence to disclose optional artifacts.

## Retention and failure behavior

Private recordings/transcripts remain immutable when creating derivatives. Private stars/notes, diagnostics, credentials, device paths and unrelated sessions stay out of packages. Exported files persist wherever the user sends them; recipient deletion is independent. Import must reject corrupt or mismatched assets before creating durable recipient data. Cancelling or invalidating preview must prevent stale-file sharing. No remote revocation or guaranteed deletion of recipient copies is promised.

## Evidence and stopping rules

Audit the exact candidate's archive, not screenshots alone: compare each included artifact/asset against the sender's choices, round-trip and verify its digest, then inspect preview wording. Test the negative case by disabling acoustic evidence while edition-wide landmarks exist. Compare source and two AI-turn Margins with identical percentages to expose coordinate-space confusion. Retain failed checks and exact candidate hashes.

Stop external readiness for an undisclosed outgoing artifact, acoustic opt-out bypass, source audio inclusion, unreviewed original voice, wrong-context Margin, stale preview that can still be shared, misleading authorship, or an unapproved rights assertion. Close the engineering gate when the relevant focused checks and full required release checks pass; only the owner closes the product and policy gates.

## Source-backed limits and questions for qualified review

Apple's [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) apply to TestFlight beta distribution (§2.2) and require appropriate intellectual-property rights (§5.2). Apple's acceptance of a prior build does not determine permission for newly exposed sharing behavior. The U.S. Copyright Office explains that [fair use is fact-specific and has no fixed permitted word count or percentage](https://www.copyright.gov/fair-use/). Sources checked September 11, 2026.

Qualified review is appropriate for any disputed source license, publisher/provider restriction on fingerprinting or transcript derivation, copyrighted full-text redistribution, or planned public/commercial edition. No legal conclusion about those cases is supplied here. TestFlight review metadata must describe the actual build and its sharing behavior without claiming blanket fair-use protection.

## Owner decision record

- [ ] Accept this bounded policy and the exact sender/recipient wording for direct external TestFlight sharing, or record a specific amendment.
- [ ] Confirm the final candidate's own-device sharing/import/listening and real-Library upgrade checklist.
- [ ] Confirm internal rollout evidence before external application.

Decision, date, candidate build/commit, devices, observations and any excluded flows: pending.
