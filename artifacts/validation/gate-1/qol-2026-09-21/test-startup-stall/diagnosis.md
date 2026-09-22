# Test startup stall and bounded recovery

After the full release UI run, the next AppBehavior run launched its host but reported zero tests for more than four minutes. Host sample: main run loop idle, roughly 42 MiB footprint, XCTTargetBootstrap loaded but no XCTest test bundle. Controller sample: waiting for build/test operation. No new simulator crash report appeared. Samples and testing-service log are retained here.

The stalled xcodebuild was interrupted and its failed/incomplete manifest retained at `artifacts/test-runs/qol-20260921-app-final/manifest.json`. The same simulator was shut down once, then rebooted by the runner. No device data/runtime was deleted. The unchanged test binary was reused. The bounded AppBehavior retry executed and passed all selected tests in 57.595 seconds; see `artifacts/test-runs/qol-20260921-app-recovery/manifest.json`. This supports a transient test-session startup failure, not an app deadlock or an iOS 27 runtime repair.
