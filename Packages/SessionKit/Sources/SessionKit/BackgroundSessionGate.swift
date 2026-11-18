import Foundation

/// Lets one `URLSession` at a time hold a background identifier (#4392).
///
/// CFNetwork throws an uncaught exception ("A background URLSession with identifier ... already exists!") from
/// `downloadTask(with:)` when a second session shares an identifier with one that has not finished
/// invalidating. `invalidateAndCancel()` is asynchronous, so a coordinator built right after `shutdown()` of
/// the old one used to land in exactly that window. A coordinator takes the identifier here before it makes a
/// session and gives it back from `didBecomeInvalidWithError`, so the second one waits for the first.
@MainActor
public final class BackgroundSessionGate {
    public static let shared = BackgroundSessionGate()

    public init() {}

    private var held: Set<String> = []
    private var waiters: [String: [UUID: CheckedContinuation<Bool, Never>]] = [:]

    public func isHeld(_ identifier: String) -> Bool { held.contains(identifier) }

    /// Takes `identifier` if no live session holds it.
    public func claim(_ identifier: String) -> Bool { held.insert(identifier).inserted }

    /// Gives `identifier` back and wakes whoever is waiting for it. Does nothing if it was not held.
    public func release(_ identifier: String) {
        guard held.remove(identifier) != nil else { return }
        let pending = waiters.removeValue(forKey: identifier) ?? [:]
        for continuation in pending.values { continuation.resume(returning: true) }
    }

    /// Waits until `identifier` is free and takes it. False when it stayed held for `timeout`, so the caller
    /// can fail visibly instead of making a second session.
    public func claim(_ identifier: String, waitingUpTo timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !claim(identifier) {
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero { return false }
            _ = await waitForRelease(identifier, timeout: remaining)
        }
        return true
    }

    private func waitForRelease(_ identifier: String, timeout: Duration) async -> Bool {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            waiters[identifier, default: [:]][token] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.expire(identifier, token: token)
            }
        }
    }

    private func expire(_ identifier: String, token: UUID) {
        guard let continuation = waiters[identifier]?.removeValue(forKey: token) else { return }
        if waiters[identifier]?.isEmpty == true { waiters[identifier] = nil }
        continuation.resume(returning: false)
    }
}
