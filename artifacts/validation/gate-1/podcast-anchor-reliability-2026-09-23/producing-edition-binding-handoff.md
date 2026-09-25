# Producing-edition local playback binding — 2026-09-23

Status: implemented and host-verified for the main voice Margin capture path; product flow awaits owner validation.

## Change

- `AudioAdapters.swift` now snapshots a local file's volume/inode/size/modification time when an `AVPlayerItem` is installed, with a distinct playback generation. The active binding is available only for the same item, URL, generation, and unchanged file.
- `Gate1AppModel.swift` samples that binding immediately before and after `beginInterjection`, checks it again at finish, hashes the exact local bytes in a detached task, and checks the file, playback generation, validated download URL, saved Margin identity, and original anchor before persisting `sourceExactEditionSHA256`. Hash failure or any changed identity leaves the digest unknown. Successful durable digest capture can start the preexisting exact-local signature retry when its window state is unavailable.
- `PodcastProducingEditionBindingTests.swift` checks stable bytes and digest, streaming rejection, same-path file replacement, later playback generation, and digest persistence after SQLite reopen.

## Verification

- Fast plan passed: 340 package tests passed, 1 skipped; runner, contracts, surfaces, inventory, and browser checks passed. Evidence: `artifacts/test-runs/20260923-171114-152788-fast/manifest.json`.
- Generic iOS Simulator `SpokenMarginsApp` `build-for-testing` passed; app test source compiled, XCTest was not run. Log: `producing-edition-app-test-build.log`.
- `git diff --check` passed. No simulator was booted.

## Limits

- The main microphone recording path receives the binding. Watch and compact-command capture paths retain an unknown producing digest. Streamed audio, a changed player generation, a replaced local file, and an unvalidated local URL also retain unknown identity.
- The binding detects ordinary file replacement and mutation through file identity and metadata; it cannot prove an adversarial same-inode rewrite that restores size and modification time. There is no runtime AVPlayer fixture test due the unresolved simulator XCTest runner connection stall. Automated checks do not constitute owner validation.
- No commit, merge, distribution, physical-device installation, or server work was performed. Existing dirty work was preserved.
