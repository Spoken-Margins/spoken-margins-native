import Foundation

/// Reads a web page as an article. The app's implementation loads the page in a locked-down web view.
@MainActor
public protocol ReadablePageExtracting: AnyObject {
    /// Which extractor read the last page, for diagnostics.
    var lastExtractor: String? { get }
    /// The hosts the last extraction contacted.
    var contactedHosts: [String] { get }
    func extract(url: URL) async throws -> BrowserTextHandoff
}
