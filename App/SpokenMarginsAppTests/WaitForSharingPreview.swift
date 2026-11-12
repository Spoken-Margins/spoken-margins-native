import XCTest
@testable import SpokenMarginsApp

/// Waits for the sharing coordinator's recipient preview, which builds and verifies a real packet. A fixed
/// 100 x 20 ms loop gave it two seconds, and on a loaded runner (load average above 300 in the #4130 lane run) it
/// did not finish: four tests that wait on it failed with the state still `building`, though the code was fine.
/// This waits for the state or a generous deadline, so a slow run is slow and only a hung preview fails, with the
/// state the caller's own assertion then reports.
@MainActor
func waitForSharingPreview(
    _ coordinator: Build23SharingCoordinator,
    timeout: Duration = .seconds(60),
    until isDone: ((Build23SharingCoordinator) -> Bool)? = nil
) async throws {
    // The default is read here, in the main actor's body: a default argument is evaluated outside it (lane build error).
    func finished() -> Bool {
        if let isDone { return isDone(coordinator) }
        return coordinator.snapshot.previewState == .ready
    }
    let deadline = ContinuousClock.now + timeout
    while !finished(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
}
