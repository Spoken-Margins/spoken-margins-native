import Foundation

/// Cleans HTML out of a captured readable page before import.
///
/// Captured page text is prose, and prose holds bare comparisons: "p < 0.001", "x<y". A catch-all `<[^>]+>`
/// ran from such a "<" to the next tag's ">", often pages later: on a long paper it took two whole runs of
/// sections, about half the article (#5417, the same class as the speech normalizer's #3813). Every pattern
/// here needs a tag name right after the "<", and a quoted attribute may hold "<" or ">", so a comparison keeps
/// its words and only real markup goes.
public enum BrowserTextHandoffSanitizer {
    public static func sanitized(_ handoff: BrowserTextHandoff) -> BrowserTextHandoff {
        guard handoff.captureMode == .readablePage,
              handoff.text.range(of: tag, options: .regularExpression) != nil else {
            return handoff
        }
        var sanitized = handoff
        sanitized.text = handoff.contentFormat == .markdown
            ? stripEmbeddedHTMLPreservingMarkdown(handoff.text)
            : stripMarkup(handoff.text)
        sanitized.text = sanitized.text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized
    }

    /// Attributes after a tag name: quoted values may hold anything but their own quote; outside quotes,
    /// no "<" or ">".
    private static let attributes = #"(?:"[^"]*"|'[^']*'|[^"'<>])*"#

    /// Any real tag, comment, CDATA section, declaration or processing instruction. Unlike the speech
    /// normalizer's `MarkupTag.pattern` it takes valueless attributes (`<details open>`, `<td nowrap>`), which the
    /// old catch-all removed too; a match still ends before the next "<", so it never crosses other markup.
    static let tag = #"(?s)<!--.*?-->|<!\[CDATA\[.*?\]\]>|<![A-Za-z][^<>]*>|<\?[A-Za-z][^<>]*\?>|</?[A-Za-z][-A-Za-z0-9:_]*(?=[\s/>])"# + attributes + ">"

    static func stripEmbeddedHTMLPreservingMarkdown(_ markdown: String) -> String {
        var result = markdown
            .replacingOccurrences(
                of: #"<(script|style|video|audio|figure|svg|iframe|canvas|noscript)\b"# + attributes + #">[\s\S]*?<\s*/\s*\1\s*>"#,
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"<(?:source|img)\b"# + attributes + ">",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )

        for level in 1...6 {
            result = result
                .replacingOccurrences(
                    of: #"<h\#(level)\b"# + attributes + ">",
                    with: "\n\(String(repeating: "#", count: level)) ",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: #"</h\#(level)\s*>"#,
                    with: "\n",
                    options: [.regularExpression, .caseInsensitive]
                )
        }

        result = result.replacingOccurrences(
            of: #"</?(?:p|div|section|article|li|br)\b"# + attributes + ">",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        return result.replacingOccurrences(of: tag, with: " ", options: .regularExpression)
    }

    /// Plain captured text (`innerText`) holds the page's "<" as written, so it gets the same tag-name rule.
    static func stripMarkup(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"<(script|style|video)\b"# + attributes + #">[\s\S]*?</\1\s*>"#,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: #"<source\b"# + attributes + ">", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(
                of: #"</?(?:p|div|section|article|h[1-6]|li|br)\b"# + attributes + ">",
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: tag, with: " ", options: .regularExpression)
    }
}

/// Real markup only: a comment, a declaration, a processing instruction, or a tag whose name follows the "<"
/// directly, with attributes after it. Shared by import sanitizing and the speech normalizer (#3813, #5417).
enum MarkupTag {
    static let pattern = #"(?s)<!--.*?-->|<![A-Za-z][^<>]*>|<\?[A-Za-z][^<>]*\?>|</?[A-Za-z][-A-Za-z0-9:_]*(?:\s+[-A-Za-z0-9_:.@]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+)(?:\s+[-A-Za-z0-9_:.@]+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*)?\s*/?>"#
}
