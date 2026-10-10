import Foundation
import XCTest
@testable import SessionKit

/// #854: leaving the app right after Save & resume, or right after play, left on-device narration silent until the
/// listener came back. Only a fresh start held background time, so every other way back into "starting" (resume
/// after a Margin, cancelling one, play from pause, the Lock Screen) could be suspended before the first word.
/// These tests drive a real engine through those starts and feed each snapshot to the protection, as the app does.
/// They are async only because Linux XCTest can't run a synchronous main-actor test.
@MainActor
final class NarrationStartupProtectionTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 8_540)

    func testResumingFromPauseIsProtectedUntilNarrationPlays() async throws {
        let (engine, audio) = try makeEngine()
        let ledger = Ledger()
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.statusChanged(to: try engine.syncPlaybackProgress().status, eligible: { true })

        protection.statusChanged(to: try engine.resumePlayback().status, eligible: { true })

        XCTAssertEqual(ledger.begins, 1, "play from pause goes back to starting and must hold background time")
        XCTAssertTrue(protection.isProtecting)
        XCTAssertEqual(protection.outcome, .protected)

        audio.confirmed = true
        let playing = try engine.syncPlaybackProgress()
        XCTAssertEqual(playing.status, .playing)
        protection.statusChanged(to: playing.status, eligible: { true })

        XCTAssertEqual(ledger.ends, 1, "released once narration plays")
        XCTAssertFalse(protection.isProtecting)
        XCTAssertEqual(protection.outcome, .completed)
    }

    func testResumingAfterASpokenMarginIsProtectedUntilNarrationPlays() async throws {
        for finishes in [true, false] {
            let label = finishes ? "Save & resume" : "cancel"
            let (engine, audio) = try makeEngine()
            let ledger = Ledger()
            let protection = ledger.protection(now: { [unowned self] in self.now })
            audio.confirmed = true
            protection.statusChanged(to: try engine.resumePlayback().status, eligible: { true })
            XCTAssertEqual(ledger.begins, 0, "\(label): a start confirmed at once needs no protection")
            protection.statusChanged(to: try engine.beginInterjection().status, eligible: { true })
            audio.confirmed = false

            let resumed = finishes ? try engine.finishInterjection(audioRef: nil) : try engine.cancelInterjection()

            XCTAssertEqual(resumed.status, .starting, label)
            protection.statusChanged(to: resumed.status, eligible: { true })
            XCTAssertEqual(ledger.begins, 1, "\(label): the resume after a Margin must hold background time")
            audio.confirmed = true
            protection.statusChanged(to: try engine.syncPlaybackProgress().status, eligible: { true })
            XCTAssertEqual(ledger.ends, 1, "\(label): released once narration plays")
            XCTAssertFalse(protection.isProtecting, label)
        }
    }

    func testResumingAfterAWrittenMarginIsProtectedUntilNarrationPlays() async throws {
        for saves in [true, false] {
            let label = saves ? "save" : "cancel"
            let (engine, audio) = try makeEngine()
            let ledger = Ledger()
            let protection = ledger.protection(now: { [unowned self] in self.now })
            audio.confirmed = true
            protection.statusChanged(to: try engine.resumePlayback().status, eligible: { true })
            let capture = try engine.beginWrittenInterjection()
            protection.statusChanged(to: engine.snapshot.status, eligible: { true })
            audio.confirmed = false

            let resumed = saves
                ? try engine.saveWrittenInterjection(captureId: capture.id, text: "A note.")
                : try engine.cancelWrittenInterjection(captureId: capture.id)

            XCTAssertEqual(resumed.status, .starting, label)
            protection.statusChanged(to: resumed.status, eligible: { true })
            XCTAssertEqual(ledger.begins, 1, "\(label): the resume after a written Margin must hold background time")
            audio.confirmed = true
            protection.statusChanged(to: try engine.syncPlaybackProgress().status, eligible: { true })
            XCTAssertEqual(ledger.ends, 1, label)
        }
    }

    func testAStartThatStaysStartingIsProtectedOnce() async {
        let ledger = Ledger()
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.protectUpcomingStart(eligible: true)

        // The item load and first render happen before the engine publishes "starting", so the protection has to
        // be open already here, not only once the first status arrives.
        XCTAssertEqual(ledger.begins, 1, "a fresh start holds background time before it reaches starting")
        XCTAssertTrue(protection.isProtecting)
        XCTAssertEqual(protection.outcome, .protected)

        protection.statusChanged(to: .starting, eligible: { true })
        protection.statusChanged(to: .starting, eligible: { true })

        XCTAssertEqual(ledger.begins, 1, "a fresh start's early protection carries into its starting status")
        XCTAssertTrue(protection.isProtecting)
        protection.statusChanged(to: .paused, eligible: { true })
        XCTAssertEqual(ledger.ends, 1, "pausing a pending start releases it")
    }

    func testAStartThatMovesToAnArticleWhileStartingIsProtected() async {
        let ledger = Ledger()
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.statusChanged(to: .starting, itemId: "podcast", eligible: { false })
        protection.statusChanged(to: .starting, itemId: "podcast", eligible: { XCTFail("same start, same item"); return true })
        XCTAssertEqual(ledger.begins, 0)

        protection.statusChanged(to: .starting, itemId: "article", eligible: { true })

        XCTAssertEqual(ledger.begins, 1)
        protection.statusChanged(to: .starting, itemId: "other-article", eligible: { true })
        XCTAssertEqual(ledger.begins, 1, "an open protection is not asked for again")
    }

    func testNarrationThatIsNotRenderedOnTheDeviceIsNotProtected() async {
        let ledger = Ledger()
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.protectUpcomingStart(eligible: false)

        XCTAssertEqual(ledger.begins, 0, "narration rendered elsewhere is not protected before it starts")
        XCTAssertFalse(protection.isProtecting)
        XCTAssertNil(protection.outcome)

        protection.statusChanged(to: .starting, eligible: { false })

        XCTAssertEqual(ledger.begins, 0)
        XCTAssertNil(protection.outcome)
    }

    func testAStartThatEndsInTheBackgroundRecordsHowLongItTookAndWhetherItPlayed() async {
        let ledger = Ledger()
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.statusChanged(to: .paused, eligible: { true })
        protection.statusChanged(to: .starting, eligible: { true })
        now += 0.4

        protection.appEnteredBackground()
        now += 2.1
        protection.statusChanged(to: .playing, eligible: { true })
        now += 30
        protection.appEnteredForeground()

        XCTAssertEqual(ledger.events.map(\.kind), ["app.background", "startup.background_end", "app.foreground"])
        XCTAssertEqual(ledger.events[0].fields, ["status": "starting", "protected": "true", "startingMs": "400"])
        XCTAssertEqual(ledger.events[1].fields, [
            "durationMs": "2500", "reachedPlaying": "true", "status": "playing",
            "startedInBackground": "false", "outcome": "protected",
        ])
        XCTAssertEqual(ledger.events[2].fields, ["status": "playing", "protected": "false"])
    }

    func testAStartThatEndsInTheForegroundRecordsNoStartupEvent() async {
        let ledger = Ledger()
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.statusChanged(to: .starting, eligible: { true })
        protection.appEnteredBackground()
        protection.appEnteredForeground()
        protection.statusChanged(to: .playing, eligible: { true })

        XCTAssertEqual(ledger.events.map(\.kind), ["app.background", "app.foreground"])
    }

    func testABackgroundStartThatNeverPlaysSaysSo() async {
        let ledger = Ledger()
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.appEnteredBackground()
        protection.statusChanged(to: .starting, eligible: { true })
        now += 5
        protection.statusChanged(to: .failed, eligible: { true })

        XCTAssertEqual(ledger.events.last?.kind, "startup.background_end")
        XCTAssertEqual(ledger.events.last?.fields["reachedPlaying"], "false")
        XCTAssertEqual(ledger.events.last?.fields["status"], "failed")
        XCTAssertEqual(ledger.events.last?.fields["startedInBackground"], "true")
        XCTAssertEqual(ledger.events.last?.fields["durationMs"], "5000")
    }

    func testRepeatedLifecycleCallsRecordOneEventEach() async {
        let ledger = Ledger()
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.appEnteredForeground()
        protection.appEnteredBackground()
        protection.appEnteredBackground()
        protection.appEnteredForeground()
        protection.appEnteredForeground()

        XCTAssertEqual(ledger.events.map(\.kind), ["app.background", "app.foreground"])
    }

    func testExpiryReleasesTheProtectionAndALateExpiryLeavesTheNextOneAlone() async {
        let ledger = Ledger()
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.statusChanged(to: .starting, eligible: { true })
        ledger.expire(0)

        XCTAssertFalse(protection.isProtecting)
        XCTAssertEqual(protection.outcome, .expired)
        XCTAssertEqual(ledger.ends, 1)

        protection.statusChanged(to: .paused, eligible: { true })
        XCTAssertEqual(ledger.ends, 1, "an expired protection is not released twice")
        protection.statusChanged(to: .starting, eligible: { true })
        ledger.expire(0)
        XCTAssertTrue(protection.isProtecting, "the first protection's expiry must not end the second")
        XCTAssertEqual(ledger.begins, 2)
        XCTAssertEqual(ledger.outcomes, [.protected, .expired, .protected], "each outcome reaches the diagnostics")
    }

    func testARefusedProtectionIsReportedAsUnavailable() async {
        let ledger = Ledger()
        ledger.refuses = true
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.statusChanged(to: .starting, eligible: { true })

        XCTAssertFalse(protection.isProtecting)
        XCTAssertEqual(protection.outcome, .unavailable)
    }

    func testStopReleasesAnOpenProtection() async {
        let ledger = Ledger()
        let protection = ledger.protection(now: { [unowned self] in self.now })
        protection.statusChanged(to: .starting, eligible: { true })
        protection.stop()

        XCTAssertEqual(ledger.ends, 1)
        XCTAssertFalse(protection.isProtecting)
    }

    // MARK: - Fixture

    private func makeEngine() throws -> (SessionEngine, PendingStartSpeechClient) {
        let item = Item(
            id: "item-854", title: "Article", mediaType: "text",
            text: "First sentence of the article. Second sentence of the article.",
            externalReference: nil, status: "ready"
        )
        let session = Session(
            id: "session-854", itemId: item.id, status: "in_progress", phase: .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: item.id,
            position: Position(charOffset: 31), completionPercent: 40, playbackRate: 1
        )
        let audio = PendingStartSpeechClient()
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "phone", displayName: "Phone",
                capabilities: [
                    "sync": ["canonical_persistence"], "playback": ["realtime_tts"],
                    "interjection": ["record_audio", "delegate_interjection_to_canonical_runtime"],
                ]
            ),
            repository: InMemorySessionRepository(items: [item.id: item], sessions: [session.id: session]),
            audio: audio,
            now: { [unowned self] in self.now }
        )
        _ = try engine.inspectSession(sessionId: session.id)
        return (engine, audio)
    }
}

/// Counts the background time asked for and given back, standing in for UIApplication's background tasks.
@MainActor
private final class Ledger {
    var begins = 0
    var ends = 0
    var refuses = false
    var events: [(kind: String, fields: [String: String])] = []
    var outcomes: [NarrationStartupProtection.Outcome] = []
    private var expiries: [@MainActor () -> Void] = []

    func protection(now: @escaping () -> Date) -> NarrationStartupProtection {
        NarrationStartupProtection(
            begin: { [unowned self] _, expired in
                guard !self.refuses else { return nil }
                self.begins += 1
                self.expiries.append(expired)
                var ended = false
                return { [unowned self] in
                    guard !ended else { return }
                    ended = true
                    self.ends += 1
                }
            },
            record: { [unowned self] kind, fields in self.events.append((kind, fields)) },
            outcomeChanged: { [unowned self] in self.outcomes.append($0) },
            now: now
        )
    }

    func expire(_ index: Int) {
        guard expiries.indices.contains(index) else { return XCTFail("no protection \(index) to expire") }
        expiries[index]()
    }
}

/// On-device narration whose start stays pending until the test confirms it, like a Supertonic chunk still
/// rendering or the player still buffering.
private final class PendingStartSpeechClient: AudioPlaybackClient {
    var confirmed = false
    private var charOffset = 31

    func configureMediaContext(_ context: PlaybackMediaContext?) throws {}
    func configureSpeechSettings(voiceIdentifier: String?, rate: Float) throws {}
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws {}
    func play(targetId: String, from charOffset: Int) throws { self.charOffset = charOffset }
    func play(targetId: String, seekingTo charOffset: Int) throws { self.charOffset = charOffset }
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {}
    func seek(toMediaTimeMs mediaTimeMs: Int) throws {}
    func pause() throws {}
    func currentPlaybackPosition() -> PlaybackPosition? {
        PlaybackPosition(targetType: .itemTextTTS, targetId: "item-854", textStart: charOffset, textEnd: charOffset + 6)
    }
    func playbackStartStatus(targetId: String) -> PlaybackStartStatus { confirmed ? .confirmed : .pending }
}
