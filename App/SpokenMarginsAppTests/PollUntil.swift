import XCTest

/// Waits for a condition that a real piece of work makes true (a packet export, a render, a download, a player
/// reaching a time) by a deadline in seconds, not a count of polls.
///
/// A fixed `for _ in 0..<100 where ... { Task.sleep(20 ms) }` loop is a two-second deadline written as a loop count, and a
/// loaded runner (load average above 300 in the #4130 lane run) misses it though the code is fine (#4131). This returns as soon
/// as the condition holds, and gives up only after `timeout`: a slow run is slow, and only work that never finishes fails, in the
/// caller's own assertion that follows, which reads the state. A `scripts/tests` guard keeps the loop form from coming back.
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
