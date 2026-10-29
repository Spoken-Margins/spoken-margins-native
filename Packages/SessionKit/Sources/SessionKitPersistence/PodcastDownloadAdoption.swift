import Foundation
import SessionKit

/// The file and row work of finishing a podcast download, off the caller's actor (#2507, #2509, #2510).
///
/// `PodcastDownloadCoordinator.finishDownload` checked, moved and sniffed the staged file and then saved the
/// asset and download rows on the main actor. The coordinator now runs each step on its row queue, so these are
/// plain synchronous functions that touch only what they are given. Ownership decisions (is this still the
/// current attempt?) stay with the coordinator, which makes them on the main actor between the two steps.
public enum PodcastDownloadAdoption {
    /// Checks the staged file and moves it to `destination`, and returns its size in bytes.
    ///
    /// Refuses a download whose response was not 2xx, a missing or empty file, and a 200 that carried a sign-in
    /// page or an error message instead of audio (#919). The staged file is removed on every refusal and on a
    /// failed move, so nothing is left in the download folder; after a successful move it no longer exists.
    public static func adopt(
        stagedURL: URL?,
        responseOK: Bool,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> Int64 {
        guard let stagedURL else { throw CocoaError(.fileReadCorruptFile) }
        do {
            guard responseOK,
                  let size = try stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard !DownloadedAudioSniffer.looksLikeText(fileAt: stagedURL) else {
                throw PodcastDownloadFailure.notAudio
            }
            try fileManager.moveItem(at: stagedURL, to: destination)
            return Int64(size)
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
    }

    /// Saves the asset and then the download row, in that order, so availability is never published ahead of
    /// the asset it names. Throws if either save fails; the caller rolls the moved file back.
    public static func publish(
        asset: AudioAsset,
        record: PodcastDownloadRecord,
        in store: SQLiteSessionStore
    ) throws {
        try store.saveAudioAsset(asset)
        try store.savePodcastDownload(record)
    }
}
