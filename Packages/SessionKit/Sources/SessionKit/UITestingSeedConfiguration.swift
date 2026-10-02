import Foundation

/// Environment hooks never take effect on an ordinary application launch.
public struct UITestingSeedConfiguration: Sendable {
    public let usesFixtureRecording: Bool
    public let seedsOfflinePodcast: Bool
    public let preservesLibrary: Bool
    public let sourceText: String?
    public let sourceTitle: String
    public let sourceReference: String

    public init(arguments: [String], environment: [String: String]) {
        let enabled = arguments.contains("--ui-testing")
        usesFixtureRecording = enabled && environment["SPOKEN_MARGINS_UI_TEST_RECORDING"] == "1"
        seedsOfflinePodcast = enabled && environment["SPOKEN_MARGINS_UI_TEST_PODCAST"] == "1"
        preservesLibrary = enabled && environment["SPOKEN_MARGINS_UI_TEST_PRESERVE_LIBRARY"] == "1"
        sourceText = enabled ? environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] : nil
        sourceTitle = environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"] ?? "UI Test Text"
        sourceReference = environment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] ?? "ui-test"
    }

    public var seedsLibrary: Bool { !preservesLibrary && (seedsOfflinePodcast || sourceText != nil) }

    public func makeRecordingClient(fixtureURL: URL, applicationSupportDirectory: URL) -> (any RecordingClient)? {
        guard usesFixtureRecording else { return nil }
        return UITestingFixtureRecordingClient(
            fixtureURL: fixtureURL, applicationSupportDirectory: applicationSupportDirectory
        )
    }
}

/// Copies already encoded fixture audio; does not access a microphone or audio session.
/// Saved paths use the same relative interjections/ convention as SystemRecordingClient.
public final class UITestingFixtureRecordingClient: RecordingClient {
    private let fixtureURL: URL
    private let applicationSupportDirectory: URL
    private var isRecording = false

    public init(fixtureURL: URL, applicationSupportDirectory: URL) {
        self.fixtureURL = fixtureURL
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public func beginRecording() throws {
        guard !isRecording else { throw SessionKitError.invalidCommandForState("beginRecording") }
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw SessionKitError.persistenceFailed("ui_test_recording_fixture_missing")
        }
        isRecording = true
    }

    public func finishRecording(audioRef: String?) throws -> String {
        guard isRecording else { throw SessionKitError.invalidCommandForState("finishRecording") }
        // Ignore caller paths, which must not overwrite an existing recording.
        let path = "interjections/ui-test-\(UUID().uuidString).\(fixtureURL.pathExtension)"
        let destination = applicationSupportDirectory.appending(path: "SpokenMargins").appending(path: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtureURL, to: destination)
        isRecording = false
        return path
    }

    public func cancelRecording() throws { isRecording = false }
}
