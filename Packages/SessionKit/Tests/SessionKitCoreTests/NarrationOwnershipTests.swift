import XCTest
@testable import SessionKit

/// #1337: sound with no mini player. The decision a returning listener's app makes, and the reasons it records.
final class NarrationOwnershipTests: XCTestCase {
    /// Every combination of the three facts, so a new case can't slip into the wrong row.
    func testRepairTable() {
        let rows: [(app: Bool, engine: Bool, narration: Bool, expected: NarrationOwnership.Repair)] = [
            (true, true, true, .none),
            (true, true, false, .none),
            (true, false, true, .none),
            (true, false, false, .none),
            // The app lost the session; the engine still plays it: show it again where it is.
            (false, true, true, .adoptEngineSession),
            (false, true, false, .adoptEngineSession),
            // Nothing owns the sound: stop it rather than leave it uncontrollable.
            (false, false, true, .stopNarration),
            (false, false, false, .none),
        ]
        for row in rows {
            XCTAssertEqual(
                NarrationOwnership.repair(appHasSession: row.app, engineSessionIsPlaying: row.engine, narrationIsPlaying: row.narration),
                row.expected,
                "app=\(row.app) engine=\(row.engine) narration=\(row.narration)"
            )
        }
    }

    /// A paused or idle listener with no session is the normal Library state: no repair, no event noise.
    func testAnIdleAppWithQuietNarrationNeedsNoRepair() {
        XCTAssertEqual(
            NarrationOwnership.repair(appHasSession: false, engineSessionIsPlaying: false, narrationIsPlaying: false),
            .none
        )
    }

    /// The #1337 export: the client said it was playing, the snapshot had no item, and the voice had changed.
    /// A change of voice is not an input to the decision: the iOS voice playing with no session is repaired too.
    func testASystemVoiceReadingWithNoSessionIsStopped() {
        let narration = PlaybackDiagnosticFields.narration(intent: "playing", systemVoiceActive: true, standInPassage: false)
        XCTAssertEqual(
            NarrationOwnership.repair(
                appHasSession: false,
                engineSessionIsPlaying: false,
                narrationIsPlaying: PlaybackDiagnosticFields.narrationIsPlaying(narration)
            ),
            .stopNarration
        )
    }

    func testMiniPlayerVisibilityNamesTheFirstCauseThatHidesIt() {
        func visibility(
            session: Bool = true, dismissing: Bool = false, playbackScreen: Bool = false, phase: SessionPhase = .itemPlayback
        ) -> NarrationOwnership.MiniPlayerVisibility {
            NarrationOwnership.miniPlayerVisibility(
                hasSession: session, isDismissing: dismissing, onPlaybackScreen: playbackScreen, phase: phase
            )
        }
        XCTAssertEqual(visibility(), .init(visible: true, reason: "visible"))
        XCTAssertEqual(visibility(session: false), .init(visible: false, reason: "no_session"))
        XCTAssertEqual(visibility(dismissing: true), .init(visible: false, reason: "dismissing"))
        XCTAssertEqual(visibility(playbackScreen: true), .init(visible: false, reason: "on_playback_screen"))
        XCTAssertEqual(visibility(phase: .finished), .init(visible: false, reason: "session_finished"))
        XCTAssertEqual(visibility(phase: .abandoned), .init(visible: false, reason: "session_abandoned"))
        // No session outranks every other cause: that is the one the export has to show.
        XCTAssertEqual(visibility(session: false, dismissing: true, playbackScreen: true, phase: .finished).reason, "no_session")
    }

    /// The app's mini player and the record must agree for every phase, or the log would explain a different
    /// mini player from the one the listener saw.
    func testOnlyAFinishedOrAbandonedPhaseHidesTheMiniPlayerOfALiveSession() {
        let phases: [SessionPhase] = [
            .idle, .itemPlayback, .recordingInterjection, .interjectionSummary, .summaryPlayback,
            .addendumCapture, .aiResponsePlayback, .conversation, .finished, .abandoned,
        ]
        for phase in phases {
            let visible = NarrationOwnership.miniPlayerVisibility(
                hasSession: true, isDismissing: false, onPlaybackScreen: false, phase: phase
            ).visible
            XCTAssertEqual(visible, phase != .finished && phase != .abandoned, "\(phase)")
        }
    }

    func testRecordsCarryStateAndTokensOnly() {
        let narration = PlaybackDiagnosticFields.narration(intent: "playing", systemVoiceActive: false, standInPassage: false)
        let repair = NarrationOwnership.repairRecord(
            trigger: "foreground", repair: .stopNarration, itemToken: "aaaa", sessionToken: "bbbb", narration: narration
        )
        XCTAssertEqual(repair["trigger"], "foreground")
        XCTAssertEqual(repair["repair"], "stop_narration")
        XCTAssertEqual(repair["item"], "aaaa")
        XCTAssertEqual(repair["session"], "bbbb")
        XCTAssertEqual(repair["clientIntent"], "playing")
        XCTAssertEqual(Set(repair.keys), ["trigger", "repair", "item", "session", "clientIntent", "clientVoice", "clientStandIn"])

        let mini = NarrationOwnership.miniPlayerRecord(
            trigger: "live_activity_tap", visibility: .init(visible: false, reason: "no_session"), narration: narration
        )
        XCTAssertEqual(mini["visible"], "false")
        XCTAssertEqual(mini["reason"], "no_session")
        XCTAssertEqual(mini["trigger"], "live_activity_tap")
        XCTAssertEqual(mini["clientIntent"], "playing")
    }
}
