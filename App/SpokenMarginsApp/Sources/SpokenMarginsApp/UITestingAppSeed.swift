import Foundation
import SessionKit
import SessionKitPersistence

/// App bundle/storage wiring only; the opt-in policy and file clients are host-tested.
enum UITestingAppSeed {
    static var configuration: UITestingSeedConfiguration {
        UITestingSeedConfiguration(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    }

    static func fixtureURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "ui-test-margin", withExtension: "mp3", subdirectory: "fixtures/audio") else {
            throw SessionKitError.persistenceFailed("ui_test_recording_fixture_missing")
        }
        return url
    }

    static func supportDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    static func resetAndSeed(store: SQLiteSessionStore) throws -> Item? {
        let configuration = Self.configuration
        guard configuration.seedsLibrary else { return nil }
        try store.reset()
        if configuration.seedsOfflinePodcast {
            return try UITestingOfflinePodcastSeed.install(
                configuration: configuration, store: store,
                fixtureURL: fixtureURL(), applicationSupportDirectory: supportDirectory()
            )
        }
        let item = Item(
            id: "item-ui-text-regression", title: configuration.sourceTitle,
            mediaType: "text", text: configuration.sourceText,
            externalReference: configuration.sourceReference, status: "needs_listening_map"
        )
        try store.seed(item: item)
        return item
    }
}

extension Gate1AppModel {
    static func makeApplicationModel() -> Gate1AppModel {
        let configuration = UITestingAppSeed.configuration
        guard configuration.usesFixtureRecording else { return Gate1AppModel() }
        do {
            let recorder = configuration.makeRecordingClient(
                fixtureURL: try UITestingAppSeed.fixtureURL(),
                applicationSupportDirectory: try UITestingAppSeed.supportDirectory()
            )
            return Gate1AppModel(
                recordingClient: recorder,
                sourceTranscriptionClient: UITestingUnavailableSourceTranscriptionClient(),
                interjectionTranscriptionHandler: { _ in
                    throw SessionKitError.persistenceFailed(TranscriptionFailureWording.speechRecognitionOffError)
                }
            )
        } catch {
            // A broken opt-in fixture must fail the test launch, not fall through
            // to a real microphone prompt or an imaginary Noop recording.
            fatalError("UI-test recording seed failed: \(error)")
        }
    }
}

// Fixture audio is synthetic. Keep transcription unavailable rather than opening
// system speech permission dialogs or depending on downloadable recognition assets.
private struct UITestingUnavailableSourceTranscriptionClient: SourceTranscriptionClient {
    func transcribeSourceAudio(url: URL, itemId: String, durationMs: Int?) async throws -> TranscriptTimeline {
        throw SessionKitError.persistenceFailed(TranscriptionFailureWording.speechRecognitionOffError)
    }
}
