# Podcast anchor reliability plan

**Goal.** When a listener shares Margins on a podcast, the recipient hears each Margin at the right moment in *their* copy of the episode. The recipient's copy may differ from the sender's: dynamically inserted ads, a different host, a re-encoded file. When the app can't be sure of the position, it says so and still plays the voice. A confidently wrong position is worse than an honest "needs confirming".

Issue: #27. Branch: `anchor-reliability`.

## How positioning works today

- **Sender.**
  - A Margin stores its source timestamp and text context.
  - For podcasts, the engine also asks the audio player for two short audio fingerprints (ShazamKit signatures): about 12 s before the Margin and about 12 s after playback resumes.
  - A continuous tap on the podcast player keeps a 20 s ring buffer so the "before" sample is available.
  - Code: `SessionEngine` (interjection completion), `PostResumePodcastEvidenceCapture.swift`, and `AudioAdapters.swift` (media client and router).
- **Packet.** The fingerprints travel with the Margin as evidence assets (`SessionKitSharing`).
- **Recipient.**
  - `PodcastAnchorEvidence.swift` matches the fingerprints against the recipient's episode and classifies the result: acoustically verified, ambiguous, or unresolved.
  - Transcript context is the fallback. A bare timestamp is never trusted on its own, because an inserted ad shifts everything after it.
- **Benchmark.** `scripts/run-podcast-anchor-benchmark.sh` builds a held-out pair of editions with inserted speech. The gate is **zero false-confident placements** and **p95 error ≤ 1.5 s**.

## Status

| Slice | What | State |
| --- | --- | --- |
| 1 | Router forwards capture calls to the media player | **implemented, verified (host test).** In every shipped build through 28, capture silently never ran, so no shared podcast Margin carried fingerprints. |
| 2 | Prove capture on a device | **human_validated on Build 29 (`fcc4974`).** The owner's packet from a streamed episode carries stream-captured pre/post evidence and an episode landmark, all 11.05-11.15 s. Two blockers found on the way: starting a Margin stopped the shared router and discarded the player and its tap; the tap was installed before the item had tracks (#154). |
| 3 | Make capture durable | **mostly done.** Verified on the host and simulator: tap installs once the audio track loads (#154); Margins no longer discard the player; failure reasons kept as a history, session-qualified diagnostic keys, stored outcomes in the export (#155). Stream source context (#156) now comes from the tap: a rolling minute before the Margin and up to a minute after resuming, as heard, transcribed on device (branch `play-this-moment`, verified on the simulator). Remaining: signature work off the audio callback. A Margin recorded within ~16 s of a start or seek has no pre window (inference: too little buffered audio). |
| 4 | Export and compatibility | **verified.** Packets need only `commentary-layer.v1`, so Build 28 still opens them. Evidence recorded before Build 29 is 12.011 s and cannot be queried; those Margins stay unresolved and still play their voices. |
| 5 | Recipient matching, benchmark-gated | **human_validated for one episode.** Evidence is 11 s (ShazamKit rejects queries over 12 s) and the recipient edition is signed in overlapping 15-minute chunks (one whole-episode reference stopped matching partway in). Host: a DS 55 packet placed all four Margins within 10 ms on the same edition and with a 30 s ad inserted; benchmark 0 false-confident, p95 4 ms. Owner: placement worked on the phone. Adversarial cases with host tests: an ad inserted between a Margin's flanks, and the wrong episode sharing the sender's intro (#456). Remaining: a repeated intro or outro within one episode (#331). |
| 6 | Recipient experience for uncertain Margins | **implemented, verified (simulator), branch `play-this-moment`.** Tapping a shared Margin in the Timeline plays its moment at the best known position (verified match, else neighbour-interpolated, else the sender's time), labelled approximate unless verified (#158). No manual placement: the owner rejected confirm-by-ear. Remaining: the owner's J5 check on an edition with different ads. |

Update this table as slices land. Don't add history paragraphs; the commits are the history.

## Slices

Each slice is one or a few commits, host tests that fail without the change, and the relevant journey (J3, J5 in [journeys.md](journeys.md)). Port code from `park/co-op-2026-09-24` only when it fits the slice. Read it, keep what's good, and fix the known defects listed below. Don't bulk-copy.

**2 — Prove capture on a device.** Build 29 with slice 1.

1. The owner plays a streamed episode and records three Margins.
2. Export diagnostics and confirm each Margin shows committed pre/post evidence, or a specific reason why not.
3. Listen for audio glitches right after each Margin. The tap now does signature work for about 12 s.

If the diagnostics can't answer this, add a minimal per-Margin evidence line first. This slice decides whether slice 3 needs to be large or small, so do it before writing more capture code.

**3 — Make capture durable.** Only what slice 2 shows is needed. Candidates from the brief:

- Separate outcomes for the pre and post windows, so one failing doesn't erase the other.
- Retry once the audio track is ready.
- Session-qualified IDs, since `ij-001` repeats across sessions.
- Survive relaunch.
- Move signature generation and allocation off the real-time audio callback, keeping the callback to a bounded copy.

Parked reference: `SessionEngine.swift` capture windows, `PostResumePodcastEvidenceCapture.swift`, `SpeechRecognitionQueue.swift`.

**4 — Export and compatibility.**

- Export reads the Margin's current evidence.
- A Margin with no evidence (every Margin recorded before slice 1) still exports without blocking, marked "no positioning evidence".
- Packets must still import into Build 28. Add fields additively and don't add a required manifest capability.

Parked reference: the evidence export gate in `Gate1AppModel`. Fix two defects from the park first:

- Empty evidence was treated as "still preparing", which blocks every old Margin.
- It read absolute asset paths without rebasing them to the current app container.

**5 — Recipient matching.**

- Improve `PodcastAnchorEvidence` resolution: check uniqueness across the whole episode, handle single-flank evidence conservatively, and add bounded transcript recovery around the hinted position.
- Every change runs the benchmark. Add adversarial cases: a repeated intro or outro, an ad inserted between the Margin and its post sample, and the wrong episode.
- The gate never loosens.

Parked reference: `PodcastAnchorEvidence.swift`, `RecipientTranscriptRecovery.swift`.

**6 — Recipient experience.**

- Every imported voice plays directly regardless of placement.
- For an unplaced Margin, "listen around the suggested spot" lets the recipient confirm a position. Store it as user-confirmed, distinct from acoustically verified.
- Parked defect to fix: episode hashing ran on the main thread (about 100 MB of SHA-256), which freezes the UI.

**Done when** J5 passes on the owner's phone with a real episode that has dynamic ads. Download it on two devices at different times so the editions differ. Placed Margins must land within about 1.5 s by ear, and unplaced ones must say so.

## Out of scope unless measurements demand it

- Cloud speech recognition.
- A custom decoder.
- Downloading full episodes only to fingerprint them.
- A second fingerprint algorithm.
- A server.
- The co-op conversation features, parked separately.
