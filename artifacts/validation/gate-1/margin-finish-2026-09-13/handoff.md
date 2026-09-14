# Margin finish feedback repair

Owner testing on iPhone 14 reports slow dismissal after ending voice capture, leading to a second tap starting a new Margin. Implemented on provisional-next atop ad533d6604dbacf892df85dc06f36d63c2f97a08; no commit or TestFlight distribution authorized.

The recording screen now acknowledges the first tap with Saving Margin… and disables finish/cancel before synchronous finalization, allowing 50 ms for presentation. Save & resume is at the top, separated from the playback capture button below. A 700 ms post-completion capture guard absorbs repeat taps. Successful persistence/resume and transcription retain their existing behavior. This mitigates acknowledgement and accidental restart; it does not claim that recorder/store finalization itself became faster. Failed saving retains the recording screen and existing error feedback.

Watch suggestion filed as https://github.com/uncomposed/spoken-margins-native/issues/121, linked to #96 and #75. Gesture availability is a future feasibility question; prefer Watch-local capture and durable later transfer. No Watch implementation was added.

Owner recheck: on iPhone 14, record a short Margin and rapidly double-tap Save & resume. Expect immediate Saving feedback, one saved Margin, resumed playback, and no new recording. After a moment, intentionally start another Margin. Repeat with a longer recording. Check cancel and save-error recovery if encountered. Existing Library data needs no reset. Diagnostics: Settings → Developer tools → diagnostic export. Other flows, PDF contents, Watch gestures and TestFlight distribution are outside this patch. Implementation remains pending human validation.

## Verification

Fast plan passed on final inputs. App plan: 427 passed; the existing feed-import database-lock case passed on isolated retry (428 cases total). The new immediate-acknowledgement/single-save/cooldown integration test passed. Focused recording UI tests passed on iPhone 17 Pro and iPad simulators (iOS 26.5), including physical double-tap, top-button geometry, resumed playback and saved-Margin detail. Signed generic-iOS build passed. See checks.json and result bundles for commands/results; source.json identifies the exact uncommitted source and device executable. App-plan evidence: artifacts/test-runs/20260913-172634-443088-app/.

Development version 0.1 (27), minimum iOS 18.0. Built for supported iPhone/iPad; iPhone 14 latency remains unmeasured. The owner phone is disconnected, so this patch is not installed. Seeded simulator fixture: item-pill; no owner Library reset. Weekly account meter moved 90% to 91% used (9% remains), without reset credits.
