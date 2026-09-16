# Active offline podcast protection

Owner reports previously downloaded podcast failed to resume after an interjection during a walk; Item Detail then said the download needed attention. No new diagnostic export identifies the deletion event, so the exact device cause remains unconfirmed.

Code evidence: PodcastDownloadCoordinator protected activeItemId only from its own cache eviction. OfflineStorageLedger independently deletes unprotected reproducible podcast assets for reservations or budget enforcement. Coordinator registration/activation did not set the existing activePlayback protection in that ledger. validatedLocalURL marks a missing file failed and clears its path. This is an evidenced route to the reported state, not proof of the particular device event. Source-window transcription cleanup was also inspected; it removes its own window directory, not PodcastAudio.

Repair: transfer activePlayback protection to the selected listening episode in the shared inventory, retaining other protection reasons. Match adopted legacy files by relative path as well as item ID. Download completion records activePlayback when the episode is active. Item Detail chapter startup now runs the existing source-media preparation path so it uses and protects downloaded audio before session startup. Protection remains through Pause and interjections and transfers when another source becomes active. Existing startup-retry work is preserved; that retry alone cannot recover a deleted offline file.

Regression: force the shared budget to six bytes with two three-byte podcast files. A new reservation must evict only the inactive file; another reservation must fail rather than remove the active file. Releasing protection makes the file reclaimable again. Use real temporary files and the SQLite-backed shared ledger; adopted-file case deliberately omits item IDs.

No device data was touched. No installation, commit or distribution. Exact walk flow remains pending owner recheck on an installed candidate; this is not human validation.

Verification: simulator build and all 16 selected tests in PodcastDownloadCoordinatorTests and OfflineStorageLedgerTests passed, zero failures. The new forced-eviction test passed. Diff whitespace check passed. Existing test teardown emits SQLite open-file unlink warnings; these are not device-database observations. Full app/release gates remain deferred.

Command:
```sh
xcodebuild -project SpokenMarginsNative.xcodeproj -scheme SpokenMarginsAppBehavior -testPlan AppBehavior -destination 'id=856FA6EF-5E03-4120-939B-F0EF42A804E8' -derivedDataPath .build/verification/SpokenMarginsAppBehavior -only-testing:SpokenMarginsAppTests/PodcastDownloadCoordinatorTests -only-testing:SpokenMarginsAppTests/OfflineStorageLedgerTests -parallel-testing-enabled NO test
```
