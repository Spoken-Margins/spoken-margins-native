import AppIntents
import XCTest
@testable import SessionKit
@testable import SessionKitPersistence
@testable import SpokenMarginsApp

/// #1991: the Today's Margins action returns the day's Margins as text and writes nothing.
@MainActor
final class TodaysMarginsShortcutIntentTests: XCTestCase {
    private func makeModel() -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        return model
    }

    func testTheActionTellsTheListenerWhenTheLibraryIsUnavailable() async {
        do {
            _ = try await TodaysMarginsShortcutAction.text(store: nil)
            XCTFail("a missing Library must not read as an empty day")
        } catch {
            XCTAssertEqual(error as? AddMarginShortcutError, .libraryUnavailable)
        }
    }

    func testTheActionReturnsTodaysMarginsFromTheLibraryAndWritesNothing() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        let store = try XCTUnwrap(model.store)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "Check this claim against the 2019 paper.")
        let marginsBefore = try store.loadInterjections(sessionId: sessionId).count

        let text = try await TodaysMarginsShortcutAction.text(store: store)

        XCTAssertTrue(text.hasPrefix("# Margins for "), text)
        XCTAssertTrue(text.contains("> Check this claim against the 2019 paper."), text)
        XCTAssertEqual(try store.loadInterjections(sessionId: sessionId).count, marginsBefore, "the action only reads")
    }

    /// A Margin Siri or the Watch filed into a quick session is not in the database; it is in the day all the same, in
    /// order with the Library's Margins. A session already saved as a Library item is not counted twice.
    func testTheActionIncludesMarginsFiledInLiveAndQuickSessions() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let store = try XCTUnwrap(model.store)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "On a Library item.")
        let now = Date()
        var quick = LiveSession(id: "quick-1", kind: .other, startedAt: now.addingTimeInterval(-60), isQuick: true)
        quick.margins = [quick.margin(id: "q1", text: "Filed by Siri into a quick session.", markedAt: now.addingTimeInterval(-60))]
        var saved = LiveSession(id: "saved-1", kind: .meeting, title: "Saved meeting", startedAt: now, savedItemId: "some-item")
        saved.margins = [saved.margin(id: "s1", text: "Counted on its item, not here.", markedAt: now)]

        let text = try await TodaysMarginsShortcutAction.text(store: store, liveSessions: [quick, saved], now: now)

        XCTAssertTrue(text.contains("> Filed by Siri into a quick session."), text)
        XCTAssertTrue(text.contains("· Quick session\n"), text)
        XCTAssertTrue(text.contains("> On a Library item."), text)
        XCTAssertFalse(text.contains("Counted on its item"), text)
        let quickAt = try XCTUnwrap(text.range(of: "Filed by Siri"))
        let libraryAt = try XCTUnwrap(text.range(of: "On a Library item."))
        XCTAssertLessThan(quickAt.lowerBound, libraryAt.lowerBound, "the quick one was made a minute earlier")
    }

    /// A Margin saved from a live session is stored with the save time; the action dates it by the record's time.
    func testAMarginSavedFromALiveSessionIsListedAtWhenItWasMade() async throws {
        let model = makeModel()
        model.startItem(id: "item-pill")
        let store = try XCTUnwrap(model.store)
        let sessionId = try XCTUnwrap(model.snapshot.sessionId)
        model.beginWrittenMargin()
        model.saveWrittenMargin(text: "Saved from a meeting.")
        let stored = try XCTUnwrap(try store.loadInterjections(sessionId: sessionId).first)
        let now = Date()

        // Made two days ago, so today's digest leaves it out even though the database stamps it with now.
        let old = try await TodaysMarginsShortcutAction.text(
            store: store, liveSessions: [], savedMarginTimes: [stored.id: now.addingTimeInterval(-2 * 86_400)], now: now)
        XCTAssertFalse(old.contains("Saved from a meeting."), old)
        let current = try await TodaysMarginsShortcutAction.text(store: store, liveSessions: [], savedMarginTimes: [:], now: now)
        XCTAssertTrue(current.contains("> Saved from a meeting."), current)
    }

    func testTheIntentSaysSoWhenTheLibraryIsUnavailable() async {
        let priorModel = ListeningEditionShortcutBridge.model
        ListeningEditionShortcutBridge.model = nil
        defer { ListeningEditionShortcutBridge.model = priorModel }
        do {
            _ = try await TodaysMarginsIntent().perform()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AddMarginShortcutError, .libraryUnavailable)
        }
    }
}
