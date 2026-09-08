# Follow prompt correction

Status: implemented and verified; not human_validated. Uncommitted changes on `codex/provisional-next`, base `8f5b74c889be28a29b110f8207cda7e207d9a208`. No build number change, phone install, or distribution.

## Findings and changes

- Feed fetching discarded the final response URL. RSS without a self link consequently assigned separate identities to redirect aliases. Fetching now retains the final response URL and resolves relative self links against it.
- Suggestion publication filtered only source IDs against subscriptions loaded before asynchronous discovery. It now checks current subscriptions after discovery, deduplicates source IDs and normalized feed URLs, and suppresses suggestions for an item whose source is already followed. Muted subscriptions still count as followed.
- Presentation filters stored candidates against current subscriptions. Accepting a suggestion records its canonical source on the originating item and immediately updates subscription state, preserving Follow suppression when returning to the item.
- Distinct feed URLs with identical titles remain distinct. No title-based merging of candidates or host-wide suppression was introduced.

## Verification

- Fast plan passed: `artifacts/test-runs/20260908-095207-831718-fast/manifest.json`.
- App plan passed: 392 tests, zero failures; `artifacts/test-runs/20260908-095233-268265-app/manifest.json`. Simulator build and bundled contracts passed.
- New controlled-response regression reproduces multiple alias requests with a single final feed URL and no feed self link; asserts a single candidate and the same subscription identity. This catches the original request-URL identity bug.
- Candidate regression checks repeated evidence, legacy IDs with equivalent normalized URLs, muted subscriptions, and a distinct same-title feed as a negative control.
- Controlled asynchronous regression adds a subscription during discovery and asserts no prompt or persisted prompt decision afterward. Existing stale-item discovery coverage remains passing.
- `git diff --check` passed.

The worktree already contained scrubber, diagnostics, preparation, and other changes. Those were preserved; the manifests fingerprint the combined working tree. This evidence does not assert physical-device acceptance or resolve unrelated preparation/scrubber reports.
