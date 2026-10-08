import Foundation

/// Item titles for browser imports whose page title is not really a title (#885).
///
/// Safari gives an X or Twitter post the page title `Name on X: "the whole post…"`, and that became
/// the item's title: several lines tall on the Item page and cut off in the listening bar. The post
/// stays in the item's text, so the title only has to say whose post it is.
public enum BrowserTextTitle {
    private static let postSites = ["X", "Twitter"]
    private static let postHosts = ["x.com", "twitter.com"]
    private static let openingQuotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}"]

    /// `Name on X` for a post page titled `Name on X: "post text…"`, or nil for any other page or title.
    ///
    /// A page counts as a post page when its host is x.com or twitter.com (or a subdomain such as
    /// `mobile.twitter.com`) and its title has the form `<name> on X: "` or `<name> on Twitter: "`,
    /// with a straight or curly opening quote. Whatever follows the quote, including the closing
    /// quote, a trailing ` / X` and a t.co link, is dropped. Profile pages (`Name (@handle) / X`) and
    /// titles without the quoted text are left alone.
    public static func postTitle(pageTitle: String, url: String) -> String? {
        guard isPostHost(url) else { return nil }
        let title = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var earliest: (end: String.Index, title: String)?
        for site in postSites {
            let marker = " on \(site): "
            var searchFrom = title.startIndex
            while let range = title.range(of: marker, range: searchFrom..<title.endIndex) {
                let name = title[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, let next = title[range.upperBound...].first, openingQuotes.contains(next) {
                    if earliest.map({ range.lowerBound < $0.end }) ?? true {
                        earliest = (range.lowerBound, "\(name) on \(site)")
                    }
                    break
                }
                searchFrom = range.upperBound
            }
        }
        return earliest?.title
    }

    private static func isPostHost(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return postHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}
