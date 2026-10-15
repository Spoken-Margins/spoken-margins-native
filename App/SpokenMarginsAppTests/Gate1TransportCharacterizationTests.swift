import XCTest
import SessionKit
@testable import SpokenMarginsApp

/// #1022 (slice X21): the transport rules pinned before playback transport moves out of the model.
/// Mix with Other Audio is a transaction: a client failure rolls the audio client, remote commands and
/// Now Playing back to where they were. The compact application commands and compact URLs route the
/// way the table below says. The preference keys these tests touch are saved in `setUp` and restored
/// in `tearDown`.
@MainActor
final class Gate1TransportCharacterizationTests: XCTestCase {
    private static let tourTombstoneKey = "guidedOnboardingTombstone"
    private static let mixOptionKey = "showsMixWithOtherAudioOption"
    private var priorDefaults: [String: Any] = [:]
    private var voicePreferences: VoicePreferencesSnapshot!
    private var root: URL!

    override func setUp() {
        super.setUp()
        voicePreferences = VoicePreferencesSnapshot.capture()
        for key in [Self.tourTombstoneKey, Self.mixOptionKey] {
            priorDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.set(true, forKey: Self.tourTombstoneKey)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Gate1TransportCharacterizationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for key in [Self.tourTombstoneKey, Self.mixOptionKey] {
            if let value = priorDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        priorDefaults = [:]
        voicePreferences.restore()
        voicePreferences = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeModel(audio: AudioPlaybackClient = NoopAudioPlaybackClient()) -> Gate1AppModel {
        Gate1AppModel(audioPlaybackClient: audio, databaseURLOverride: root.appendingPathComponent("library.sqlite"))
    }

    private func modelWithMixOptionShown(audio: AudioPlaybackClient) -> Gate1AppModel {
        let model = makeModel(audio: audio)
        model.showsMixWithOtherAudioOption = true
        model.mixWithOtherAudioAvailabilityChanged()
        return model
    }

    private func nowPlayingEnabled(_ model: Gate1AppModel) -> String? {
        model.gate2CompactControls.diagnostics()["gate2NowPlayingEnabled"]
    }

    // MARK: Mix with Other Audio rollback

    func testEnablingMixFailureRollsBackToSystemOwnedPlayback() {
        let audio = MixTransactionRecordingClient(failingMixState: true)
        let model = modelWithMixOptionShown(audio: audio)
        XCTAssertEqual(nowPlayingEnabled(model), "true")
        audio.calls.removeAll()

        model.setMixesWithOtherAudio(true)

        XCTAssertFalse(model.mixesWithOtherAudio)
        XCTAssertEqual(audio.calls, [
            .remoteCommands(false),
            .mix(true),
            .mix(false),
            .volume(1),
            .remoteCommands(true)
        ])
        XCTAssertEqual(audio.remoteCommandStates.last, true)
        XCTAssertEqual(nowPlayingEnabled(model), "true")
        XCTAssertEqual(model.lastError?.hasPrefix("Audio mixing update failed"), true)
        XCTAssertEqual(model.diagnostics["recentFailure"], model.lastError)
    }

    func testDisablingMixFailureRollsBackToMixedPlayback() {
        let audio = MixTransactionRecordingClient(failingMixState: false)
        let model = modelWithMixOptionShown(audio: audio)
        model.setMixesWithOtherAudio(true)
        XCTAssertTrue(model.mixesWithOtherAudio)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(nowPlayingEnabled(model), "false")
        let mixedVolume = Float(model.mixedPlaybackVolume)
        audio.calls.removeAll()

        model.setMixesWithOtherAudio(false)

        XCTAssertTrue(model.mixesWithOtherAudio)
        XCTAssertFalse(model.lowersBackgroundAudio)
        XCTAssertEqual(audio.calls, [
            .lowersBackground(false),
            .mix(false),
            .remoteCommands(false),
            .mix(true),
            .lowersBackground(false),
            .volume(mixedVolume)
        ])
        XCTAssertEqual(audio.remoteCommandStates.last, false)
        XCTAssertEqual(nowPlayingEnabled(model), "false")
        XCTAssertEqual(model.lastError?.hasPrefix("Audio mixing update failed"), true)
    }

    func testEnablingMixWhileTheOptionIsHiddenReportsAFailureAndTouchesNoClient() {
        let audio = MixTransactionRecordingClient(failingMixState: nil)
        let model = makeModel(audio: audio)
        model.showsMixWithOtherAudioOption = false
        audio.calls.removeAll()

        model.setMixesWithOtherAudio(true)

        XCTAssertFalse(model.mixesWithOtherAudio)
        XCTAssertEqual(audio.calls, [])
        XCTAssertEqual(
            model.lastError,
            "Enable Mix with Other Audio in Settings before using it for a listening session."
        )
    }

    // MARK: Compact application command routing

    func testSummarizeAndDiscussWhenUnavailableReturnFalseAndReportAFailure() {
        let model = makeModel()
        XCTAssertNil(model.gate2CompactSnapshot)

        XCTAssertFalse(model.handleGate2CompactApplicationCommand(Gate2CompactApplicationCommand.summarizeInterjections))
        XCTAssertEqual(model.lastError, "Summary is unavailable for the current compact surface state.")

        model.lastError = nil
        XCTAssertFalse(model.handleGate2CompactApplicationCommand(Gate2CompactApplicationCommand.discussInterjections))
        XCTAssertEqual(model.lastError, "Discuss is unavailable for the current compact surface state.")
    }

    func testListenAndDismissWithNoPendingSharedMarginReturnFalseSilently() {
        let model = makeModel()
        XCTAssertNil(model.pendingImportedCommentary)

        XCTAssertFalse(model.handleGate2CompactApplicationCommand(Gate2CompactApplicationCommand.listenToSharedMargin))
        XCTAssertFalse(model.handleGate2CompactApplicationCommand(Gate2CompactApplicationCommand.dismissSharedMargin))
        XCTAssertNil(model.lastError)
    }

    func testJumpWithAMissingOrEmptyTargetReturnsFalse() {
        let model = makeModel()

        XCTAssertFalse(model.handleGate2CompactApplicationCommand(Gate2CompactApplicationCommand.jumpToSharedMargin))
        XCTAssertFalse(
            model.handleGate2CompactApplicationCommand(Gate2CompactApplicationCommand.jumpToSharedMargin, targetID: "")
        )
        XCTAssertNil(model.lastError)
    }

    func testUnknownApplicationCommandReturnsFalseAndReportsAFailure() {
        let model = makeModel()

        XCTAssertFalse(model.handleGate2CompactApplicationCommand("notACompactCommand"))
        XCTAssertEqual(model.lastError, "Unsupported compact application command.")
    }

    // MARK: Compact URL routing

    func testUnsupportedCompactURLsReportAFailure() throws {
        let rows: [(String, URL)] = [
            ("another scheme", try XCTUnwrap(URL(string: "https://example.com/compact-control?command=pause"))),
            ("another host", try XCTUnwrap(URL(string: "\(Gate2CompactCommandURL.scheme)://elsewhere?command=pause"))),
            ("no command", try XCTUnwrap(URL(string: "\(Gate2CompactCommandURL.scheme)://\(Gate2CompactCommandURL.host)"))),
            ("unknown command", Gate2CompactCommandURL.url(command: "notACompactCommand")),
            ("application command that declines", Gate2CompactCommandURL.url(
                command: Gate2CompactApplicationCommand.listenToSharedMargin
            ))
        ]
        for (label, url) in rows {
            let model = makeModel()

            model.handleGate2CompactURL(url)

            XCTAssertEqual(model.lastError, "Unsupported compact control URL.", label)
        }
    }

    func testTransportURLDispatchesWithTheCompactURLOrigin() {
        SpokenMarginsTerms.recordAcceptance()
        let model = makeModel()
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        XCTAssertTrue(model.gate2CompactSnapshot?.availableCommands.contains(.pause) == true)

        model.handleGate2CompactURL(Gate2CompactCommandURL.url(command: CompactControlCommand.pause.rawValue))

        XCTAssertEqual(model.gate2CompactControls.lastCommand, .pause)
        XCTAssertEqual(model.gate2CompactControls.lastCommandOrigin, "compact_url")
        XCTAssertEqual(model.snapshot.status, .paused)
        XCTAssertNil(model.lastError)
    }

    // MARK: Live Activity tap (#1337)

    /// The owner tapped a playing Live Activity and stayed wherever the app was last, with no way to the player.
    func testTappingAPlayingLiveActivityOpensPlaybackAndOtherCardsKeepTheirTaps() {
        func card(status: String, isRecording: Bool = false, sharedFrom: String? = nil) -> Gate2LiveActivityAttributes.ContentState {
            .init(title: "Episode", chapterTitle: "Opening", status: status, phase: "itemPlayback", progressPercent: 10,
                  isRecording: isRecording, sharedMarginSenderLabel: sharedFrom)
        }
        let open = Gate2CompactCommandURL.url(command: Gate2CompactApplicationCommand.openPlayback)
        let play = Gate2CompactCommandURL.url(command: "play")
        XCTAssertEqual(card(status: "playing").tapURL(isStale: false), open)
        XCTAssertEqual(card(status: "paused").tapURL(isStale: false), play, "a paused card still resumes")
        XCTAssertEqual(card(status: "playing").tapURL(isStale: true), play, "a stale card still resumes")
        XCTAssertNil(card(status: "playing", isRecording: true).tapURL(isStale: false), "a recording card just opens the app")
        XCTAssertNil(card(status: "playing", sharedFrom: "A friend").tapURL(isStale: false))
    }

    func testTheOpenPlaybackLinkShowsPlaybackFromAnotherScreenAndKeepsTheSession() {
        SpokenMarginsTerms.recordAcceptance()
        let model = makeModel()
        model.resetAndSeed()
        model.startItem(id: "item-pill")
        let sessionId = model.snapshot.sessionId
        XCTAssertNotNil(sessionId, "precondition: something is playing")
        model.screen = .home

        model.handleGate2CompactURL(Gate2CompactCommandURL.url(command: Gate2CompactApplicationCommand.openPlayback))

        XCTAssertEqual(model.screen, .playback)
        XCTAssertEqual(model.snapshot.sessionId, sessionId)
        XCTAssertNil(model.lastError)
    }

    func testTheOpenPlaybackLinkWithNoSessionReportsItAndNothingElse() {
        let model = makeModel()
        XCTAssertFalse(model.hasActiveSession)
        let screen = model.screen

        model.handleGate2CompactURL(Gate2CompactCommandURL.url(command: Gate2CompactApplicationCommand.openPlayback))

        XCTAssertEqual(model.lastError, "Nothing is playing right now.", "the URL router must not overwrite it")
        XCTAssertEqual(model.screen, screen)
    }
}

/// Records every call that the mix transaction makes, in order, and throws on `setMixesWithOtherAudio`
/// for one chosen state.
private final class MixTransactionRecordingClient: AudioPlaybackClient {
    enum Call: Equatable {
        case mix(Bool)
        case lowersBackground(Bool)
        case volume(Float)
        case remoteCommands(Bool)
    }

    struct MixFailure: LocalizedError {
        var errorDescription: String? { "test mix failure" }
    }

    private let failingMixState: Bool?
    var calls: [Call] = []
    var remoteCommandStates: [Bool] {
        calls.compactMap { if case .remoteCommands(let enabled) = $0 { enabled } else { nil } }
    }

    init(failingMixState: Bool?) {
        self.failingMixState = failingMixState
    }

    func prepareSpeechText(_ text: String) throws -> String {
        SpeechTextNormalizer.normalize(text)
    }

    func play(targetId: String) throws {}

    func pause() throws {}

    func setMixesWithOtherAudio(_ enabled: Bool) throws {
        calls.append(.mix(enabled))
        if enabled == failingMixState { throw MixFailure() }
    }

    func setLowersBackgroundAudio(_ enabled: Bool) throws {
        calls.append(.lowersBackground(enabled))
    }

    func setPlaybackVolume(_ volume: Float) throws {
        calls.append(.volume(volume))
    }

    func setRemoteCommandHandlingEnabled(_ enabled: Bool) {
        calls.append(.remoteCommands(enabled))
    }
}
