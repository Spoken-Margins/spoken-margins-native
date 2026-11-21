import Foundation
import SessionKit
import XCTest

/// The result values of a run that writes on-device scene summaries for an article or a PDF (#3450, #3461), moved
/// out of the app (#318) so the wording and the two background-pass flags are host-tested. The background pass reads
/// `settlesBackgroundRun` to decide whether to pick an item again, so a flipped flag either loops one item forever or
/// strands a paused one; the listener reads `message` and the Diagnostics export reads `diagnostic`.
final class TextSceneSummaryOutcomeTests: XCTestCase {
    private struct Row {
        let outcome: TextSceneSummaryOutcome
        let settles: Bool
        let canBeContinued: Bool
        let message: String
        let diagnostic: String
    }

    private let rows: [Row] = [
        Row(outcome: .summarised(scenes: 3, total: 5), settles: true, canBeContinued: false,
            message: "Scene summaries are ready (3 of 5 scenes). Skim can read them.", diagnostic: "summarised 3 of 5"),
        Row(outcome: .nothingToSummarise, settles: true, canBeContinued: false,
            message: "This text is too short to summarise. The chapters stay as they are.", diagnostic: "nothing_to_summarise"),
        Row(outcome: .noSummaryAccepted, settles: true, canBeContinued: false,
            message: "The on-device model's summaries didn't pass the check, so the chapters stay without summaries.",
            diagnostic: "no_summary_accepted"),
        Row(outcome: .keptOtherMap, settles: true, canBeContinued: false,
            message: "This already has a Listening Map, so it was not replaced.", diagnostic: "kept_other_map"),
        Row(outcome: .paused(.heat(.serious), written: 2, total: 6), settles: false, canBeContinued: true,
            message: "Paused while the phone is warm. 2 of 6 scene summaries are saved. Tap Continue Scene Summaries to pick up there.",
            diagnostic: "paused:heat_serious 2 of 6"),
        Row(outcome: .paused(.lowPowerMode, written: 0, total: 4), settles: false, canBeContinued: true,
            message: "Paused for Low Power Mode. 0 of 4 scene summaries are saved. Tap Continue Scene Summaries to pick up there.",
            diagnostic: "paused:low_power_mode 0 of 4"),
        Row(outcome: .audioPaused(.heat(.critical)), settles: false, canBeContinued: false,
            message: "Paused while the phone is warm. The scene summaries are saved, and Skim makes their audio later.",
            diagnostic: "audio paused:heat_critical"),
        Row(outcome: .modelStopped(written: 1, total: 3), settles: false, canBeContinued: true,
            message: "The on-device model stopped answering. 1 of 3 scene summaries are saved. Tap Continue Scene Summaries to try again.",
            diagnostic: "model_stopped 1 of 3"),
        Row(outcome: .cancelled, settles: false, canBeContinued: true,
            message: "Stopped writing scene summaries. The ones already written are kept.", diagnostic: "cancelled"),
        Row(outcome: .failed("The file is unreadable."), settles: true, canBeContinued: true,
            message: "Couldn't write scene summaries. The file is unreadable.", diagnostic: "failed: The file is unreadable."),
    ]

    func testEveryOutcomeSaysWhatTheListenerAndDiagnosticsAreTold() {
        for row in rows {
            XCTAssertEqual(row.outcome.message, row.message, "\(row.outcome)")
            XCTAssertEqual(row.outcome.diagnostic, row.diagnostic, "\(row.outcome)")
        }
    }

    func testOnlyAnEndedRunSettlesTheBackgroundPassAndOnlyAnInterruptedOneCanContinue() {
        for row in rows {
            XCTAssertEqual(row.outcome.settlesBackgroundRun, row.settles, "settles: \(row.outcome)")
            XCTAssertEqual(row.outcome.canBeContinued, row.canBeContinued, "continues: \(row.outcome)")
        }
    }

    /// A run that fails every time must not keep the charging pass from the items behind it, yet the listener may
    /// try it again by tapping: a failure both settles the background run and can be continued.
    func testAFailureSettlesTheBackgroundPassButStaysContinuable() {
        let failure = TextSceneSummaryOutcome.failed("x")
        XCTAssertTrue(failure.settlesBackgroundRun)
        XCTAssertTrue(failure.canBeContinued)
    }

    /// Adding an outcome must add a row here: this switch stops compiling until it is handled, and the count check
    /// fails until the table covers it.
    func testTheTableCoversEveryOutcomeKind() {
        func kind(_ outcome: TextSceneSummaryOutcome) -> String {
            switch outcome {
            case .summarised: "summarised"
            case .nothingToSummarise: "nothingToSummarise"
            case .noSummaryAccepted: "noSummaryAccepted"
            case .keptOtherMap: "keptOtherMap"
            case .paused: "paused"
            case .audioPaused: "audioPaused"
            case .modelStopped: "modelStopped"
            case .cancelled: "cancelled"
            case .failed: "failed"
            }
        }
        XCTAssertEqual(Set(rows.map { kind($0.outcome) }).count, 9)
    }

    func testEveryStartHasAPlainSentenceForTheChaptersNote() {
        XCTAssertEqual(TextSceneSummaryStart.started.note, "Writing scene summaries on this device.")
        XCTAssertEqual(TextSceneSummaryStart.alreadyRunning.note, "Scene summaries are still being written.")
        XCTAssertEqual(
            TextSceneSummaryStart.busyWithAnotherItem.note,
            "Scene summaries for something else are still being written, so this one has chapters only.")
        XCTAssertEqual(
            TextSceneSummaryStart.modelUnavailable("Turn on Apple Intelligence").note,
            "Scene summaries need the on-device model, so the chapters have no summaries. Turn on Apple Intelligence.")
    }
}
