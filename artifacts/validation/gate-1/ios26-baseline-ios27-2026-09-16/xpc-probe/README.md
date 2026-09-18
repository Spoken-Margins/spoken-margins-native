# Simulator XPC peer-requirement diagnosis

This probe uses the public C API beneath Swift `XPCPeerRequirement.hasEntitlement(_:)`. It does not connect to a service, request a privileged entitlement, change security policy, or invoke Spoken Margins. The C API returns an error rather than asserting as the Swift wrapper does.

## Observations

- Host: macOS 26.6.2 (25G83), Apple silicon; Xcode 27.0 (27A266a).
- Native host execution: all three requirement objects created successfully (`macos26.txt`).
- iOS 26.5 simulator (23F77): all three returned NULL with `XPC Peer Requirement requires LWCR support.` (`ios26.txt`).
- iOS 27.0 simulator (24A434), fresh device: the identical executable returned the same error for all three requirements (`ios27.txt`). Probe exit was 1; execution completed normally without a deliberate crash.
- The same Apple AppIntentsLiveEntityService assertion occurred on both the original iOS 27 device and a freshly created device. Its faulting stack is `_assertionFailure` → `__XPC_INTERNAL_CRASH__` → `__XPC_API_MISUSE__` → `XPCPeerRequirement.hasEntitlement(_:)` → service code.

This is distinct from the PosterBoard invalid-descriptor state and the single WidgetRenderer `_AXDyldImageMonitor` SIGILL. A passing fresh-device keyboard test did not establish overall runtime stability: the subsequent speech check reproduced the App Intents crash and was stopped.

## Reproduction

Compile `peer-requirement.c` with the selected Xcode's iPhone Simulator SDK, target `arm64-apple-ios26.0-simulator`, and `-fblocks`; ad-hoc sign the executable. On an already booted supervised simulator, execute it with `xcrun simctl spawn <UDID> <absolute executable path>`. It prints each result and rich-error description; exit 1 means construction failed. For the host comparison, compile the same file using the macOS SDK and target `arm64-apple-macos26.0`.

The SDK header `usr/include/xpc/peer_requirement.h` documents a nullable result and an error-out parameter. Apple API reference: https://developer.apple.com/documentation/xpc/xpcpeerrequirement.

No simulator system binary, private entitlement or security check has been modified. No bug report has been sent externally.

## Conclusion and limit

Requirement construction fails in the simulator API with an explicit missing-LWCR-support error, while the host API succeeds. Combined with identical service stacks on two iOS 27 devices, this provides a concrete explanation for the AppIntentsLiveEntityService Swift assertion. It does not explain the separate WidgetRenderer SIGILL or how the original PosterBoard store became incomplete. Fresh-device boot and keyboard checks passed, but a later speech run reproduced the service failure, falsifying a device-state-only explanation.

Completing uninterrupted iOS 27 simulator verification requires an Apple runtime/toolchain correction or an Apple-supported workaround for the missing simulator capability. The current repository cannot implement that capability in Apple's service. Physical-device verification can provide separate app evidence but cannot prove the simulator defect fixed. Disabling a service, suppressing crash dialogs or modifying Apple binaries is not recorded as a repair.
