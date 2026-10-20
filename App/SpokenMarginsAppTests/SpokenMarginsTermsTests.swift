import XCTest
import SessionKit
import SessionKitSupertonic
@testable import SpokenMarginsApp

final class SpokenMarginsTermsStorageTests: XCTestCase {
    func testAcceptanceIsVersionedAndExpiresWhenTheVersionChanges() throws {
        let suiteName = "SpokenMarginsTermsStorageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(SpokenMarginsTerms.hasAcceptedCurrentVersion(in: defaults))

        let acceptedAt = Date(timeIntervalSince1970: 1_790_000_000)
        SpokenMarginsTerms.recordAcceptance(at: acceptedAt, in: defaults)

        XCTAssertTrue(SpokenMarginsTerms.hasAcceptedCurrentVersion(in: defaults))
        XCTAssertEqual(SpokenMarginsTerms.acceptedVersion(in: defaults), SpokenMarginsTerms.currentVersion)
        XCTAssertEqual(SpokenMarginsTerms.acceptedAt(in: defaults), acceptedAt)

        defaults.set("older-version", forKey: SpokenMarginsTerms.acceptanceVersionKey)
        XCTAssertFalse(SpokenMarginsTerms.hasAcceptedCurrentVersion(in: defaults))
    }

    func testBundledTermsContainTheOpenRAILAgreementAndMaterialChangeRule() {
        XCTAssertTrue(SpokenMarginsTerms.hasBundledText())
        let text = SpokenMarginsTerms.bundledText()

        XCTAssertTrue(text.contains("Agree and Enable On-Device Voice"))
        XCTAssertTrue(text.contains("paragraph 5 and Attachment A"))
        XCTAssertTrue(text.contains("material change"))
        XCTAssertTrue(text.contains("Apple Standard EULA"))
    }
}

@MainActor
final class SupertonicTermsGateTests: XCTestCase {
    func testStoredSupertonicVoiceFallsBackToSystemUntilTermsAreAccepted() throws {
        let snapshot = StandardDefaultsSnapshot(keys: termsAndVoiceDefaultsKeys)
        defer { snapshot.restore() }
        let defaults = UserDefaults.standard
        SpokenMarginsTerms.clearAcceptance(in: defaults)
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.james.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("supertonic", forKey: "ttsMode")

        let model = Gate1AppModel(audioPlaybackClient: TermsNoopAudioPlaybackClient())

        XCTAssertFalse(model.hasAcceptedCurrentTerms)
        XCTAssertEqual(model.ttsVoiceSelection, .system)
        XCTAssertEqual(model.ttsMode, "systemImmediate")
        XCTAssertEqual(defaults.string(forKey: "ttsVoiceSelection"), AppTTSVoiceSelection.system.rawValue)
        XCTAssertThrowsError(try model.verifyCurrentTermsForOnDeviceVoice()) { error in
            XCTAssertEqual(error as? SpokenMarginsTermsError, .acceptanceRequired)
        }
    }

    func testSelectingSupertonicPresentsTermsAndAcceptanceEnablesPendingVoice() {
        let snapshot = StandardDefaultsSnapshot(keys: termsAndVoiceDefaultsKeys)
        defer { snapshot.restore() }
        let defaults = UserDefaults.standard
        SpokenMarginsTerms.clearAcceptance(in: defaults)
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.system.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("systemImmediate", forKey: "ttsMode")
        let model = Gate1AppModel(audioPlaybackClient: TermsNoopAudioPlaybackClient())

        model.ttsVoiceSelection = .lily
        model.ttsVoiceSelectionChanged()

        XCTAssertTrue(model.isTermsOfUsePresented)
        XCTAssertEqual(model.ttsVoiceSelection, .system)
        XCTAssertFalse(model.hasAcceptedCurrentTerms)

        model.acceptCurrentTermsAndEnableOnDeviceVoice()

        XCTAssertFalse(model.isTermsOfUsePresented)
        XCTAssertTrue(model.hasAcceptedCurrentTerms)
        XCTAssertEqual(model.ttsVoiceSelection, .lily)
        XCTAssertEqual(defaults.string(forKey: SpokenMarginsTerms.acceptanceVersionKey), SpokenMarginsTerms.currentVersion)
        XCTAssertEqual(defaults.string(forKey: "ttsVoiceSelection"), AppTTSVoiceSelection.lily.rawValue)
        XCTAssertNoThrow(try model.verifyCurrentTermsForOnDeviceVoice())
    }

    /// #2125: a Supertonic preview takes seconds to render. If the listener picks another voice or starts an
    /// item meanwhile, the preview must not play when the render lands.
    func testAPendingVoicePreviewIsDroppedByAVoiceChangeOrPlaybackStart() throws {
        let snapshot = StandardDefaultsSnapshot(keys: termsAndVoiceDefaultsKeys)
        defer { snapshot.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(audioPlaybackClient: TermsNoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appendingPathComponent("preview.sqlite"))
        model.resetAndSeed()

        let beforeVoiceChange = model.supertonicPreviewRequest.begin(voice: .m1)
        model.ttsVoiceSelectionChanged()
        XCTAssertFalse(model.supertonicPreviewRequest.isPending, "a voice change cancels the preview")
        XCTAssertFalse(model.supertonicPreviewRequest.mayPlay(beforeVoiceChange, selectedVoice: .m1, otherAudioActive: false))

        let beforePlayback = model.supertonicPreviewRequest.begin(voice: .m1)
        model.startItem(id: "item-pill")
        XCTAssertFalse(model.supertonicPreviewRequest.isPending, "starting an item cancels the preview")
        XCTAssertNotNil(model.snapshot.sessionId)
        XCTAssertFalse(model.supertonicPreviewRequest.mayPlay(beforePlayback, selectedVoice: .m1, otherAudioActive: false))

        let duringPlayback = model.supertonicPreviewRequest.begin(voice: .m1)
        XCTAssertFalse(model.supertonicPreviewRequest.mayPlay(duringPlayback, selectedVoice: .m1, otherAudioActive: true),
                       "a preview never plays over narration")
        model.endSession()
    }

    /// #2219: with James chosen and no Supertonic download (#1820), "Try App Voice" asked Supertonic anyway and the
    /// listener got "On-device voice preview failed". The sample is spoken by Kitten, the voice reading to them now,
    /// and the status line points to Settings › Voices. With the model present, `OnDeviceVoicePreviewTests` covers
    /// Supertonic speaking it as before.
    @MainActor
    func testTryAppVoiceWithoutTheSupertonicDownloadPlaysKittensSample() async throws {
        let snapshot = StandardDefaultsSnapshot(keys: termsAndVoiceDefaultsKeys)
        defer { snapshot.restore() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Gate1AppModel(audioPlaybackClient: TermsNoopAudioPlaybackClient(),
                                  databaseURLOverride: root.appendingPathComponent("kitten-preview.sqlite"))
        model.resetAndSeed()
        try XCTSkipIf(model.supertonicModel.isModelPresent, "a Supertonic download is present, so James would speak the sample")
        model.acceptCurrentTermsAndEnableOnDeviceVoice()
        model.ttsVoiceSelection = .james
        model.lastError = nil

        model.previewAppVoice()
        XCTAssertTrue(model.isRenderingSupertonicPreview)
        // Kitten loads its bundled model first, which takes a while on a busy lane.
        let deadline = Date().addingTimeInterval(90)
        while model.isRenderingSupertonicPreview, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { model.stopSpeechPreviews() }

        XCTAssertFalse(model.isRenderingSupertonicPreview)
        XCTAssertNil(model.lastError, "the missing download must not fail the preview")
        XCTAssertEqual(model.diagnostics["supertonicPreview"], SupertonicModelNotDownloaded.fallbackCode)
        XCTAssertEqual(model.diagnostics["supertonicPreviewEngine"], KittenNarrationRenderer.engine)
        XCTAssertTrue(model.statusMessage.contains("Settings › Voices"), model.statusMessage)
        XCTAssertEqual(model.ttsVoiceSelection, .james, "the preview never changes the chosen voice")
    }

    func testDecliningTermsKeepsSystemVoiceAndDoesNotRecordAcceptance() {
        let snapshot = StandardDefaultsSnapshot(keys: termsAndVoiceDefaultsKeys)
        defer { snapshot.restore() }
        let defaults = UserDefaults.standard
        SpokenMarginsTerms.clearAcceptance(in: defaults)
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.system.rawValue, forKey: "ttsVoiceSelection")
        let model = Gate1AppModel(audioPlaybackClient: TermsNoopAudioPlaybackClient())

        model.ttsVoiceSelection = .james
        model.ttsVoiceSelectionChanged()
        model.declineCurrentTerms()

        XCTAssertFalse(model.isTermsOfUsePresented)
        XCTAssertFalse(model.hasAcceptedCurrentTerms)
        XCTAssertEqual(model.ttsVoiceSelection, .system)
        XCTAssertNil(defaults.string(forKey: SpokenMarginsTerms.acceptanceVersionKey))
    }

    func testCurrentAcceptancePreservesStoredSupertonicVoice() throws {
        let snapshot = StandardDefaultsSnapshot(keys: termsAndVoiceDefaultsKeys)
        defer { snapshot.restore() }
        let defaults = UserDefaults.standard
        SpokenMarginsTerms.recordAcceptance(in: defaults)
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.james.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("supertonic", forKey: "ttsMode")

        let model = Gate1AppModel(audioPlaybackClient: TermsNoopAudioPlaybackClient())

        XCTAssertTrue(model.hasAcceptedCurrentTerms)
        XCTAssertEqual(model.ttsVoiceSelection, .james)
        XCTAssertEqual(model.ttsMode, "supertonic")
        XCTAssertNoThrow(try model.verifyCurrentTermsForOnDeviceVoice())
    }

    func testFirstPlaybackPromptsForTermsAndAcceptanceContinuesWithSupertonic() {
        let snapshot = StandardDefaultsSnapshot(keys: termsAndVoiceDefaultsKeys)
        defer { snapshot.restore() }
        let defaults = UserDefaults.standard
        SpokenMarginsTerms.clearAcceptance(in: defaults)
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.james.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("supertonic", forKey: "ttsMode")
        _ = Gate1AppModel(audioPlaybackClient: TermsNoopAudioPlaybackClient())
        let model = Gate1AppModel(audioPlaybackClient: TermsNoopAudioPlaybackClient())
        model.resetAndSeed()

        model.start()

        XCTAssertTrue(model.isTermsOfUsePresented)
        XCTAssertNil(model.snapshot.sessionId)

        model.acceptCurrentTermsAndEnableOnDeviceVoice()

        XCTAssertFalse(model.isTermsOfUsePresented)
        XCTAssertEqual(model.ttsVoiceSelection, .james)
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertNotNil(model.snapshot.sessionId)
    }

    func testDecliningFirstPlaybackTermsContinuesWithIOSVoice() {
        let snapshot = StandardDefaultsSnapshot(keys: termsAndVoiceDefaultsKeys)
        defer { snapshot.restore() }
        let defaults = UserDefaults.standard
        SpokenMarginsTerms.clearAcceptance(in: defaults)
        defaults.set(true, forKey: "supertonicTTSMigrationV1")
        defaults.set(AppTTSVoiceSelection.james.rawValue, forKey: "ttsVoiceSelection")
        defaults.set("supertonic", forKey: "ttsMode")
        let model = Gate1AppModel(audioPlaybackClient: TermsNoopAudioPlaybackClient())
        model.resetAndSeed()

        model.start()
        model.declineCurrentTerms()

        XCTAssertFalse(model.isTermsOfUsePresented)
        XCTAssertFalse(model.hasAcceptedCurrentTerms)
        XCTAssertEqual(model.ttsVoiceSelection, .system)
        XCTAssertEqual(model.ttsMode, "systemImmediate")
        XCTAssertEqual(model.snapshot.status, .playing)
        XCTAssertNotNil(model.snapshot.sessionId)
    }

    private var termsAndVoiceDefaultsKeys: [String] {
        [
            SpokenMarginsTerms.acceptanceVersionKey,
            SpokenMarginsTerms.acceptanceDateKey,
            "supertonicTTSMigrationV1",
            "supertonicVoicePendingTermsV1",
            "ttsVoiceSelection",
            "ttsMode"
        ]
    }
}

private struct StandardDefaultsSnapshot {
    private let values: [String: Any]
    private let keys: [String]

    init(keys: [String]) {
        self.keys = keys
        self.values = keys.reduce(into: [:]) { values, key in
            values[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    func restore() {
        for key in keys {
            if let value = values[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

private final class TermsNoopAudioPlaybackClient: AudioPlaybackClient {
    func prepareSpeechText(_ text: String) throws -> String { text }
    func play(targetId: String) throws {}
    func pause() throws {}
}
