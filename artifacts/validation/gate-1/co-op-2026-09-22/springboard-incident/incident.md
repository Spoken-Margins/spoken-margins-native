# iPad SpringBoard crash during UI-test teardown

- Device: Spoken Margins Test Suite iPad, BEBBB4FD-E13C-457C-A41F-DD7DF02B5C51, iPadOS 26.5.
- Suite: `artifacts/test-runs/20260922-122224-759672-ui`.
- All 16 assertions/tests finished passing at 12:33:54.038 EDT.
- SpringBoard crashed at 12:33:54.1731 EDT, about 135 ms later.
- Fault: EXC_BAD_ACCESS, invalid address 0x20, thread 9.
- Crashing frame: XCTAutomationSupport, block in `XCTAutomationSession initWithAccessibilityFramework:dataSource:`.
- Main thread was processing keyboard-focus/window transitions after application exit.
- The report was persisted later as SpringBoard-2026-09-22-123514.ips, after the runner had exited and its device-specific report monitor stopped.

The evidence strongly connects the incident to UI automation teardown. It does not
establish the underlying Apple/runtime defect or prove an application trigger is
impossible. This signature differs from the prior iOS 27 AppIntents incident.

Upon the owner's report, the agent matched the simulator identity, preserved both
reports, and shut down the affected iPad successfully. The phone speech canary had
already completed. No further simulator boot or test was attempted after discovery,
and no recovery is claimed. The raw XCTest success remains historical evidence;
it is not a clean-system pass. An evidence-backed recovery check remains pending.

Monitoring gap: the runner watches only the current test destination while the
process runs. A delayed report from a completed destination escapes that window.
Future repair should supervise all task-owned destinations through teardown and
reconcile delayed reports before issuing a clean-system handoff. A short fixed
post-exit sleep would not cover this observed roughly 80-second report delay.

Shutdown verification: a later read unexpectedly found the iPad Booted again.
This task issued no boot request. A second shutdown returned success and the
immediate inventory read confirmed `Shutdown`; no iPad launchd_sim remained.
The cause of the intervening boot state is unknown.
