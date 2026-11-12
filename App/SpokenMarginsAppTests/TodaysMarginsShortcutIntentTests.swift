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
