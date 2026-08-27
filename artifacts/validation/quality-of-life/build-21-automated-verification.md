# Build 21 Non-Watch Quality-of-Life Handoff

Status: `implemented` and locally `verified`; not `human_validated` and not yet a
shippable release candidate because the production onboarding endpoint is not
deployed.

## Candidate

- Version/build: Spoken Margins 0.1 (21)
- Branch: `codex/quality-of-life-next`
- Runtime SHA: `dcad5f08b15bca5b28051a17b804cddd8954f77e`
- Supported devices: iPhone and iPad on iOS/iPadOS 18.0 or later
- Watch scope: excluded; no Watch build is required for this release

## In scope

- Durable prepared Supertonic audio and truthful completed-media scrubbing
- Unified offline storage lifecycle and power-aware preparation horizon
- DRM-free EPUB and local audiobook import
- Opt-in charging-only background preparation
- Guided onboarding and followed-source inbox/suggestions
- Library search/filter/sort and session-scoped sleep timers

## Out of scope

- Issue #75 and all new Watch playback, transfer, rendering, connectivity, and
  synchronization work
- OCR for image-only books or documents
- Any promise that iOS will complete preparation overnight
- Product-owner acceptance, TestFlight upload, or App Store submission

## Known issues and blockers

- `https://spokenmargins.proximitytoprogress.com/onboarding/v1/manifest.json`
  currently returns 404. The repository contains the bounded manifest and audio,
  but deployment is blocked because the configured VPS SSH credential is rejected.
- AVFoundation's older chapter-loading API emits deprecation warnings; it remains
  in use because the async replacement currently violates Swift 6 isolation in
  this integration. Import behavior builds and is covered by focused checks.
- Physical-device duration/scrubbing, audio interruption, background scheduling,
  thermal/power transitions, and security-scoped file picking remain for the
  product owner.

## Automated evidence

- Contract validator: pass
- Surface-contract validator: pass
- SessionKit build/tests: 181 pass, 0 failures, including concurrent SQLite
  connection regression
- Generic iOS Simulator build: pass
- Generic iOS device build: pass
- App unit tests: 248 pass, 0 failures
- Broad simulator route suite: 12 pass, 0 failures
- Runtime Kokoro/MLX scan: no app/package/project matches
- Watch runtime diff audit: no changed Watch runtime files
- Guided-tour local manifest/audio SHA-256: match

The broad simulator run initially exposed an SQLite connection race when the
offline ledger inventoried assets while the timeline decoded interjections. The
app trapped in `sqlite3MutexMisuseAssert`. The repository now serializes the
shared connection, opens it in full-mutex mode, and includes a concurrent
read/write regression test. This is the prior failure mode the final rerun must
falsify.

The final Xcode run succeeded while logging intermittent
`DebuggerLLDB.DebuggerVersionStore.StoreError` / `no debugger version` warnings.
Those warnings did not terminate the app or fail a test. The earlier product
crash was separately symbolicated to `sqlite3MutexMisuseAssert` and is covered by
the new repository regression.

## Reset, sample data, and diagnostics

- Reset: Settings > Storage & Testing > Reset Library and Load Sample, then
  confirm Reset Library.
- Seeded clean-install items: welcome text and the guided audio tour. A bundled
  playable fallback is used when the production manifest is unavailable.
- Diagnostics: Settings > Diagnostics > Refresh Diagnostics, then Copy
  Privacy-Safe Diagnostics. Network evidence records redacted hosts/errors only.

## Product-owner checklist

Record PASS or FAIL plus brief notes. Save accepted evidence under
`artifacts/validation/quality-of-life/`.

- [ ] Terminate during each preparation stage; relaunch and confirm valid chunks
  are reused, corrupt/stale output is rejected, and Stop/Retry is truthful.
- [ ] Confirm playback can start after two chunks without a fabricated complete
  duration; after final adoption, Lock Screen duration and scrubbing agree.
- [ ] Change voice/model inputs and confirm repreparation is required; change
  playback speed and confirm it is not.
- [ ] Exercise storage choices, protected overage, safe clearing, and low-space
  failure without losing imported or active media.
- [ ] Import nested-navigation and malformed/protected EPUB samples; verify
  authored hierarchy, chapter jumps, rejection behavior, and interjection anchors.
- [ ] Import supported audiobook formats with chapters and reject a duplicate,
  protected, zero-duration, and interrupted copy without orphaned items.
- [ ] Enable While Charging and verify unplug, Low Power Mode, thermal pressure,
  expiration, force-quit, relaunch, opt-out, deletion, and low-space boundaries.
- [ ] Verify clean-install/upgrade onboarding, dismissal tombstones, all compiled
  import routes, checksum update behavior, and offline fallback.
- [ ] Follow single- and multi-feed sources, refresh/304/failure behavior, inbox
  seen/dismiss/import, mute, unfollow, and prompt suppression. Confirm following
  alone never imports, downloads, or prepares media.
- [ ] Combine library search, filters, and every sort; relaunch to confirm filter
  and sort persistence but an empty query.
- [ ] Exercise every timed sleep mode and End of Chapter across pause,
  backgrounding, recording, extension, cancellation, item replacement, and app
  termination.

Product-owner result: Pending.

Product-owner notes: Pending.
