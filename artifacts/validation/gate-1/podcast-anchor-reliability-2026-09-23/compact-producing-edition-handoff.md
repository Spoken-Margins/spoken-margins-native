# Compact-control producing edition — 2026-09-23

Status: implemented and build-verified; runtime product validation remains with the owner.

`Gate1AppModel.swift` now retains the validated active local playback file binding across compact-control begin and finish. It accepts only `app_ui`, `compact_url`, and `now_playing` origins, a delegated canonical-runtime command, an unchanged playback generation and local file, and a saved Margin with the exact scheduled ID, session ID, item ID, target type, and original media anchor. The existing detached digest path rechecks the file and playback generation before writing. A failed, stale, or unproved path leaves the producing digest unknown. Watch runtime was untouched.

`Gate1AppModelWorkflowTests.swift` now covers compact recording with no proven local transport and the origin allowlist. `PodcastProducingEditionBindingTests.swift` from the preceding slice covers same-path replacement and stale playback generations. The app test source compiled; it was not run due the unresolved simulator XCTest runner connection stall.

Final checks: fast plan passed, including 340 package tests and one skip (`artifacts/test-runs/20260923-171646-268701-fast/manifest.json`); generic iOS Simulator app `build-for-testing` passed (`compact-producing-edition-app-test-build.log`); `git diff --check` passed. No simulator boot, commit, merge, distribution, physical-device installation, or server work occurred. Existing dirty work was preserved.
