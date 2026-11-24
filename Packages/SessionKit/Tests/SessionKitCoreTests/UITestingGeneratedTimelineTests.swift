import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence
import SessionKitTestInputs

/// #5204: the fixture article's UI-test seed paused every start, so J1 text chapters never saw it play. These run the
/// app's start sequence on the app's own fixture item, map and capability profile, as `resetAndSeed` and `makeEngine`
/// load them.
final class UITestingGeneratedTimelineTests: XCTestCase {
    private func fixtureEngine() throws -> (SessionEngine, SQLiteSessionStore, String) {
        let item = try ContractFixtureLoader.item(at: TestInputs.url(.contracts, "fixtures/items/text-with-listening-map.json"))
        let map = try ContractFixtureLoader.listeningMap(at: TestInputs.url(.contracts, "fixtures/maps/valid-listening-map.json"))
        let profile = try ContractFixtureLoader.profile(at: TestInputs.url(.contracts, "fixtures/capabilities/phone-tablet-online.json"))
            .limitedToOnDeviceAI(foundationModelAvailable: false)
        let path = FileManager.default.temporaryDirectory.appending(path: "ui-timeline-\(UUID().uuidString).sqlite").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteSessionStore(path: path)
        try store.seed(item: item)
        try store.seed(map: map)
        return (SessionEngine(profile: profile, repository: store), store, item.id)
    }

    func testAPlayingStartIsStillPlayingInItemPlaybackAfterTheSeed() throws {
        let (engine, store, itemId) = try fixtureEngine()
        let started = try engine.startSession(itemId: itemId)
        XCTAssertEqual(started.status, .playing, "precondition: the fixture article starts playing")
        let sessionId = try XCTUnwrap(started.sessionId)

        let seeded = try UITestingGeneratedTimeline.seed(sessionId: sessionId, engine: engine)

        XCTAssertEqual(seeded.status, .playing, "The seed paused the article the listener just started")
        XCTAssertEqual(seeded.phase, .itemPlayback, "The seed left the session in the conversation phase")
        XCTAssertEqual(seeded.sourceProgressPercent, started.sourceProgressPercent, "The seed moved the place")
        XCTAssertEqual(engine.snapshot, seeded)
        let turns = try store.loadTurns(sessionId: sessionId)
        XCTAssertEqual(turns.map(\.role), ["user", "assistant"])
        let response = try XCTUnwrap(turns.last)
        XCTAssertEqual(response.id, UITestingGeneratedTimeline.responseTurnId)
        XCTAssertEqual(response.status, "complete")
        XCTAssertEqual(response.chapters?.map(\.title), ["Quick Response", "Timeline Navigation"])
    }

    func testAPausedSessionStaysPaused() throws {
        let (engine, _, itemId) = try fixtureEngine()
        let sessionId = try XCTUnwrap(engine.startSession(itemId: itemId).sessionId)
        XCTAssertEqual(try engine.pause().status, .paused)

        let seeded = try UITestingGeneratedTimeline.seed(sessionId: sessionId, engine: engine)

        XCTAssertEqual(seeded.status, .paused, "The seed started a session the listener had paused")
        XCTAssertEqual(seeded.phase, .itemPlayback)
    }
}
