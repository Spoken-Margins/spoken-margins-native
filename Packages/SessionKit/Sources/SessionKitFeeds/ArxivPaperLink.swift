import Foundation

/// #5049: an arXiv abstract link (`arxiv.org/abs/1706.03762`) is a web page with no audio, so the Link field
/// spent about 41 s and then said it found no playable file, while the paper's own PDF link added at once. This
/// maps the abstract link to that PDF link. It reads the text only: no request is made.
public enum ArxivPaperLink {
    /// Longest link read; anything longer is not an arXiv abstract link.
    static let maxLength = 2_048

    private static let hosts: Set<String> = ["arxiv.org", "www.arxiv.org", "export.arxiv.org"]

    /// The PDF link for an arXiv abstract link (`/abs/<id>`, the id with or without a `vN` version), or `nil`
    /// for anything else: a PDF link, `list/`, `html/`, another host, an `/abs/` path that is not an arXiv id.
    /// Scheme (`http` or `https`), `www.` or `export.`, a trailing slash, a query and a fragment don't matter.
    public static func pdfURL(forAbstract text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength, let url = URL(string: trimmed) else { return nil }
        return pdfURL(forAbstract: url)
    }

    public static func pdfURL(forAbstract url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 80 || url.port == 443,
              let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0] == "abs" else { return nil }
        let identifier = parts.dropFirst().joined(separator: "/")
        guard isIdentifier(identifier) else { return nil }
        return URL(string: "https://arxiv.org/pdf/\(identifier)")
    }

    /// The link to open: the PDF link for an abstract link, the link itself otherwise.
    public static func openingURL(for url: URL) -> URL { pdfURL(forAbstract: url) ?? url }

    /// `2301.01234` or `1706.03762v7` (four digit year-month, four or five digit number), or the old style
    /// `hep-th/9901001` and `math.GT/0309136v2`, each with an optional version.
    static func isIdentifier(_ text: String) -> Bool {
        text.range(of: #"^(\d{4}\.\d{4,5}|[a-z]+(-[a-z]+)*(\.[A-Z]{2})?/\d{7})(v\d+)?$"#, options: .regularExpression) != nil
    }
}
