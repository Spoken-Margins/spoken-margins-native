import Foundation
import SessionKit

/// Installs a local enclosure through the same persisted download record used by the app.
public enum UITestPodcastSeed {
    public static let environmentKey = "SPOKEN_MARGINS_UI_TEST_PODCAST"
    public static let itemID = "item-ui-podcast-j2"
    public static let title = "J2: Offline podcast"
    public static let fixtureName = "evidence-length-48k-stereo"
    public static let durationMs = 40_032

    @discardableResult
    public static func installIfRequested(
        arguments: [String],
        environment: [String: String],
        store: SQLiteSessionStore,
        fixtureURL: () throws -> URL,
        applicationSupportDirectory: () throws -> URL
    ) throws -> Bool {
        guard arguments.contains("--ui-testing"), environment[environmentKey] == "1" else {
            return false
        }
        // Resolve and read before resetting: a missing bundled fixture must fail explicitly.
        let audio = try Data(contentsOf: fixtureURL())
        guard !audio.isEmpty, audio.count < 1_000_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let directory = try applicationSupportDirectory().appending(path: "PodcastAudio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let relativePath = "ui-test-j2.mp3"
        try audio.write(to: directory.appending(path: relativePath), options: .atomic)

        // Keep a remote canonical enclosure, just like a downloaded podcast. Playback
        // must use the persisted local transport; a network fallback cannot pass J2.
        let remoteURL = "https://example.invalid/j2-offline-podcast.mp3"
        let item = Item(
            id: itemID, title: title, mediaType: "podcast", text: nil,
            externalReference: remoteURL, status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: remoteURL, durationMs: durationMs)
        )
        try store.reset()
        try store.saveItem(item)
        try store.savePodcastDownload(PodcastDownloadRecord(
            id: "podcast-download-\(itemID)", itemId: itemID, remoteURL: remoteURL,
            localRelativePath: relativePath, state: .availableOffline,
            bytesWritten: Int64(audio.count), expectedBytes: Int64(audio.count)
        ))
        return true
    }
}
