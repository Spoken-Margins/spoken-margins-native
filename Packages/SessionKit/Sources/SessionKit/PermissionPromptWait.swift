import Foundation

/// iOS's answer to a permission request, read directly.
public enum PermissionPromptStatus: Equatable, Sendable {
    /// Not decided yet: the system prompt is (or is about to be) on screen.
    case undetermined
    case granted
    case denied
}

/// #217: waits for the listener's answer to a permission prompt. The prompt stays up as long as the
/// listener reads it, so a slow "Allow" is still a yes. The timeout only guards a request that never
/// reports back: once iOS has recorded a decision, that decision is the answer.
public enum PermissionPromptWait {
    public static func awaitAnswer(
        request: @escaping @Sendable () async -> Bool,
        currentStatus: @escaping @Sendable () async -> PermissionPromptStatus,
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool {
        // The request can't be cancelled, so nothing may wait on it inside a task group: the group
        // would only return when the listener answers, with the timeout's "no" (the #217 bug).
        let answer = Task { await request() }
        let watchdog = Task { () -> Bool? in
            while !Task.isCancelled {
                await sleep(timeout)
                guard !Task.isCancelled else { return nil }
                switch await currentStatus() {
                case .undetermined: continue // the prompt is still up: keep waiting for the listener
                case .granted: return true
                case .denied: return false
                }
            }
            return nil
        }
        let once = ResumeOnce()
        return await withCheckedContinuation { continuation in
            Task {
                let value = await answer.value
                if once.claim() {
                    watchdog.cancel()
                    continuation.resume(returning: value)
                }
            }
            Task {
                if let value = await watchdog.value, once.claim() {
                    continuation.resume(returning: value)
                }
            }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
