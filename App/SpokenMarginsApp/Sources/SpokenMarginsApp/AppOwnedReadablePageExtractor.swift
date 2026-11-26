import Foundation
import SessionKit
import WebKit

enum ReadablePageExtractionError: Error, LocalizedError, Equatable {
    case invalidURL
    /// The page moved to an address that isn't HTTPS while it loaded (#144).
    case pageLeftHTTPS
    /// The page sent the reader to another app's address, such as X's `x-safari-https://` (#4776).
    case handedToAnotherApp
    case oversizedHTML
    case tooManyRedirects
    case missingExtractor
    case invalidResult
    case busy
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Article URLs must use HTTPS."
        case .pageLeftHTTPS: "The article page moved to an address that isn't secure (HTTPS)."
        case .handedToAnotherApp: "The site tried to open the page in another app instead of showing it here."
        case .oversizedHTML: "The article exceeds the 1 MB safety limit."
        case .tooManyRedirects: "The article redirected more than five times."
        case .missingExtractor: "The bundled readable-page extractor is unavailable."
        case .invalidResult: "No readable article text was found."
        case .busy: "Another article is being read. Try again in a moment."
        case .httpStatus(let status): "The site answered with HTTP \(status) instead of the article."
        }
    }
}

/// Loads an article in an ephemeral WebKit data store. Remote scripts and
/// subresources are blocked; only the app-bundled, pinned Defuddle capture
/// script executes after the top-level document finishes loading.
@MainActor
final class AppOwnedReadablePageExtractor: NSObject, WKNavigationDelegate, ReadablePageExtracting {
    private static let maximumHTMLBytes: Int64 = 1 * 1_024 * 1_024
    /// A shared ChatGPT page is already over half that before the chat: the site's own session data comes first (#874).
    private static let maximumSharedChatHTMLBytes: Int64 = 8 * 1_024 * 1_024
    /// WebKit content rules for an ordinary page: block its images, styles, scripts, fonts, media, fetches and
    /// popups, so the reader gets the page's HTML without running or downloading anything else.
    static let readablePageContentRules = """
    [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","raw","svg-document","popup"]},"action":{"type":"block"}}]
    """
    private var webView: WKWebView?
    private var requestedURL: URL?
    private var continuation: CheckedContinuation<BrowserTextHandoff, Error>?
    private var navigationRules: ReadablePageNavigationRules?
    var contactedHosts: [String] { navigationRules?.contactedHosts ?? [] }
    private(set) var lastExtractor: String?
    private let queue = ReadablePageQueue()
    /// Counts pages stopped by the time limit, so a stopped page still compiling its rules gives up.
    private var stoppedPages = 0

    /// One web view reads one page at a time. A page asked for while another loads (a shared link while the
    /// listener adds an article) waits its turn, and a page still loading after the queue's time limit is
    /// stopped (#579).
    func extract(url: URL) async throws -> BrowserTextHandoff {
        try await queue.read({ [self] in
            try await load(url: url)
        }, stop: { [weak self] in
            self?.stoppedPages += 1
            self?.finish(.failure(ReadablePageTimeout(limit: ReadablePageQueue.defaultTimeLimit)))
        })
    }

    private func load(url: URL) async throws -> BrowserTextHandoff {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw ReadablePageExtractionError.invalidURL
        }
        guard continuation == nil else { throw ReadablePageExtractionError.busy }
        let stoppedBefore = stoppedPages
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let rules: String
        let ruleListIdentifier: String
        if ClaudeSharedPage.matches(url) {
            // A shared Claude page fetches its chat with its own scripts, so this is the one page that runs
            // its own code. The rules let it reach only its own host and asset hosts; the only script added is
            // the one that keeps a copy of the chat it fetched (#876).
            configuration.userContentController.addUserScript(WKUserScript(
                source: ClaudeSharedPage.snapshotHookScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
            rules = ClaudeSharedPage.contentRules
            ruleListIdentifier = "spoken-margins-claude-share.v1"
        } else {
            configuration.userContentController.addUserScript(WKUserScript(
                source: try await extractorScript(),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .defaultClient
            ))
            rules = Self.readablePageContentRules
            ruleListIdentifier = "spoken-margins-readable-page.v1"
        }
        guard let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: ruleListIdentifier,
            encodedContentRuleList: rules
        ) else { throw ReadablePageExtractionError.missingExtractor }
        guard stoppedPages == stoppedBefore else {
            throw ReadablePageTimeout(limit: ReadablePageQueue.defaultTimeLimit)
        }
        configuration.userContentController.add(ruleList)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        // A site that bounces the web view's own iPhone identity to Safari gets Mac Safari's instead (#4776).
        if let userAgent = ReadablePageBrowserIdentity.userAgent(for: url) {
            webView.customUserAgent = userAgent
        }
        self.webView = webView
        navigationRules = ReadablePageNavigationRules(requestedURL: url)
        requestedURL = url
        lastExtractor = nil
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        let limit = requestedURL.map(ChatGPTSharedPage.matches) == true
            ? Self.maximumSharedChatHTMLBytes : Self.maximumHTMLBytes
        if navigationResponse.isForMainFrame,
           navigationResponse.response.expectedContentLength > limit {
            finish(.failure(ReadablePageExtractionError.oversizedHTML))
            return .cancel
        }
        // A sign-in wall, bot check or missing page still renders text, which would be read as the article (#145).
        if navigationResponse.isForMainFrame, let status = Self.failingHTTPStatus(navigationResponse.response) {
            finish(.failure(ReadablePageExtractionError.httpStatus(status)))
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard var rules = navigationRules else { return .cancel }
        let decision = rules.decide(
            url: navigationAction.request.url,
            targetIsMainFrame: navigationAction.targetFrame?.isMainFrame,
            isRedirect: navigationAction.navigationType == .other
        )
        navigationRules = rules
        switch decision {
        case .load:
            return .allow
        case .skipFrame:
            return .cancel
        case .refuse(.pageLeftHTTPS):
            finish(.failure(ReadablePageExtractionError.pageLeftHTTPS))
            return .cancel
        case .refuse(.handedToAnotherApp):
            finish(.failure(ReadablePageExtractionError.handedToAnotherApp))
            return .cancel
        case .refuse(.tooManyRedirects):
            finish(.failure(ReadablePageExtractionError.tooManyRedirects))
            return .cancel
        }
    }

    nonisolated static func failingHTTPStatus(_ response: URLResponse) -> Int? {
        guard let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 else { return nil }
        return status
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // A shared ChatGPT page draws its chat with scripts, so the page reader would see only the title.
            // The chat is in the page's data instead. If it isn't, say so rather than import a few words (#874).
            if let url = requestedURL, ClaudeSharedPage.matches(url) {
                let shared: Result<BrowserTextHandoff, Error>
                do { shared = .success(try await sharedClaudeHandoff(in: webView, url: url)) } catch { shared = .failure(error) }
                guard self.webView === webView else { return }
                if case .success = shared { lastExtractor = "claude_shared_page" }
                finish(shared)
                return
            }
            if let url = requestedURL, ChatGPTSharedPage.matches(url) {
                let shared: Result<BrowserTextHandoff, Error>
                do { shared = .success(try await sharedChatHandoff(in: webView, url: url)) } catch { shared = .failure(error) }
                guard self.webView === webView else { return }
                if case .success = shared { lastExtractor = "chatgpt_shared_page" }
                finish(shared)
                return
            }
            let outcome: Result<[String: Any], Error>
            do { outcome = .success(try await capturePayload(in: webView)) } catch { outcome = .failure(error) }
            // A page stopped by the time limit must not answer the next page's request (#579).
            guard self.webView === webView else { return }
            do {
                let payload = try outcome.get()
                lastExtractor = (payload["metadata"] as? [String: Any])?["extractor"] as? String
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

    /// The bundled script is about 750 KB and never changes while the app runs: read it once, off the main actor,
    /// and keep it (#2508). Every page after the first adds it from memory.
    private static var cachedExtractorScript: String?

    private func extractorScript() async throws -> String {
        if let cached = Self.cachedExtractorScript { return cached }
        let script = try await Task.detached(priority: .userInitiated) { try Self.readExtractorScript() }.value
        Self.cachedExtractorScript = script
        return script
    }

    nonisolated private static func readExtractorScript() throws -> String {
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

    /// The page's scripts are still fetching the chat when the page finishes loading. Wait for the copy the
    /// capture script keeps. A page that was loading fine answers within seconds (3 on a Mac); one stuck behind
    /// a bot check never does, so stop waiting well before the queue's time limit.
    private func sharedClaudeHandoff(in webView: WKWebView, url: URL) async throws -> BrowserTextHandoff {
        let deadline = ContinuousClock.now + .seconds(20)
        while self.webView === webView {
            guard ContinuousClock.now < deadline else { throw ClaudeSharedPage.ParseError.noSnapshot }
            let result = try await webView.callAsyncJavaScript(
                ClaudeSharedPage.snapshotReadScript, arguments: [:], in: nil, contentWorld: .page
            )
            if let snapshot = result as? String { return try ClaudeSharedPage.handoff(fromSnapshot: snapshot, url: url) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw CancellationError()
    }

    private func sharedChatHandoff(in webView: WKWebView, url: URL) async throws -> BrowserTextHandoff {
        let result = try await webView.callAsyncJavaScript(
            Self.sharedChatScriptsJavaScript, arguments: [:], in: nil, contentWorld: .defaultClient
        )
        guard let payload = result as? [String: Any], let scripts = payload["scripts"] as? String else {
            throw ChatGPTSharedPage.ParseError.noPageData
        }
        return try ChatGPTSharedPage.handoff(fromPageSource: scripts, url: url, pageTitle: payload["title"] as? String)
    }

    /// The page's inline scripts that carry its data. They sit in the document whether or not they ran.
    private static let sharedChatScriptsJavaScript = #"""
    return {
        title: document.title,
        scripts: Array.from(document.scripts)
            .map(script => script.textContent || "")
            .filter(text => text.includes("streamController.enqueue"))
            .join("\n")
    };
    """#

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
    const selector = "h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,table";
    // A table becomes a Markdown table, so speech announces it once and never
    // reads a cell's paragraph as a sentence (#5364). Spans fill a grid; the
    // first row is the header. Same rules as tableToMarkdown in
    // Tools/BrowserExtraction/browserExtractionCore.mjs.
    const breaks = new Set(["td", "th", "tr", "p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"]);
    const words = (node, parts) => {
        if (node.nodeType === 3) { parts.push(node.nodeValue); return; }
        const tag = String(node.tagName || "").toLowerCase();
        if (tag === "script" || tag === "style") { return; }
        if (breaks.has(tag)) { parts.push(" "); }
        Array.from(node.childNodes || []).forEach(child => words(child, parts));
        if (breaks.has(tag)) { parts.push(" "); }
    };
    const span = (cell, name) => {
        const value = Number.parseInt(String(cell.getAttribute(name) ?? "").trim(), 10);
        return Number.isFinite(value) && value >= 1 ? Math.min(value, 1000) : 1;
    };
    const tableMarkdown = table => {
        const tableRows = Array.from(table.querySelectorAll("tr")).filter(row => row.closest("table") === table);
        const grid = [];
        tableRows.forEach((row, rowIndex) => {
            grid[rowIndex] ??= [];
            let column = 0;
            for (const cell of Array.from(row.children)) {
                const tag = String(cell.tagName || "").toLowerCase();
                if (tag !== "td" && tag !== "th") { continue; }
                while (grid[rowIndex][column] !== undefined) { column += 1; }
                const parts = [];
                Array.from(cell.childNodes || []).forEach(child => words(child, parts));
                const value = normalize(parts.join("")).replace(/\|/g, "\\|");
                const columns = span(cell, "colspan");
                const rows = Math.min(span(cell, "rowspan"), tableRows.length - rowIndex);
                for (let down = 0; down < rows; down += 1) {
                    grid[rowIndex + down] ??= [];
                    for (let across = 0; across < columns; across += 1) { grid[rowIndex + down][column + across] = value; }
                }
                column += columns;
            }
        });
        const rows = grid.filter(row => row && row.some(cell => cell));
        const width = Math.max(0, ...rows.map(row => row.length));
        if (!rows.length || width === 0) { return ""; }
        const caption = Array.from(table.children).find(child => String(child.tagName || "").toLowerCase() === "caption");
        const captionParts = [];
        if (caption) { Array.from(caption.childNodes || []).forEach(child => words(child, captionParts)); }
        const captionText = normalize(captionParts.join(""));
        const line = row => `| ${Array.from({ length: width }, (_, index) => row[index] ?? "").join(" | ")} |`;
        const markdown = [line(rows[0]), `| ${Array(width).fill("---").join(" | ")} |`, ...rows.slice(1).map(line)].join("\n");
        return captionText ? `${captionText}\n\n${markdown}` : markdown;
    };
    // A container's text already includes its descendants. Consume each DOM
    // passage once, without deleting intentional repetitions in sibling blocks.
    // A layout table (a nested table, or no row with two cells) is no block:
    // its headings and paragraphs are, as Defuddle flattens it (#5364 audit).
    const isDataTable = table => !table.querySelector("table") && Array.from(table.querySelectorAll("tr"))
        .some(row => Array.from(row.children).filter(cell => /^(td|th)$/i.test(String(cell.tagName || ""))).length >= 2);
    const dataTables = new Map();
    const isBlock = element => {
        if (element.tagName.toLowerCase() !== "table") { return true; }
        if (!dataTables.has(element)) { dataTables.set(element, isDataTable(element)); }
        return dataTables.get(element);
    };
    const insideBlock = element => {
        for (let parent = element.parentElement; parent; parent = parent.parentElement) {
            if (parent.matches(selector) && isBlock(parent)) { return true; }
        }
        return false;
    };
    const blocks = Array.from(root.querySelectorAll(selector))
        .filter(element => isBlock(element) && !insideBlock(element));
    const text = blocks.map(element => {
        const tag = element.tagName.toLowerCase();
        if (tag === "table") { return tableMarkdown(element); }
        const value = normalize(element.innerText || element.textContent);
        if (!value) { return ""; }
        if (/^h[1-6]$/.test(tag)) { return `${"#".repeat(Number(tag.slice(1)))} ${value}`; }
        if (tag === "li") { return `- ${value}`; }
        if (tag === "blockquote") { return `> ${value}`; }
        return value;
    }).filter(Boolean).join("\n\n") || normalize(root.innerText || root.textContent);
    if (!text) { return null; }
    const metadata = selector => document.querySelector(selector)?.getAttribute("content") || null;
    return {
        text,
        metadata: { extractor: "native_semantic_dom_fallback" },
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
