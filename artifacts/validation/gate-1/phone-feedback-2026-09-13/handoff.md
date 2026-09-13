# Physical-phone feedback repairs

Current uncommitted provisional-next source, based on de9dc82060a19c435d4045c30f957c04a4dbe871. Prior QoL work preserved. The owner authorized this repair pass and personal-phone testing, with a target of 10% weekly allowance remaining and a hard floor of 5%.

## Changes and evidence

- Podcast recovery: the copied phone record for On the Media / Haitians Live in a Dual State in Ohio Right Now claimed available_offline. Its recorded file was absent from the device’s PodcastAudio directory. Playback-time validation now demotes missing/incomplete files to a recoverable failure and clears stale local playback overrides. More and Item Detail expose download recovery even for allegedly downloaded audio. A start that remains pending for 30 seconds stops and explains recovery. A newly completed download may replace a pending start, while an already-playing stream stays intact.
- Render indicator: full native track width, positioned below the thumb. During native-text rendering it uses the same current-session percentage as More; the saved manifest remains the fallback outside that live progress. The phone’s flying-car manifest contained only two old chunks, explaining the tiny old indicator despite more current render progress. The live percentage describes total rendered work, not a promise that every earlier source span is contiguous/offline.
- Spotify follow: matched Apple episode metadata now resolves the matched show’s RSS URL. Existing source URLs no longer prevent fallback discovery. A fixture verifies Spotify → exact Apple episode → RSS; no blind show-title match was added.
- Share Sheet: accept a share containing a supported attachment even when the host includes extra attachment types or multiple extension items. The previous predicate required every attachment to be supported and exactly one qualifying item. Built bundle checks still verify declared types, principal class, and Safari preprocessing resource. System Share Sheet visibility requires owner recheck.
- PDFs: remove repeated text only in physical page margins, preserve the first page and interior occurrences, and exclude margin page numbers. The regression PDF verifies that repeated body text survives. Reported source: https://tsapps.nist.gov/publication/get_pdf.cfm?pub_id=957258 (NIST CSF 2.0). Existing saved source text/audio is not rewritten: import the PDF again for the new extraction, keeping the prior item if it has Margins.

## Quick owner recheck

1. Open On the Media → More → Download Again if needed. Once downloaded, press Play. Verify audible playback and that a failed start offers recovery instead of spinning indefinitely.
2. Render a native-text item. Compare More’s percentage with the line; verify both endpoints and clearance below the thumb.
3. Share a Safari page, a PDF, and a podcast episode. Confirm Spoken Margins appears (including the Share Sheet’s More list) and imports the selected content.
4. Import a Pod Save America Spotify episode and choose Follow Podcast. Confirm the correct show is followed.
5. Reimport the NIST PDF as a fresh test item and listen across page boundaries. Confirm headers are not repeated and body text remains.

No whole-Library reset is needed. Diagnostics are in Settings → Developer tools → diagnostic export. Verification is developer evidence, not human validation; the initial five owner checks were pending at installation. See the owner follow-up below. No commit or TestFlight publication is included.

## Final verification and installation

Fast plan passed. App tests: 426 initially passed; one existing database-lock failure passed on isolated retry, covering all 427. Audio-adapter checks passed after a simulator-launch stall and clean restart. Xcode built and signed the physical-device app; installation and launch on the owner’s iPhone succeeded without a reset or fixture arguments. Exact source/binary identity is in verification.json. This is local development version 0.1 (27), not a TestFlight upload.

Weekly usage moved 85% → 89% used; 11% remains (rounded account-wide meter). No reset credit was used.

## Owner follow-up — PDF contents

The owner reports “succeeded on the headers” and “everything else works.” Record the exercised podcast/download recovery, render indicator, Spotify follow, Share Sheet, and repeated-header behavior as human_validated for this personal-phone candidate. This is bounded acceptance of the reported repairs, not whole-app validation. The owner suspects a PDF table-of-contents regression; contents handling remains open pending diagnosis and clarification of whether the symptom is spoken contents entries, chapter creation, or both. The pre-header extractor already emitted detected contents entries as paragraphs rather than omitting them, so a new regression has not yet been established.
