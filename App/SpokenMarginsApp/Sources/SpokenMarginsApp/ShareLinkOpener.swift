import Foundation
import SessionKit

/// Opens a tapped share link (#488): downloads and unseals the packet, then hands the file to the usual
/// import review. The key in the link never leaves the phone and is never logged.
@MainActor
final class ShareLinkOpener {
    /// Tests swap in a stub transport.
    var downloader: ShareLinkPacketDownloader
    private var task: Task<Void, Never>?

    init(downloader: ShareLinkPacketDownloader = .live) {
        self.downloader = downloader
    }

    /// Starts opening `link`. A second link while the first is still downloading replaces it.
    /// `stage` receives the unsealed packet file, which is removed once it returns.
    func open(
        _ link: ShareLinkURL,
        stage: @escaping @MainActor (URL) -> Void,
        fail: @escaping @MainActor (String) -> Void
    ) {
        task?.cancel()
        let downloader = downloader
        task = Task { @MainActor in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShareLink-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let file = try await downloader.download(link, into: directory)
                try Task.checkCancellation()
                stage(file)
            } catch is CancellationError {
                return
            } catch let failure as ShareLinkPacketDownloader.Failure {
                fail(failure.message)
            } catch {
                guard !Task.isCancelled else { return }
                fail(ShareLinkPacketDownloader.Failure.expiredOrUnreachable.message)
            }
        }
    }
}
