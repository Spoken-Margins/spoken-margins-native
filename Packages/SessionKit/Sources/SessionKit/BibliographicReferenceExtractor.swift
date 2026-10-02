import Foundation

/// Finds the identifier a reference manager matches a paper by (#206): the paper's own DOI or
/// arXiv id, from the text of its first two pages, plus the authors, year and title from the
/// PDF's metadata. Zotero matches on the DOI directly, so no citekey is guessed.
///
/// A DOI cited in the reference list is another paper's, so the text is cut at the first
/// "References" heading, and numbered reference entries before it ("[3] …") are skipped.
public enum BibliographicReferenceExtractor {
    /// Nil when the first pages carry neither a DOI nor an arXiv id: without one, the
    /// metadata alone can't be matched to a library entry, and the note stays as it was.
    public static func extract(
        pageTexts: [String],
        metadataTitle: String? = nil,
        metadataAuthor: String? = nil,
        metadataCreationDate: Date? = nil
    ) -> PDFBibliography? {
        let lines = frontMatterLines(pageTexts.prefix(2))
        let doi = lines.lazy.compactMap(firstDOI(in:)).first
        let arxivId = lines.lazy.compactMap(firstArXivId(in:)).first
        guard doi != nil || arxivId != nil else { return nil }
        return PDFBibliography(
            doi: doi,
            arxivId: arxivId,
            authors: authors(fromMetadata: metadataAuthor),
            year: metadataCreationDate.map(year(of:)),
            title: metadataTitle.map(collapsedWhitespace).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// The first pages' lines up to the reference list, without numbered reference entries.
    static func frontMatterLines<Pages: Sequence<String>>(_ pages: Pages) -> [String] {
        var kept: [String] = []
        for page in pages {
            for line in page.components(separatedBy: .newlines) {
                if line.range(of: referenceHeading, options: [.regularExpression, .caseInsensitive]) != nil { return kept }
                if line.range(of: numberedReferenceEntry, options: .regularExpression) != nil { continue }
                kept.append(line)
            }
        }
        return kept
    }

    /// "References", "7. References", "REFERENCES", "Notes and References", "Bibliography",
    /// "Works Cited" or "Endnotes" alone on a line.
    private static let referenceHeading =
        #"^\s*(?:[0-9IVX]{1,4}\.?\s+)?(?:references(?:\s+cited|\s+and\s+notes)?|notes\s+and\s+references|bibliography|works\s+cited|cited\s+works|literature\s+cited|reference\s+list|endnotes)\s*:?\s*$"#
    private static let numberedReferenceEntry = #"^\s*\[[0-9]{1,4}\]\s"#

    /// Crossref's DOI pattern (`10.` + registrant + `/` + suffix), with sentence punctuation
    /// and an unmatched closing bracket trimmed from the end.
    static func firstDOI(in text: String) -> String? {
        guard let range = text.range(of: #"\b10\.[0-9]{4,9}/[-._;()/:A-Za-z0-9]+"#, options: .regularExpression) else {
            return nil
        }
        var doi = String(text[range])
        while let last = doi.last {
            if ".,;:".contains(last) {
                doi.removeLast()
            } else if last == ")", doi.filter({ $0 == "(" }).count < doi.filter({ $0 == ")" }).count {
                doi.removeLast()
            } else {
                break
            }
        }
        return doi
    }

    /// `arXiv:2101.01234v2`, `arxiv.org/abs/2101.01234`, or an old-style `arXiv:hep-th/9901001`.
    /// The version is dropped: Zotero matches the id without it.
    static func firstArXivId(in text: String) -> String? {
        let patterns = [
            #"arxiv(?::\s?|\.org/(?:abs|pdf)/)([0-9]{4}\.[0-9]{4,5})(?:v[0-9]+)?"#,
            #"arxiv(?::\s?|\.org/(?:abs|pdf)/)([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?/[0-9]{7})(?:v[0-9]+)?"#,
        ]
        let matches = patterns.compactMap { pattern -> (String.Index, String)? in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let whole = Range(match.range, in: text),
                  let id = Range(match.range(at: 1), in: text) else { return nil }
            return (whole.lowerBound, String(text[id]))
        }
        return matches.min { $0.0 < $1.0 }?.1
    }

    /// PDF metadata puts every author in one string. Split on ";" or on ", " and " and ",
    /// unless that leaves a one-word part, which means the names are "Last, First".
    static func authors(fromMetadata metadata: String?) -> [String] {
        guard let metadata = metadata.map(collapsedWhitespace), !metadata.isEmpty else { return [] }
        let separator = metadata.contains(";") ? #"\s*;\s*"# : #"\s*,\s*and\s+|\s*,\s*|\s+and\s+|\s*&\s*"#
        let parts = metadata
            .replacingOccurrences(of: separator, with: "\u{1F}", options: .regularExpression)
            .components(separatedBy: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !metadata.contains(";"), parts.contains(where: { !$0.contains(" ") }) { return [metadata] }
        return parts
    }

    private static func year(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.year, from: date)
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension StructuredDocument {
    /// The 1-based page of the segment holding `character` (an `Anchor.startChar`): the last
    /// segment starting at or before it, so a gap between segments counts as the one before.
    ///
    /// A segment records only the page it starts on, and same-role lines on later pages join it
    /// when no page header or footer splits them. So the page is given only when the segment is
    /// known to end on the page it starts on: the next segment starts there too, or it is the
    /// last segment and that page is the document's last. Otherwise nil: no page beats a wrong one.
    public func pageNumber(atCharacter character: Int) -> Int? {
        let ordered = segments.sorted { $0.range.start < $1.range.start }
        guard let index = ordered.lastIndex(where: { $0.range.start <= character }),
              let page = ordered[index].pageIndex else { return nil }
        let endPage = index + 1 < ordered.count ? ordered[index + 1].pageIndex : extraction.pageCount - 1
        return endPage == page ? page + 1 : nil
    }
}
