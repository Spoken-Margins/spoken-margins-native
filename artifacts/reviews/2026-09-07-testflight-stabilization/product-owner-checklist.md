> Superseded in part by the owner's [September 7 device feedback](../../validation/gate-1/2026-09-07-device-feedback.md): several flows were accepted, while scrubbing, import continuity, Library access, startup preparation, and Continue Listening failed. The identity and verification below describe the earlier candidate, not the subsequent remediation. Current remediation starts from commit `8f5b74c`.

# Candidate acceptance checklist — not yet human validated

## Identity and device scope

This is a local working-tree candidate on `codex/provisional-next`, HEAD `90d08c19ddf957c70b8a34077f73a58f92771544`, version 0.1 (25). It contains uncommitted changes, including pre-existing audio-policy and test-infrastructure work. The final verification manifest's input hash identifies the tested inputs. This is not an uploaded build or an assertion that distributed Build 25 contains these changes. Reconcile App Store Connect Build 26 references before assigning an upload number.

Configured support: iPhone and iPad, iOS/iPadOS 18+. Automated evidence records the actual simulator/runtime; it does not establish coverage on every supported OS. Watch work remains archived. Physical audio, thermal and loaded-library behavior require the product owner's device.

## Preparation, sample and diagnostics

Preserve the existing content-heavy device library for #93/#97. Relaunching is sufficient to test persistence; do not reset or reinstall that device as a troubleshooting shortcut. On a disposable test library only, Settings → Reset Library and Load Sample permanently deletes that library and loads **You Can't Inspect the Pill**. Add a long pasted response and two unrelated feed episodes for identity/navigation checks.

Use Settings → Copy Privacy-Safe Diagnostics after each failure. Record item title, playback target, elapsed wait, device/OS, exact build identity and pass/fail notes alongside the export. Keep owner acceptance evidence under `artifacts/validation/gate-N/` for the assigned release gate; these review files are not an acceptance record.

## In-scope checks

| Flow | Required observation | Owner result / notes |
|---|---|---|
| First Supertonic chunk | Playback starts with the first available chunk; delayed synthesis yields a bounded fallback rather than an indefinite spinner. Assess the initial 15-second limit on device. | Pending |
| Completed source | Mark Complete persists after relaunch; old partial sessions and unfinished assistant turns do not return the source to Unplayed/In Progress or enqueue automatic synthesis. | Pending |
| Prepared source replay | Replay compatible complete audio without new synthesis; explicit render remains available for an intentional incomplete artifact. | Pending |
| Assistant response | Resume at midpoint, scrub/skip while paused, then play; the chosen response advances from that point, and source completion remains unchanged. | Pending |
| Stop / Retry | Retry immediately resumes on-device work for the current target and position; a paused target stays paused. | Pending |
| Notes on long response | Create an interjection, leave/reopen the response and retrieve it; inspect prior reported missing notes separately. | Pending |
| Follow suggestion identity | Rapidly open two unrelated items; late discovery from the first never appears on the second. Multiple feeds expose distinguishable URLs. | Pending |
| Feed episode import | Known title, source and author survive import; another active item's playback stays unchanged. | Pending |
| Browser article import | Representative article imports readable content through the app-owned browser; generic payload tests do not replace this route. | Pending |
| Loaded library responsiveness | Paired idle/active-preparation traces and accepted Quick Add, scrolling and navigation behavior on the original content-heavy physical phone. | Pending |
| #84 combined playback control | Sticky drag followed by seek and continuing progress behaves correctly in the same session. | Pending |

## Known limits and exclusions

No physical-device performance comparison is available. Existing Safari PDF route proof is from September 4 and is developer verification. #14 still governs external sharing/distribution acceptance. Broad UI redesign and figure narration are outside this stabilization scope. No claim that previously missing historical notes have been recovered.

An intermittent imported-podcast test failed twice with a persistence write error, then passed a full app rerun and 15 consecutive targeted iterations. SQLite write errors now include the extended code and message to support diagnosis if it recurs; passing reruns do not explain the earlier failures. See implementation.md for final gate results and retained failures.

## Final automated verification

- Full release gate: **414/414 app, adapter and UI tests passed**, no skips, including the exact emoji speech canary. Fast checks passed with 262 package tests and the one named permitted benchmark skip.
- iPad: **5/5 focused UI tests passed**.
- Generic iOS device build and whitespace checks: passed.
- Both final test manifests report `verified`, input SHA-256 `827ebc43e6cc0a8674c12be6ae2ca8b4bb3e251a54c8e12baa894ecbbc79b554`.
- Evidence: `artifacts/test-runs/20260907-125017-904309-release/manifest.json` and `artifacts/test-runs/20260907-124523-268051-ui/manifest.json`.
- The physical phone later became available with developer-installed 0.1 (25). Its exact source SHA is unknown, and the coordinated workload capture remains pending. No new candidate was installed on it by this task.

These results establish automated verification, not product-owner acceptance. The original checklist rows above preserve the prior handoff; use the linked owner-feedback record for subsequent bounded acceptance and failures.
