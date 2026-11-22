import Foundation
import SessionKitTestInputs
import XCTest

/// #3940, PR 3: two promises about the end phrase that a test of behaviour can't see, because they are about code that
/// must not exist. They read the source: no quiet timer may sit near the way a Margin ends, and listening may never ask
/// for permission (a prompt with the microphone live is the #2966 trap; the question belongs at the first transcription).
/// A change that needs either has to change this test in the open.
final class MarginEndPhraseGuardTests: XCTestCase {
    /// A source file of the package, named from the repository root.
    private func source(_ relative: String) throws -> String {
        let app = try TestInputs.directory(.appSources) // the checkout is found through the helper, never by an App/ path
        let root = app.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// A source file of the app, by its name in the app's sources folder.
    private func appSource(_ name: String) throws -> String {
        try String(contentsOf: TestInputs.directory(.appSources).appendingPathComponent(name), encoding: .utf8)
    }

    private let ruleFiles = [
        "Packages/SessionKit/Sources/SessionKit/MarginEndPhrase.swift",
        "Packages/SessionKit/Sources/SessionKit/MarginEndPhraseListening.swift"
    ]
    private let listenerFile = "Packages/SessionKit/Sources/SessionKitAudio/MarginEndPhraseListener.swift"
    private let liveFiles = [
        "Packages/SessionKit/Sources/SessionKitAudio/MarginEndPhraseListener.swift",
        "Packages/SessionKit/Sources/SessionKitAudio/LiveInputTap.swift",
        "Packages/SessionKit/Sources/SessionKitAudio/SpeechLiveInputSession.swift"
    ]
    private let timerWords = ["Task.sleep", "Timer.", "Timer(", "asyncAfter", "DispatchSource", "scheduledTimer", "ContinuousClock", ".sleep("]

    /// The coordinator, the part of the app that starts and ends listening and routes the phrase to Save.
    private func coordinatorSource() throws -> String {
        let capture = try appSource("Gate1AppModel+MarginCapture.swift")
        let start = try XCTUnwrap(capture.range(of: "final class MarginEndPhraseStatus")?.lowerBound)
        return String(capture[start...])
    }

    func testNoTimerSitsInTheRuleOrTheCoordinator() throws {
        for file in ruleFiles {
            let text = try source(file)
            for word in timerWords { XCTAssertFalse(text.contains(word), "\(file) must not contain \(word): nothing but the phrase ends a Margin") }
        }
        let coordinator = try coordinatorSource()
        for word in timerWords { XCTAssertFalse(coordinator.contains(word), "the coordinator must not contain \(word)") }
    }

    func testTheListenersOnlyTimerIsTheTickThatConfirmsAPhraseAlreadyHeard() throws {
        let text = try source(listenerFile)
        XCTAssertEqual(text.components(separatedBy: "Task.sleep").count - 1, 1, "one loop, and it only ticks")
        let loop = try XCTUnwrap(text.range(of: "while !Task.isCancelled {"))
        let body = String(text[loop.upperBound...].prefix(260))
        XCTAssertTrue(body.contains("self?.tick()"), "the loop calls tick() and nothing that finishes a Margin")
        XCTAssertFalse(body.contains(".end"))
        XCTAssertFalse(body.contains("onSignal"), "a tick's step goes through the decider, which needs the phrase")
    }

    func testThePhraseReachesSaveOnlyThroughTheEndSignal() throws {
        let coordinator = try coordinatorSource()
        XCTAssertEqual(coordinator.components(separatedBy: "requestFinishInterjectionFromPhrase()").count - 1, 1,
                       "the coordinator ends a Margin in exactly one place")
        XCTAssertFalse(coordinator.contains("requestFinishInterjection()"),
                       "the coordinator never finishes through the unmarked path: the phrase must mark its Margin")
        let end = try XCTUnwrap(coordinator.range(of: "case .end:"))
        let next = try XCTUnwrap(coordinator.range(of: "case .couldNotStart", range: end.upperBound..<coordinator.endIndex))
        XCTAssertTrue(coordinator[end.upperBound..<next.lowerBound].contains("finish()"), "…and it is the `.end` signal's")
        let others = coordinator[next.lowerBound...]
        XCTAssertFalse(others.contains("finish()"), "a failure to listen never finishes the recording")
    }

    /// PR 4's cut runs only on a Margin the ledger marks as ended by the phrase. The audit of #4830 found nothing
    /// marked it, so the cut never ran. The mark must come from the phrase's own finish and from nothing else.
    func testOnlyAPhraseEndedSaveMarksItsMarginForTheCut() throws {
        let capture = try appSource("Gate1AppModel+MarginCapture.swift")
        XCTAssertEqual(capture.components(separatedBy: "requestFinish(endedByPhrase: true)").count - 1, 1,
                       "one entry point marks a Margin as ended by the phrase")
        XCTAssertEqual(capture.components(separatedBy: "requestFinish(endedByPhrase: false)").count - 1, 1,
                       "a tap, the Lock Screen and a headset press never mark one")
        XCTAssertTrue(capture.contains("transcribeAndRecordSavedSpokenMargin(endedByPhrase: endedByPhrase)"),
                      "the save passes the phrase's flag on to the transcription it schedules")

        let signals = try appSource("Gate1AppModel+ListeningSignals.swift")
        let mark = try XCTUnwrap(signals.range(of: "if endedByPhrase { MarginEndPhraseEndLedger.shared.markEndedByPhrase(interjectionId: interjection.id) }"))
        let schedule = try XCTUnwrap(signals.range(of: "scheduleTranscription(for: interjection)"))
        XCTAssertLessThan(mark.lowerBound, schedule.lowerBound,
                          "the Margin is marked before its transcription job asks the ledger")
        XCTAssertEqual(signals.components(separatedBy: "markEndedByPhrase").count - 1, 1)
        XCTAssertTrue(signals.contains("func transcribeAndRecordSavedSpokenMargin(endedByPhrase: Bool = false)"),
                      "every other save route defaults to unmarked, which keeps everything")

        // No other source marks a Margin: the ledger's answer is true only for a phrase-ended save.
        for file in ["Gate1AppModel.swift", "Gate1AppModel+MarginInterruption.swift", "Gate1AppModel+SourceWindowContext.swift",
                     "ExperienceRecordingScreen.swift", "MarginRecordingScreen.swift"] {
            XCTAssertFalse(try appSource(file).contains("markEndedByPhrase"), "\(file) must not mark a Margin as phrase-ended")
        }
    }

    func testListeningNeverAsksForPermission() throws {
        let sources = try liveFiles.map { ($0, try source($0)) } + [("SpeechRecognitionAccess.swift", try appSource("SpeechRecognitionAccess.swift"))]
        for (file, text) in sources {
            XCTAssertFalse(text.contains("requestAuthorization"), "\(file) must not ask for Speech Recognition")
            XCTAssertFalse(text.contains("requestRecordPermission"), "\(file) must not ask for the microphone")
            XCTAssertFalse(text.contains("requestPermission"), "\(file) must not ask for anything")
        }
        let coordinator = try coordinatorSource()
        XCTAssertFalse(coordinator.contains("requestAuthorization"))
        XCTAssertTrue(coordinator.contains("SpeechRecognitionAccess.state"), "availability reads the status without asking")
        XCTAssertTrue(coordinator.contains("isAuthorized"), "the session is only given the no-prompt check")
    }
}
