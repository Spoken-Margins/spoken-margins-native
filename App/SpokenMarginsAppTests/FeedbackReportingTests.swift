import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// Pins the reporting boundary while its implementation moves out of the model (#982).
@MainActor
final class FeedbackReportingTests: XCTestCase {
    func testErrorDescriptionsAndContextKeepTheirPrecedence() async {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let fallback = ListenerErrorText.fallback
        // (error, context, what the banner reads, what diagnostics keep for bug reports (#1965))
        let cases: [(Error, String?, String, String)] = [
            (URLError(.timedOut), nil, Gate1AppModel.userFacingMessage(for: URLError(.timedOut)), Gate1AppModel.userFacingMessage(for: URLError(.timedOut))),
            (DescribedError(), nil, "A useful localized description", "A useful localized description"),
            (PlainError(), nil, fallback, "plain error description"),
            (UndescribedError(), nil, fallback, "fallback without a localized description"),
            (DescribedError(), "Import failed", "Import failed: A useful localized description", "Import failed: A useful localized description"),
            (DescribedError(), "", ": A useful localized description", ": A useful localized description")
        ]
        for (error, context, expected, raw) in cases {
            model.reportFailure(error, context: context)
            XCTAssertEqual(model.lastError, expected)
            XCTAssertEqual(model.feedbackEvent?.message, expected)
            XCTAssertEqual(model.diagnostics["recentFailure"], raw)
        }
    }

    func testFailureSuccessAndWarningKeepStatusAndDiagnostics() async {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.diagnostics["lastStatus"] = "Earlier status"
        model.reportFailure("Failed", itemId: "original")
        XCTAssertEqual(model.statusMessage, "Error")
        XCTAssertEqual(model.lastError, "Failed")
        XCTAssertEqual(model.diagnostics["recentFailure"], "Failed")
        XCTAssertEqual(model.diagnostics["lastStatus"], "Earlier status")
        let failures = model.itemFailures

        model.reportSuccess("Succeeded")
        XCTAssertEqual(model.statusMessage, "Succeeded")
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.diagnostics["lastStatus"], "Succeeded")
        XCTAssertEqual(model.diagnostics["recentFailure"], "none")
        XCTAssertEqual(model.itemFailures, failures)

        model.reportFailure("Another failure", itemId: "original")
        let failuresBeforeWarning = model.itemFailures
        model.reportWarning("Degraded")
        XCTAssertEqual(model.statusMessage, "Degraded")
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.feedbackEvent?.kind, .warning)
        XCTAssertEqual(model.diagnostics["lastStatus"], "Degraded")
        XCTAssertEqual(model.diagnostics["recentFailure"], "none")
        XCTAssertEqual(model.itemFailures, failuresBeforeWarning)
    }

    func testFailureUsesExplicitItemThenVisibleItemOnly() async {
        let cases: [(Gate1Screen, String?, String?, String?)] = [
            (.item, "playing", "explicit", "explicit"),
            (.playback, "playing", "explicit", "explicit"),
            (.home, "playing", "explicit", "explicit"),
            (.item, "playing", nil, "selected"),
            (.playback, "playing", nil, "playing"),
            (.playback, nil, nil, nil),
            (.home, "playing", nil, nil),
            (.timeline, "playing", nil, nil),
            (.item, "playing", "", nil)
        ]
        for (screen, playingItem, explicitItem, expectedItem) in cases {
            let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
            model.selectedItem.id = "selected"
            model.snapshot.itemId = playingItem
            model.screen = screen
            model.reportFailure("Failed", itemId: explicitItem)
            for item in ["explicit", "selected", "playing", ""] {
                XCTAssertEqual(model.itemFailures.lastFailure(itemId: item)?.message,
                               item == expectedItem ? "Failed" : nil,
                               "screen=\(screen), explicit=\(String(describing: explicitItem)), item=\(item)")
            }
        }
    }

    func testRetryBannerReplacementFollowsPolicy() async {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let retry = UserFeedbackEvent.Retry(key: "retry-original") {}
        model.reportFailure("Retry this", retry: retry)
        let original = model.feedbackEvent
        model.reportConfirmation("Copied")
        XCTAssertEqual(model.feedbackEvent, original)
        model.reportWarning("Warning")
        XCTAssertEqual(model.feedbackEvent, original)
        model.reportFailure("New error")
        XCTAssertNotEqual(model.feedbackEvent, original)
        XCTAssertEqual(model.feedbackEvent?.message, "New error")
        XCTAssertNil(model.feedbackEvent?.retry)
        model.reportConfirmation("Done")
        XCTAssertEqual(model.feedbackEvent?.kind, .success)
        XCTAssertEqual(model.feedbackEvent?.message, "Done")
    }

    func testConfirmationPreservesItsAction() async {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        var performed = false
        let action = UserFeedbackEvent.Action(title: "Undo", accessibilityLabel: "Undo this",
                                             identifier: "test.undo", perform: { performed = true })
        model.reportConfirmation("Done", action: action)
        XCTAssertEqual(model.feedbackEvent?.action?.title, "Undo")
        XCTAssertEqual(model.feedbackEvent?.action?.accessibilityLabel, "Undo this")
        XCTAssertEqual(model.feedbackEvent?.action?.identifier, "test.undo")
        model.feedbackEvent?.action?.perform()
        XCTAssertTrue(performed)
    }
}

private struct DescribedError: LocalizedError {
    var errorDescription: String? { "A useful localized description" }
}

private struct PlainError: Error, CustomStringConvertible {
    var description: String { "plain error description" }
}

private struct UndescribedError: LocalizedError, CustomStringConvertible {
    var errorDescription: String? { nil }
    var description: String { "fallback without a localized description" }
}
