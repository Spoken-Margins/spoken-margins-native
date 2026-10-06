import Foundation

/// Reads a shared Claude chat (#876). A page like `https://claude.ai/share/<id>` is an empty shell until its own
/// scripts fetch the chat from `/api/chat_snapshots/<id>`, so the page reader has to let that page run. What
/// it runs, and who it may talk to, is fixed here: the page's own host and its two asset hosts, nothing else
/// (no analytics), with no stored data. The reader keeps the snapshot the page fetched, as structured data,
/// instead of scraping the drawn page.
public enum ClaudeSharedPage {
    public enum ParseError: Error, LocalizedError, Equatable {
        case noSnapshot
        case noResponse

        public var errorDescription: String? {
            switch self {
            case .noSnapshot:
                "Claude's shared page did not deliver the chat. Open the link in Safari to check that it still works."
            case .noResponse:
                "This shared Claude chat has no text to read."
            }
        }
    }

    /// A page whose URL looks like a Claude share link: `/share/<id>`.
    public static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host == "claude.ai" || host == "www.claude.ai" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count >= 2 && parts[0] == "share"
    }

    /// WebKit content rules for the web view that reads a share page: block everything, allow the three hosts
    /// the page needs, then block its event logging. (`if-domain` names the page's domain, not the resource's,
    /// and WebKit's pattern language has no alternation, so each host gets its own rule.)
    public static let contentRules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^https://claude\\\\.ai/"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^https://assets-proxy\\\\.anthropic\\\\.com/"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^https://s-cdn\\\\.anthropic\\\\.com/"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^https://claude\\\\.ai/api/event_logging"},"action":{"type":"block"}}]
    """

    /// Runs in the page before its own scripts (the page's JavaScript world) and keeps a copy of the snapshot
    /// response in `window.__smSnapshot`.
    public static let snapshotHookScript = #"""
    (function () {
        const realFetch = window.fetch;
        window.fetch = async function (...args) {
            const response = await realFetch.apply(this, args);
            try {
                const address = typeof args[0] === "string" ? args[0] : (args[0] && args[0].url) || "";
                if (response.ok && address.includes("/api/chat_snapshots/")) {
                    response.clone().text().then(function (text) { window.__smSnapshot = text; });
                }
            } catch (error) {}
            return response;
        };
    })();
    """#

    public static let snapshotReadScript = "return window.__smSnapshot || null;"

    /// The shared chat as an article to import.
    public static func handoff(fromSnapshot json: String, url: URL) throws -> BrowserTextHandoff {
        guard let snapshot = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let rawMessages = snapshot["chat_messages"] as? [[String: Any]] else { throw ParseError.noSnapshot }
        let sharer = nonEmpty(snapshot["created_by"] as? String) ?? nonEmpty((snapshot["creator"] as? [String: Any])?["full_name"] as? String)
        let ordered = rawMessages.enumerated().sorted {
            (($0.element["index"] as? Int) ?? $0.offset, $0.offset) < (($1.element["index"] as? Int) ?? $1.offset, $1.offset)
        }.map(\.element)
        let turns: [(speaker: String, text: String)] = ordered.compactMap { message in
            guard let sender = message["sender"] as? String, sender == "human" || sender == "assistant" else { return nil }
            let text = messageText(message)
            return text.isEmpty ? nil : (sender, text)
        }
        guard !turns.isEmpty else { throw ParseError.noResponse }
        let text: String
        if Set(turns.map(\.speaker)).count > 1 {
            text = turns.map { ($0.speaker == "human" ? (sharer ?? "User") : "Claude") + ": " + $0.text }.joined(separator: "\n\n")
        } else {
            text = turns.map(\.text).joined(separator: "\n\n")
        }
        return BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(
                url: url.absoluteString,
                title: nonEmpty(snapshot["snapshot_name"] as? String) ?? fallbackTitle(for: text),
                author: "Claude",
                publishedAt: snapshot["created_at"] as? String
            ),
            text: text,
            contentFormat: .markdown,
            requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
        )
    }

    /// The message's written words. Images, thinking and tool calls are not text to listen to.
    private static func messageText(_ message: [String: Any]) -> String {
        if let blocks = message["content"] as? [[String: Any]], !blocks.isEmpty {
            return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        return (message["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func fallbackTitle(for text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let plain = firstLine.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        guard !plain.isEmpty else { return "Claude chat" }
        return plain.count > 80 ? String(plain.prefix(80)) + "…" : plain
    }
}
