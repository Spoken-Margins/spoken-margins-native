# Gate 1 guided-tour Timeline validation — version 0.1 build 8

## Build identity

- Date recorded: July 24, 2026
- Marketing version: `0.1`
- Build number: `8`
- Base commit: `4d69cd9` (`4d69cd91792dc3e1719efd3f68d2567083b65030`)
- Source branch: `codex/interactive-onboarding`
- Validation target: the working-tree guided-tour Timeline fix based on the commit above
- Supported devices: iPhone and iPad
- Minimum OS: iOS/iPadOS 18.0

## Validation state

- `implemented`: successful Timeline navigation now records the `reviewed_timeline` onboarding milestone.
- `verified`: the focused simulator tests and contract validators listed below passed.
- `human_validated`: **PASS — the product owner confirmed the corrected step-two flow is human validated.**

## Product-owner evidence

On July 24, 2026, after reporting that step two could not previously be completed and receiving the corrected Timeline completion behavior, the product owner stated: “Human validated. Thanks!”

The device model, OS version, and granular pass/fail notes were not supplied. This record preserves the exact scope and acceptance without inferring those details.

## In-scope flow

1. Start the guided tour.
2. Complete the practice-interjection step.
3. Use **Show Timeline** to reveal the Timeline.
4. Tap a Timeline chapter or another interactive Timeline entry.
5. Confirm step two completes and the guided tour advances to the optional-AI step.

## Out-of-scope flows

- The remaining guided-tour steps beyond confirming advancement to optional AI.
- Voice consent and voice-switch playback behavior.
- Other app, Watch, widget, browser-extension, and sharing flows.
- Devices and OS versions not reported by the product owner.

## Automated verification

Run on July 24, 2026 from the validation working tree:

- [x] `Gate1AppModelWorkflowTests.testGuidedOnboardingTimelineChapterCompletesReviewStep` — passed on an iPhone 16 Pro simulator running iOS 18.6.
- [x] `Gate1AppModelWorkflowTests.testGuidedOnboardingAdvancesOnlyFromCompletedProductActions` — passed on the same simulator.
- [x] `scripts/validate-contracts.py` — passed; 22 Supertonic files validated.
- [x] `scripts/validate-surface-contracts.py` — passed.

## Result and known issues

- Result: **PASS**
- Known issues reported during this validation: none.
- Evidence gap: device model, OS version, diagnostics export, and granular checklist notes were not supplied.
