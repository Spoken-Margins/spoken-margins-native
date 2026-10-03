import Foundation
import UniformTypeIdentifiers

/// What Paste & go reads from the clipboard (#145). `PasteAndGoBar`'s button offers to paste only while the
/// clipboard holds one of `supportedTypes`, and hands the items to `text(from:)`.
@MainActor
enum PastedClipboardContent {
    static let supportedTypes: [UTType] = [.plainText]

    /// The first item's text.
    static func text(from providers: [NSItemProvider]) async -> String? {
        for provider in providers {
            if let text = await loadText(from: provider) { return text }
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
}
