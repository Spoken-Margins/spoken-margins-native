# Device diagnostic recording — September 8

Installed and launched on the connected iPhone 17 Pro (iOS 26.6.1), preserving the existing app data through an in-place install. No uninstall, reset, TestFlight upload, commit, or branch change.

- Visible recording build: `device-diagnostics-20260908-A`
- Bundle: `com.spokenmargins.native`, Debug 0.1 (25)
- Base commit: `8f5b74c889be28a29b110f8207cda7e207d9a208`, plus current uncommitted changes
- Verification input: `69a98be0500686e7d72f3b0ae5139e2a22db247a47ffa4da32f654bc34ef346a`
- Installed debug dylib SHA-256: `aaa6d18f1a8a8be00694890be2ac93dc4444206c6fbf2d9c6e591e707ef9f034`

## Use

Settings → Developer → Developer tools → **Record Device Diagnostics**. Starts off each launch. Enable immediately before one reproduction; disable immediately after it; use **Copy Privacy-Safe Diagnostics** in Support & Privacy and paste the export. Enabling starts a fresh capture. Disabling retains it for export. The latest 1,200 events are retained, periodically checkpointed off-main to `Caches/DeveloperDiagnostics/latest.json`; an app restart can export that saved capture. The latest unsaved events may be lost if the process is killed.

Events include hashed item/target identities, selected-versus-playing item, playback status, opening-buffer counts, preparation worker eligibility, thermal/low-power state, render start/commit, item-open duration, mini-player closure, seek requests, drag values, and slider binding values on canonical progress changes. The display event measures the value supplied to SwiftUI, not the physical thumb's pixels. A delayed heartbeat measures main-actor scheduling delay; it is not a CPU profile and can include lifecycle suspension. This does not claim to fix or human-validate the reported flows.

The 500-ms sampler and recorder do not publish per-event SwiftUI state. Recording remains opt-in; fields omit article text, URLs, and credentials. Existing legacy diagnostics fields retain their previous redaction behavior.

## Verification

Generic/connected iOS Debug build succeeded. Focused checks compiled and ran the actual recorder on macOS: disabled capture, oldest-event eviction, stopping, restarting, identity hashing, and Codable export. The emitted capture passed `scripts/validate-developer-recording.py` against `schemas/developer-recording.schema.json`. Corresponding XCTest regression added for future app runs; not claimed executed in this focused install. Fast plan `20260908-084524-248918-fast` verified. Broad app/UI/release runs deferred per the owner's explicitly revised device-first workflow.

CoreDevice install and launch both succeeded. User flow acceptance is pending; no seeded items or reset are required.
