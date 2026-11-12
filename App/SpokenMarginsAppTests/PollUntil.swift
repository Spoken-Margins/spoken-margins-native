import XCTest

/// Waits for a condition that a real piece of work makes true (a packet export, a render, a download, a player
/// reaching a time) by a deadline in seconds, not a count of polls.
///
/// A fixed `for _ in 0..<100 where ... { Task.sleep(20 ms) }` loop is a two-second deadline written as a loop count, and a
/// loaded runner (load average above 300 in the #4130 lane run) misses it though the code is fine (#4131). This returns as soon
/// as the condition holds, and gives up only after `timeout`: a slow run is slow, and only work that never finishes fails, in the
/// caller's own assertion that follows, which reads the state. A `scripts/tests` guard keeps the loop form from coming back.
///
/// The 30 s default is a guard against a slow runner, never part of what a test claims. When a test claims the work happens
/// within some time ("while the kept chunk plays", "within the seam's deadline", a 3 s chunk, a 5 s default the test
/// must beat), pass a `timeout` below that time, so the assertion after the wait still fails for a regression that is merely
/// late. The same goes for a probe whose "no" is a normal answer: give it a short `timeout`, not the default (#4131 audit).
@MainActor
func pollUntil(
    timeout: Duration = .seconds(30),
    pollEvery interval: Duration = .milliseconds(10),
    _ condition: @MainActor () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: interval)
    }
}
