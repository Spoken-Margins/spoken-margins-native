import XCTest
@testable import SpokenMarginsApp

/// #1913: the Live Activity's buttons read their raw command ("skipBack") to VoiceOver, and its state
/// images and compact shared-Margin buttons said nothing useful.
final class LiveActivityAccessibilityTests: XCTestCase {
    private func state(
        _ status: String,
        isRecording: Bool = false,
        microphone: Gate2LiveActivityMicrophone = .capturing,
        sender: String? = nil
    ) -> Gate2LiveActivityAttributes.ContentState {
        Gate2LiveActivityAttributes.ContentState(
            title: "Episode", chapterTitle: "Opening", status: status, phase: "itemPlayback",
            progressPercent: 10, isRecording: isRecording, microphone: microphone,
            sharedMarginSenderLabel: sender
        )
    }

    func testEveryTransportCommandHasAnExplicitLabelThatIsNotTheCommand() {
        for command in Gate2LiveActivityAccessibility.transportCommands {
            let label = Gate2LiveActivityAccessibility.label(forCommand: command)
            XCTAssertNotNil(Gate2LiveActivityAccessibility.transportLabels[command], command)
            XCTAssertNotEqual(label, command, command)
            XCTAssertTrue(label.contains(" "), "\(command) reads as one camelCase word: \(label)")
        }
    }

    func testTheSkipButtonsSayHowFarTheyGo() {
        XCTAssertEqual(Gate2LiveActivityAccessibility.label(forCommand: "skipBack"), "Back 15 seconds")
        XCTAssertEqual(Gate2LiveActivityAccessibility.label(forCommand: "skipForward"), "Forward 15 seconds")
    }

    func testAnUnknownCommandReadsAsWordsNotCamelCase() {
        XCTAssertEqual(Gate2LiveActivityAccessibility.label(forCommand: "openDiary"), "open diary")
    }

    func testPlayPauseNamesTheActionNotTheState() {
        XCTAssertEqual(Gate2LiveActivityAccessibility.playPauseLabel(isPlaying: true), "Pause")
        XCTAssertEqual(Gate2LiveActivityAccessibility.playPauseLabel(isPlaying: false), "Play")
    }

    func testCompactSharedMarginButtonsNameTheirTarget() {
        XCTAssertEqual(Gate2LiveActivityAccessibility.playSharedMargin, "Play shared Margin")
        XCTAssertEqual(Gate2LiveActivityAccessibility.skipSharedMargin, "Skip shared Margin")
    }

    func testTheStateImageIsDescribedInWordsForEveryState() {
        XCTAssertEqual(state("playing").stateAccessibilityLabel(isStale: false), "Playing")
        XCTAssertEqual(state("starting").stateAccessibilityLabel(isStale: false), "Loading")
        XCTAssertEqual(state("paused").stateAccessibilityLabel(isStale: false), "Paused, tap to resume")
        XCTAssertEqual(state("playing").stateAccessibilityLabel(isStale: true), "Paused, tap to resume")
        XCTAssertEqual(state("recording", isRecording: true).stateAccessibilityLabel(isStale: false), "Recording a Margin")
        XCTAssertEqual(
            state("recording", isRecording: true, microphone: .stopped).stateAccessibilityLabel(isStale: false),
            "Microphone stopped"
        )
        XCTAssertEqual(state("playing", sender: "Sam").stateAccessibilityLabel(isStale: false), "New shared Margin")
    }

    func testTheStateLabelNeverLeaksASenderName() {
        XCTAssertFalse(state("playing", sender: "Sam").stateAccessibilityLabel(isStale: false).contains("Sam"))
    }

    /// #3722: the live session card's state glyphs (stop, waveform, bookmark) read their symbol names to VoiceOver.
    func testTheLiveSessionCardStateGlyphsSayTheirStateInWords() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        typealias CardState = LiveSessionActivityAttributes.ContentState
        XCTAssertEqual(CardState(markCount: 0).stateAccessibilityLabel, "Session running")
        XCTAssertEqual(CardState(markCount: 2, isRecordingMargin: true).stateAccessibilityLabel, "Recording")
        XCTAssertEqual(CardState(markCount: 2, endedAt: start).stateAccessibilityLabel, "Session ended")
        // An ended card never says it records, even if the flag was left on.
        XCTAssertEqual(CardState(markCount: 2, endedAt: start, isRecordingMargin: true).stateAccessibilityLabel, "Session ended")
    }
}
