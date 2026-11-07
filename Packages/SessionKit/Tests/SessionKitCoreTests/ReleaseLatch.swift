import Foundation

/// Holds callers until a test releases them, and remembers the release (#3616).
///
/// A stand-in called from a task the code under test started can't know whether it runs before or after the test's
/// next line. A gate that only resumes whoever is already parked loses a release that comes first: the late caller
/// parks with nobody left to wake it, and the test hangs with every thread idle, so no test method shows on any stack.
/// Here a caller that comes after the release goes straight through.
final class ReleaseLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let goesThrough = lock.withLock { () -> Bool in
                if released { return true }
                parked.append(continuation)
                return false
            }
            if goesThrough { continuation.resume() }
        }
    }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { parked = [] }
            return parked
        }
        for continuation in waiting { continuation.resume() }
    }
}
