import Foundation
import SessionKit
import WebKit

enum ReadablePageExtractionError: Error, LocalizedError, Equatable {
    case invalidURL
    case oversizedHTML
    case tooManyRedirects
    case missingExtractor
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Article URLs must use HTTPS."
        case .oversizedHTML: "The article exceeds the 1 MB safety limit."
        case .tooManyRedirects: "The article redirected more than five times."
        case .missingExtractor: "The bundled readable-page extractor is unavailable."
        case .invalidResult: "No readable article text was found."
        }
    }
}

/// Loads an article in an ephemeral WebKit data store. Remote scripts and
/// subresources are blocked; only the app-bundled, pinned Defuddle capture
/// script executes after the top-level document finishes loading.
@MainActor
final class AppOwnedReadablePageExtractor: NSObject, WKNavigationDelegate {
    private static let maximumHTMLBytes: Int64 = 1 * 1_024 * 1_024
    private static let maximumRedirects = 5
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<BrowserTextHandoff, Error>?
    private var redirectCount = 0
    private var requestedURL: URL?
    private(set) var contactedHosts: [String] = []

    func extract(url: URL) async throws -> BrowserTextHandoff {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw ReadablePageExtractionError.invalidURL
        }
        guard continuation == nil else { throw ReadablePageExtractionError.invalidResult }
        let script = try extractorScript()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        let rules = """
        [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","raw","svg-document","popup"]},"action":{"type":"block"}}]
        """
        guard let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "spoken-margins-readable-page.v1",
            encodedContentRuleList: rules
        ) else { throw ReadablePageExtractionError.missingExtractor }
        configuration.userContentController.add(ruleList)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        redirectCount = 0
        requestedURL = url
        contactedHosts = [url.host!.lowercased()]
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame,
           navigationResponse.response.expectedContentLength > Self.maximumHTMLBytes {
            finish(.failure(ReadablePageExtractionError.oversizedHTML))
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            finish(.failure(ReadablePageExtractionError.invalidURL))
            return .cancel
        }
        if !contactedHosts.contains(host) { contactedHosts.append(host) }
        if navigationAction.navigationType == .other, url != requestedURL {
            redirectCount += 1
            requestedURL = url
            if redirectCount > Self.maximumRedirects {
                finish(.failure(ReadablePageExtractionError.tooManyRedirects))
                return .cancel
            }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let payload = try await capturePayload(in: webView)
                finish(.success(try Self.handoff(from: payload)))
            } catch {
                finish(.failure(ReadablePageExtractionError.invalidResult))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func extractorScript() throws -> String {
        guard let url = Bundle.main.url(forResource: "browserTextCapture", withExtension: "js") else {
            throw ReadablePageExtractionError.missingExtractor
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func capturePayload(in webView: WKWebView) async throws -> [String: Any] {
        do {
            let result = try await webView.callAsyncJavaScript(
                "return globalThis.SpokenMarginsBrowserTextCapture.captureReadablePage(document);",
                arguments: [:],
                in: nil,
                contentWorld: .defaultClient
            )
            guard let payload = result as? [String: Any] else {
                throw ReadablePageExtractionError.invalidResult
            }
            return payload
        } catch {
            let result = try await webView.callAsyncJavaScript(
                Self.semanticFallbackJavaScript,
                arguments: [:],
                in: nil,
                contentWorld: .defaultClient
            )
            guard let payload = result as? [String: Any] else {
                throw ReadablePageExtractionError.invalidResult
            }
            return payload
        }
    }

    static func handoff(from payload: [String: Any]) throws -> BrowserTextHandoff {
        guard let text = payload["text"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximumHTMLBytes,
              let source = payload["source"] as? [String: Any],
              let url = source["url"] as? String,
              let title = source["title"] as? String else {
            throw ReadablePageExtractionError.invalidResult
        }
        return BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(
                url: url,
                title: title,
                author: source["author"] as? String,
                publishedAt: source["publishedAt"] as? String
            ),
            text: text,
            contentFormat: .markdown,
            requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
        )
    }

    private static let semanticFallbackJavaScript = #"""
    const root = document.querySelector("article") || document.querySelector("main") || document.body;
    if (!root) { return null; }
    const normalize = value => String(value || "").replace(/\s+/g, " ").trim();
    const blocks = Array.from(root.querySelectorAll("h1,h2,h3,h4,h5,h6,p,li,blockquote,pre"));
    const text = blocks.map(element => {
        const value = normalize(element.innerText || element.textContent);
        if (!value) { return ""; }
        const tag = element.tagName.toLowerCase();
        if (/^h[1-6]$/.test(tag)) { return `${"#".repeat(Number(tag.slice(1)))} ${value}`; }
        if (tag === "li") { return `- ${value}`; }
        if (tag === "blockquote") { return `> ${value}`; }
        return value;
    }).filter(Boolean).join("\n\n") || normalize(root.innerText || root.textContent);
    if (!text) { return null; }
    const metadata = selector => document.querySelector(selector)?.getAttribute("content") || null;
    return {
        text,
        source: {
            url: document.location.href,
            title: normalize(metadata("meta[property='og:title']") || document.title || "Browser Text"),
            author: normalize(metadata("meta[name='author']")) || null,
            publishedAt: metadata("meta[property='article:published_time']") || null
        }
    };
    """#

    private func finish(_ result: Result<BrowserTextHandoff, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }
}
