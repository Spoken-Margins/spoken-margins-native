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
        XCTAssertEqual(coordinator.components(separatedBy: "requestFinishInterjection()").count - 1, 1,
                       "the coordinator ends a Margin in exactly one place")
        let end = try XCTUnwrap(coordinator.range(of: "case .end:"))
        let next = try XCTUnwrap(coordinator.range(of: "case .couldNotStart", range: end.upperBound..<coordinator.endIndex))
        XCTAssertTrue(coordinator[end.upperBound..<next.lowerBound].contains("finish()"), "…and it is the `.end` signal's")
        let others = coordinator[next.lowerBound...]
        XCTAssertFalse(others.contains("finish()"), "a failure to listen never finishes the recording")
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
