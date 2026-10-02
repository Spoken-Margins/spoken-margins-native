import Foundation
import SessionKit

/// A downloaded remote-stream item, so journeys use the normal podcast transport
/// and persistence path. Only an explicitly enabled UI-test launch can install it.
public enum UITestingOfflinePodcastSeed {
    public static let itemID = "item-ui-podcast"
    public static let title = "UI Test Offline Podcast"
    public static let durationMs = 120_096

    public static func install(
        configuration: UITestingSeedConfiguration,
        store: SQLiteSessionStore,
        fixtureURL: URL,
        applicationSupportDirectory: URL
    ) throws -> Item? {
        guard configuration.seedsOfflinePodcast, !configuration.preservesLibrary else { return nil }
        let fixture = try Data(contentsOf: fixtureURL)
        // The fixture contains 417 complete MP3 frames (10.008 s). Repeating
        // encoded frames creates a two-minute source without an encoder/network.
        var episode = Data()
        for _ in 0..<12 { episode.append(fixture) }
        let name = "ui-test-podcast.mp3"
        let directory = applicationSupportDirectory.appending(path: "PodcastAudio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try episode.write(to: directory.appending(path: name), options: .atomic)
        let remoteURL = "https://example.invalid/ui-test-podcast.mp3"
        let item = Item(
            id: itemID, title: title, mediaType: "podcast", text: nil, externalReference: remoteURL, status: "ready",
            media: ItemMedia(sourceType: .remoteStream, url: remoteURL, durationMs: durationMs)
        )
        try store.saveItem(item)
        try store.savePodcastDownload(PodcastDownloadRecord(
            id: "podcast-download-\(itemID)", itemId: itemID, remoteURL: remoteURL,
            localRelativePath: name, state: .availableOffline,
            bytesWritten: Int64(episode.count), expectedBytes: Int64(episode.count)
        ))
        return item
    }
}
