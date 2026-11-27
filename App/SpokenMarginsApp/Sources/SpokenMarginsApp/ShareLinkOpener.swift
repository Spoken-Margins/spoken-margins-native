import Foundation
import SessionKit

/// Opens a tapped share link (#488): downloads and unseals the packet, then hands the file to the usual
/// import review. The key in the link never leaves the phone and is never logged.
@MainActor
final class ShareLinkOpener {
    /// Tests swap in a stub transport.
    var downloader: ShareLinkPacketDownloader
    /// Where the friend's side of opened marks is kept (#5275). Tests swap in their own defaults.
    var signals = FriendLinkSignals()
    private var task: Task<Void, Never>?

    init(downloader: ShareLinkPacketDownloader = .live) {
        self.downloader = downloader
    }

    /// Stops an open that is still running; its failure or packet is then never reported.
    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Starts opening `link`. A second link while the first is still downloading replaces it.
    /// `stage` receives the unsealed packet file, which is removed once it finishes. `fail` gets what went wrong; the
    /// failure sheet's words and whether the same link is worth another try come from it (#3801).
    func open(
        _ link: ShareLinkURL,
        stage: @escaping @MainActor (URL) async -> Void,
        fail: @escaping @MainActor (ShareLinkPacketDownloader.Failure) -> Void
    ) {
        task?.cancel()
        let downloader = downloader
        let signals = signals
        task = Task { @MainActor in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShareLink-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let download = try await downloader.downloadOffering(link, into: directory)
                try Task.checkCancellation()
                // Whether this link's server keeps opened marks, and the token a start tap would send; nothing is sent here.
                if let token = ShareLinkOpenedToken.make(for: link) {
                    signals.recordArrival(id: link.id, token: token, offered: download.offersOpened, now: Date())
                }
                await stage(download.file)
            } catch is CancellationError {
                return
            } catch let failure as ShareLinkPacketDownloader.Failure {
                // A replaced link whose server answered before the cancel reached it says nothing.
                guard !Task.isCancelled else { return }
                fail(failure)
            } catch {
                guard !Task.isCancelled else { return }
                fail(.expiredOrUnreachable)
            }
        }
    }
}
