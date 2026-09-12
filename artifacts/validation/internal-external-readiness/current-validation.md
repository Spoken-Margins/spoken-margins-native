# Current product-owner validation checklist

**Latest retry:** [September 12 failures, repairs and recheck](september-12-retry.md). This supersedes the earlier six-row worksheet where observations changed. Older-session sharing, Skim behavior/speech speed, and Library icons are now owner-accepted. Copy executes correctly. Margin-detail tap feedback still fails, and shared-layer opening still hangs for about one second. See the latest retry for remaining checks.

**Owner update:** [Build 27 validation and six exceptions](build-27-owner-validation.md). The owner accepts all other checklist flows. Use the exception record for current rechecks; repairs require their own evidence.


Start here for the current candidate. [Historical handoff](handoff.md) preserves the earlier release/archive evidence; [efficient test procedure](efficient-test-procedure.md) governs engineering verification. Do not use the earlier IPA to validate the chapter fixes.

## Candidate and setup

- Local version: **0.1 (27)** on `codex/provisional-next`, uncommitted repairs based on commit **4fbb131b7c7b1c8a86aabd6a6474ed7ec3c0cb60**. Build number alone is insufficient: the earlier archive also says 27.
- Verified implementation input: `924ffb51430c18341f95b31496d79e023e8a90c4b6e9620a241744a0e62d0203`. Rechecked against the current checkout on September 12.
- Engineering evidence: **417 app tests and one scoped quick-tap UI test passed, zero failures/skips**; fast checks passed. Recorded Simulator frames show the button highlight. Prior audio evidence is historical; audio implementation is unchanged in this latest patch. Evidence is recorded in the [September 12 repair evidence](september-12-retry.md). Device scrolling performance is not yet measured or accepted.
- **Installation identity pending:** the earlier Build 27 IPA predates these fixes. A fresh development install or refreshed release archive must be tied to this source before results count for this candidate. This document does not claim an install or upload occurred.
- Supported deployment: iPhone/iPad, iOS/iPadOS 18+. On-device intelligence is conditional on supported hardware/OS and configuration; the deployment minimum does not guarantee generation support. App tests used iPhone 17 Pro Simulator / iOS 26.5. Physical device acceptance remains pending.
- Preserve the real Library. Update in place; do not delete/reimport the Dwarkesh item to diagnose its scrolling. For a disposable Simulator only: Library → Settings → Developer tools → Reset Library and Load Sample → Reset Library.
- Content: keep the reported Dwarkesh episode with its **24 generated scenes and summaries**. Record its exact title/URL. Use seeded **You Can't Inspect the Pill** for text preparation/capture, a long disposable assistant response, and a permitted test Margin package for sharing. Use a separate test episode with published timestamped show notes to check new metadata import; existing items are not automatically backfilled.
- Diagnostics: Library → Settings → Copy Privacy-Safe Diagnostics. For a failure, enable Record Device Diagnostics, reproduce once, export, and turn recording off when finished. Keep private content out of public reports.

Record once: installed build/source identity ___; install date ___; device/OS ___; episode title/URL ___; playback state ___; text size ___; diagnostics location ___.

## Current recheck scope

Use the latest checklist in [September 12 retry](september-12-retry.md), plus any earlier exception not explicitly accepted. All other original worksheet flows are `human_validated` by the owner's Build 27 report. That acceptance is retained; it does not establish acceptance of these subsequent repairs.

For publisher chapters, use the exact Apple link recorded there in a disposable import. Existing items are not automatically backfilled. Preserve the real 24-scene item for the paused/playing scrolling comparison. No map regeneration or Library reset is required for the other checks.

Record Pass, Fail, or Not tested for each exception. After one failure reproduction, save diagnostics and continue independent rows. If scrolling still lags, record the screen, playback state and a short reproduction with diagnostics enabled; automated passes do not settle device performance.
