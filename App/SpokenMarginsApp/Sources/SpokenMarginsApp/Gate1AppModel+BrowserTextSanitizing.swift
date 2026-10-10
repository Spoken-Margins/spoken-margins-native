import Foundation
import SessionKit

/// Cleaning HTML out of captured page text before import. Moved out of Gate1AppModel unchanged,
/// so the model's hot file has room for #810's call sites.
extension Gate1AppModel {
    static func sanitizedBrowserTextHandoff(_ handoff: BrowserTextHandoff) -> BrowserTextHandoff {
        guard handoff.captureMode == .readablePage,
              handoff.text.range(of: #"<[^>]+>"#, options: .regularExpression) != nil else {
            return handoff
        }
        var sanitized = handoff
        sanitized.text = handoff.contentFormat == .markdown
            ? stripEmbeddedHTMLPreservingMarkdown(handoff.text)
            : stripHTML(handoff.text)
        sanitized.text = sanitized.text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized
    }

    private static func stripEmbeddedHTMLPreservingMarkdown(_ markdown: String) -> String {
        var result = markdown
            .replacingOccurrences(
                of: #"<\s*(script|style|video|audio|figure|svg|iframe|canvas|noscript)\b[^>]*>[\s\S]*?<\s*/\s*\1\s*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<\s*(source|img)\b[^>]*>"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )

        for level in 1...6 {
            result = result
                .replacingOccurrences(
                    of: #"<\s*h\#(level)\b[^>]*>"#,
                    with: "\n\(String(repeating: "#", count: level)) ",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: #"<\s*/\s*h\#(level)\s*>"#,
                    with: "\n",
                    options: [.regularExpression, .caseInsensitive]
                )
        }

        return result
            .replacingOccurrences(
                of: #"</?(p|div|section|article|li|br)\b[^>]*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    static func stripHTML(_ html: String) -> String {
        HTMLTextStripping.stripHTML(html)
    }
}
