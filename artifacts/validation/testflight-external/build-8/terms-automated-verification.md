# Versioned Terms automated verification — Spoken Margins 0.1 (8)

Status: `implemented` and `verified` by the automated evidence below on July
23, 2026. The product owner has not yet `human_validated` the flow. Legal review
of enforceability and OpenRAIL-M sufficiency remains required.

Source baseline: `1f8f6ef0ef937df6aa2933969af6dad7bc9d9840` plus the
versioned-terms working tree. Replace this description with the final commit SHA
when the submission build is created.

## Implemented contract

- Apple Standard EULA remains selected; no custom App Store Connect EULA is
  required by the implementation plan.
- Spoken Margins Terms version 1.0 are bundled for offline presentation and
  have a corresponding public HTML page.
- A stored James or Lily selection falls back to the iOS system voice if the
  accepted version is absent or stale.
- Selecting James or Lily without current acceptance presents the Terms and
  preserves the requested voice as a pending selection.
- Agree stores the current version and timestamp locally and enables the
  pending voice.
- Not Now leaves the system voice enabled and records no acceptance.
- The Supertonic renderer boundary independently rejects use without current
  acceptance or without the bundled Terms resource.

## Automated evidence

- Full `SpokenMarginsAppTests`: 121 tests passed before the final fail-closed
  resource check; the focused Terms suite passed again after that check.
- Focused Terms tests cover version storage/expiry, bundled-clause presence,
  first-run fallback, pending-voice enablement, refusal behavior, persisted
  acceptance, and the renderer-boundary precondition.
- Generic iOS Simulator build passed.
- Generic iOS device build passed.
- Contract and surface-contract validators passed.
- All site HTML parsed successfully and bundled/public key-clause parity
  passed.

## Remaining evidence

- Product owner: install the candidate cleanly, confirm the system voice works
  before acceptance, select both James and Lily, review the complete Terms,
  exercise Agree and Not Now, relaunch, and confirm acceptance persistence.
- Product owner: deploy `/terms/` and confirm public HTTP 200 plus visual
  readability on phone and desktop.
- Legal: approve the version 1.0 text and confirm the affirmative in-app
  agreement satisfies paragraph 4(a) of the bundled OpenRAIL-M license.
- Release: record the final build number and commit SHA. If build 8 has already
  been uploaded to App Store Connect, increment the build number before upload.
