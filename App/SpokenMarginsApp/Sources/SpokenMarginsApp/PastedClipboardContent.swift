import Foundation
import UniformTypeIdentifiers

/// What Paste & go reads from the clipboard (#145). `PasteAndGoBar`'s button offers to paste only while the
/// clipboard holds one of `supportedTypes`, and hands the items to `text(from:)`.
///
/// A link copied with "Copy Link" is a URL item, often with no plain-text copy. The button used to accept plain
/// text only, so it stayed disabled for such a link (the owner's FAIL on cb3d6c4).
@MainActor
enum PastedClipboardContent {
    static let supportedTypes: [UTType] = [.plainText, .url]

    /// The first item's text, or its link when it carries only a URL. Text wins when an item has both, so
    /// "Title https://…" copied from a share sheet reads as before.
    static func text(from providers: [NSItemProvider]) async -> String? {
        for provider in providers {
            if let text = await loadText(from: provider) { return text }
            if let link = await loadLink(from: provider) { return link }
        }
        return nil
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
                continuation.resume(returning: reading as? String)
            }
        }
    }

    private static func loadLink(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { reading, _ in
                continuation.resume(returning: (reading as? URL)?.absoluteString)
            }
        }
    }
}
