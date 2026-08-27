# Build 19 External TestFlight Product-Owner Test Plan

- Prepared: 2026-08-21
- Version/build: 0.1 (19)
- Candidate commit: `738c743e202f5e700f4d6975adee52862f63c69f`
- Supported devices: iPhone and iPad on iOS/iPadOS 18.0 or later
- Current state: source commit accepted by the product owner; signed candidate
  uploaded and processed successfully; Build 19 is testing in the internal
  **Margins** group

## Decision This Plan Supports

Approve build 19 for external TestFlight only if the distributed TestFlight
binary preserves the product-owner-accepted native-text interruption fix and
passes the short release smoke below. This plan does not reopen acceptance of
`738c743`; it identifies the evidence needed for the exact binary Apple will
distribute.

## Test Record

Complete this table once per device used. Record `N/A` only when the test is
explicitly inapplicable to that device.

| Device | OS | Install source | Tester | Date | Overall result |
| --- | --- | --- | --- | --- | --- |
|  |  | TestFlight build 19 | Product owner |  | PASS / FAIL |

For any failure, record the checklist number, observed behavior, expected
behavior, whether it reproduces after relaunch, and the copied privacy-safe
diagnostics.

## Preconditions and Test Data

- Build 19 has completed App Store Connect processing and is installed from
  TestFlight, not Xcode.
- Delete an older install before the clean-install checks. A new library should
  seed **Welcome to Spoken Margins**.
- Have one public, playable podcast episode URL and one ordinary public article
  with readable body text available.
- Have one text-based PDF and, for the negative case, one scanned/image-only PDF.
- Use a native-text item long enough for James or Lily to finish generating
  prepared audio before the interruption check.
- If available, have AirPods or another Bluetooth route for the optional route
  smoke. Do not block external beta solely because that accessory is unavailable.

## In Scope

- exact-candidate installation and launch
- native-text playback interruption pause/resume behavior fixed by `738c743`
- system voice plus bundled James/Lily voice selection and Terms gate
- native-text and podcast playback, navigation, background controls, and
  interjections
- Safari readable-page capture, Share extension intake, text-based PDF import,
  and public podcast import
- truthful release boundaries: no account, no remote provider/API-key feature,
  no watchOS app, and graceful handling when Apple Foundation Models is
  unavailable
- diagnostics and feedback path needed by external testers

## Out of Scope and Known Limitations

- App Store submission or production review; this decision is only for external
  TestFlight.
- watchOS; build 19 contains no watchOS app.
- OCR; scanned/image-only PDFs must be OCR'd before import.
- Remote discussion, third-party API keys, and AI-generated Listening Maps;
  they are disabled in this release.
- Apple Foundation Models interjection summaries are optional and depend on
  device, OS, model availability, locale, and system settings.
- Safari intake is one user-invoked complete readable-page capture. There is no
  selected-text mode in build 19.
- Xcode may report the known upstream ONNX Runtime dSYM warning. Apple processing
  or crash-symbolication failures remain release-stopping even though the local
  archive/export succeeded.

## Release-Stopping Rules

Stop and fail the candidate for a crash, data loss, playback of the wrong item,
simultaneous/duplicate audio, playback that remains visually active but silent,
an interruption that cannot recover with Play, unexpected network/provider or
API-key UI, an unaccepted Terms bypass for James/Lily, a signing/processing
failure, or a privacy disclosure in diagnostics. Record lesser presentation or
copy defects as known issues and make an explicit ship/defer decision.

## Product-Owner Checklist

Record **PASS**, **FAIL**, or **N/A**, plus a short note, for each line.

### A. Installation and release boundary

1. [ ] Clean-install TestFlight build 19; confirm it launches and seeds
   **Welcome to Spoken Margins** without an account or sign-in.
2. [ ] Confirm Settings offers System, James, and Lily voices but no usable
   remote-provider or API-key setup, and no watchOS app is installed.
3. [ ] With Apple Foundation Models unavailable or disabled, confirm listening,
   deterministic native-text Listening Maps, publisher podcast chapters,
   interjections, export, and pasted-response import remain usable; the optional
   local summary reports unavailability truthfully.

### B. Native-text interruption regression — primary gate

4. [ ] Select James or Lily. Confirm the complete bundled Terms appear before
   first enablement; decline leaves the voice disabled, then accept and continue.
5. [ ] Start a long native-text item and wait for prepared audio to become the
   active playback path. Confirm audio, progress, title, and Play/Pause agree in
   the app and on the Lock Screen.
6. [ ] While it is playing, cause a real audio interruption (for example Siri,
   an incoming call, or another system interruption). Confirm playback pauses
   once, position does not jump materially, and no second audio path continues.
7. [ ] End the interruption. If iOS grants resume permission, confirm the same
   item resumes from the saved position. If iOS does not, confirm one tap on Play
   resumes it cleanly and the app explains that manual resume is required.
8. [ ] Repeat while playback was already paused before the interruption. Confirm
   it remains paused afterward and does not begin unexpectedly.
9. [ ] Repeat one interruption during System voice playback. Confirm the app
   remains controllable and resumes only according to the displayed state.

### C. Short external-beta smoke

10. [ ] Background and lock the device during native-text playback. Confirm
    uninterrupted audio and synchronized Lock Screen Play/Pause and skip controls.
11. [ ] Import and play a public podcast episode. Confirm title/episode identity,
    publisher chapters when supplied, scrub/skip behavior, and background controls.
12. [ ] Record one spoken interjection, allow transcription, and confirm its
    timeline anchor and exported session context are correct.
13. [ ] In Safari, invoke Spoken Margins on a readable public article. Confirm a
    single complete readable-page item opens in the app without a selected-text
    choice or automatic background capture.
14. [ ] Share a text-based PDF or text file to Spoken Margins and confirm import.
    Confirm an image-only PDF gives the OCR-required message instead of a blank
    or misleading item.
15. [ ] Copy **Settings → Copy Privacy-Safe Diagnostics** and inspect the result.
    Confirm it contains no private source text, transcript, email address, API
    key, personal file path, or stable device identifier.
16. [ ] Use the TestFlight feedback path and confirm the beta feedback email is
    present and usable before external testers are invited.

## Verification Evidence Already Available

The following evidence supports implementation and packaging; it does not
replace the physical-device checklist:

- contract validator: pass
- surface-contract validator: pass
- `SessionKit`: 150 tests, 0 failures
- focused iOS 18.6 prepared-text interruption regression: pass
- signed Release archive and local App Store export: pass
- exported app and three extensions: version 0.1 (19), iOS 18.0 minimum,
  Apple Distribution signing, Store profiles, `get-task-allow = false`, and
  `beta-reports-active = true`
- app and extension signatures: valid
- privacy manifests: present in all four bundles
- IPA SHA-256:
  `3b1f3eae0aa142656d6e25dded2d8b8824d29f73362e696cb26d51e2a9b195b2`

## Product-Owner Validation Update

On 2026-08-21, the product owner reported that all in-app behavior covered by
this plan is validated. The only unconfirmed item is the TestFlight feedback
email, which is App Store Connect metadata rather than executable app behavior
and therefore is not an app-regression concern. The device and OS were not
supplied with this result.

Build 19 was uploaded on 2026-08-21, completed Apple processing, and was added
automatically to the internal **Margins** group with six testers. Installation
of the exact TestFlight-distributed binary has not yet been reported. That does
not reopen the product-owner validation of commit `738c743`.

## Final Decision

- Product-owner result: **PASS / `human_validated`** for in-app behavior
- Approved for external TestFlight: **YES**, after the feedback email and
  remaining App Store Connect release operations are complete
- Device and OS: not supplied with the validation report
- Known issues accepted for beta: App Store Connect feedback email not yet
  configured; known upstream ONNX Runtime dSYM warning
- Failed checklist items and diagnostics: none reported for app behavior
- Product-owner notes: all validated except email
- Decision date: 2026-08-21
