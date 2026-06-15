import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

@MainActor
final class Gate2CompactControlTests: XCTestCase {
    func testCompactSnapshotIsPublishedForSeededSession() {
        let model = Gate1AppModel()
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        XCTAssertEqual(model.gate2CompactSnapshot?.surfaceProfileId, "lock-screen-widget")
        XCTAssertEqual(model.gate2CompactSnapshot?.title, "You Can't Inspect the Pill")
        XCTAssertEqual(model.gate2CompactSnapshot?.chapterTitle, "Reasonable distrust")
        XCTAssertEqual(model.gate2CompactSnapshot?.compactSurfaceReady, true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.togglePlayPause) == true)
        XCTAssertTrue(model.gate2CompactSnapshot?.exposedCommands.contains(.beginInterjection) == true)
    }

    func testCompactTransportCommandsDelegateAndUpdateDiagnostics() {
        let model = Gate1AppModel()
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        model.dispatchGate2CompactCommand(.togglePlayPause)

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "togglePlayPause")
        XCTAssertEqual(model.diagnostics["gate2LastResult"], "delegated")

        model.dispatchGate2CompactCommand(.skipForward)

        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "skipForward")
        XCTAssertEqual(model.gate2CompactSnapshot?.compactSurfaceReady, true)
    }

    func testCompactCommandURLDelegatesThroughCanonicalRuntime() {
        let model = Gate1AppModel()
        model.resetAndSeed()
        model.startItem(id: "item-pill")

        model.handleGate2CompactURL(Gate2CompactCommandURL.url(command: "togglePlayPause"))

        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertEqual(model.diagnostics["gate2LastCommand"], "togglePlayPause")
    }

    func testWidgetCommandQueueBuffersAndDrainsCommands() {
        let suiteName = "Gate2CompactCommandQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        Gate2CompactCommandQueue.enqueue(command: "togglePlayPause", id: "first", defaults: defaults)
        Gate2CompactCommandQueue.enqueue(command: "skipForward", id: "second", defaults: defaults)

        let drained = Gate2CompactCommandQueue.drain(defaults: defaults)

        XCTAssertEqual(drained.map(\.id), ["first", "second"])
        XCTAssertEqual(drained.map(\.command), ["togglePlayPause", "skipForward"])
        XCTAssertTrue(Gate2CompactCommandQueue.drain(defaults: defaults).isEmpty)
    }
}
