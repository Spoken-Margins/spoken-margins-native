import Foundation
import SessionKit

/// What the sender is told, and what diagnostics record, when a Margins packet can't be written (#2118).
///
/// The archive's own wording ("The package manifest is too large.") is for bug reports, not the listener, and on its
/// own it didn't say what filled the manifest. The diagnostic adds the counts that answer that.
public struct SharedPacketExportFailure: Equatable, Sendable {
    /// `lastSharedPackageFailure`: the error, then (once the packet was prepared) its descriptor counts, the longest
    /// identity link and the manifest's size before digests.
    public let diagnostic: String
    public let listenerMessage: String

    public init(error: Error, prepared: PreparedSpokenMarginsPackage?) {
        var diagnostic = String(describing: error)
        if let manifest = prepared?.manifest {
            let item = manifest.item
            let longestURL = [item.canonicalURL, item.originalURL, item.enclosureURL, item.source?.canonicalURL]
                .compactMap { $0?.count }.max() ?? 0
            let manifestBytes = (try? SpokenMarginsPackageArchive.encodeManifest(manifest).count).map(String.init) ?? "unknown"
            diagnostic += ";artifacts=\(manifest.artifacts.count);assets=\(manifest.assets.count)"
                + ";longestURL=\(longestURL);manifestBytes=\(manifestBytes)"
        }
        self.diagnostic = diagnostic
        listenerMessage = Self.listenerMessage(for: error)
    }

    static func listenerMessage(for error: Error) -> String {
        guard let error = error as? SpokenMarginsPackageArchiveError else { return error.localizedDescription }
        switch error {
        case .manifestTooLarge, .packageTooLarge, .audioTooLarge:
            return "These Margins don't fit in one file. Try sending fewer at a time."
        case .audioTooLong:
            return "A voice Margin is longer than 10 minutes. Send that one as text, or leave it out."
        default:
            return "These Margins couldn't be packed into a file. Try again, and if it keeps failing, send a bug report."
        }
    }
}
