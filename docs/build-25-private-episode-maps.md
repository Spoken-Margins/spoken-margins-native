# Build 25 Private Episode Maps

Build 25 creates a private, edition-specific episode map from independent evidence. The sender can combine exact decoded-playback signatures, source-window reference signatures, sparse playback landmarks, salted transcript phrase sketches, and Margin-local transcript context. Exact decoded-playback evidence outranks re-fetched streaming references.

The recipient starts from an explicitly approximate source timestamp while its episode downloads. Alignment then chooses a maximum-weight order-preserving landmark sequence. It verifies a position only with exact-edition identity, or with independent corroboration across acoustic, transcript, and monotonic-neighbor evidence. Stable equal-offset segments may be interpolated; changed offsets bracket an edition change but never classify an advertisement. Ambiguous repeated audio, silence, conflicting identity, missing passages, and out-of-order candidates remain unresolved.

## Source import identity repair after Build 27

Local Library identity must be established before a map or other derivative can be reused. New resolved-audio imports use an `item-source-v2-` SHA-256 identity: followed imports supply their subscription and feed-entry identity; other imports use the complete resolved audio URL, preserving query parameters and path case. Titles, show names, generic filenames such as `default.mp3`, and truncated title prefixes are not identity evidence.

Repeated import of that identity retains its existing media edition, transcript, creation date and private map, and restores a trashed item. Feed metadata can update the displayed title, author and source. A newly resolved URL does not silently replace an already-anchored media edition; publisher chapters and transcript discovery cannot attach evidence from a different URL to the retained edition. Direct-URL aliases without a feed identity may create separate items rather than being guessed equivalent.

Legacy title-slug records remain intact. Reimport creates an isolated new record instead of adopting derivatives with uncertain ownership. This prevents further collisions but does not assert that an already-mismatched legacy map has been recovered or reassigned correctly. The diagnostic and repair evidence is in `artifacts/validation/gate-1/2026-09-12-build-27-episode-map-article-feedback.md`.

## Privacy boundary

Decoded PCM remains in a bounded memory-only ring and is never exported. Download preparation uses a transient timed transcript. After the fingerprint spine, phrase sketches, scene proposal, local projection, and bridge preparation commit, the job deletes its transcript and temporary audio caches. Share packages may contain scene summary text, fingerprint signatures, and phrase sketches; they never contain decoded PCM, a complete transcript, or rendered summary audio.

Phrase sketches use normalized overlapping three-token shingles, omit stopword-only shingles, and retain the bottom 24 HMAC-SHA256 values per timed window, truncated to 128 bits. Each map has a random public salt. This reduces accidental text exposure and prevents direct equality across salts, but it is not cryptographic protection against dictionary attacks. An attacker who can guess likely phrases can hash those guesses with the public salt. The release tests therefore include common phrases, repeated intros, reordered speech, collisions, and dictionary-guess simulations, and product copy must not describe sketches as anonymous or irreversible.

## Stopping and rollout rules

Verified placement requires zero false-confident placements in the held-out cross-edition corpus and p95 placement error no greater than 1.5 seconds. Abstention is preferable to an incorrect verified result. Local scene generation and Skim ship only when physical-device latency, thermal, memory, and grounding checks pass; fingerprint maps, phrase sketches, imported maps, and recipient alignment do not depend on local summaries. There is no server fallback, public catalog, contribution credit, or automatic ad classifier in this build.

Automated checks can mark implementation `verified`. Only the product owner can mark playback, sharing, and Skim flows `human_validated`.
