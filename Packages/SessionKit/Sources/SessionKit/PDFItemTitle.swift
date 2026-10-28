import Foundation

/// #2062: which title an imported PDF gets.
///
/// An arXiv paper with a bookmark outline was titled "1 Introduction": the printed title keeps no
/// heading level when the PDF has an outline, so the first level-1 heading was the first outline
/// entry. The printed title now wins over an outline heading, and a metadata title that is only a
/// file name or a word processor's default is not a title.
///
/// #2807: an outlined PDF with no "Abstract" or "Summary" line has no printed-title block, so its
/// first bookmark ("Story 1") won over a page 1 that reads "Collected Stories / Edited by … /
/// Contents". `displayTitle(onPageOne:bodySize:)` reads that title from page 1's type.
public enum PDFItemTitle {
    /// One line of page 1, in reading order, with the size its type is set in.
    public struct PageLine: Equatable, Sendable {
        public var text: String
        public var pointSize: Double

        public init(text: String, pointSize: Double) {
            self.text = text
            self.pointSize = pointSize
        }
    }

    /// The metadata title when it says something, else the printed title (given only for a PDF
    /// that has an outline), else the first level-1 heading.
    public static func choose(metadata: String?, printedTitle: String?, firstHeading: String?) -> String? {
        if let metadata = tidy(metadata), !isPlaceholder(metadata) { return metadata }
        return tidy(printedTitle) ?? tidy(firstHeading)
    }

    /// The same, given every title block on page 1 in reading order. A block that reads as a sentence is passed
    /// over when another block follows it: arXiv 1706.03762 sets Google's permission notice ("Provided proper
    /// attribution is provided, Google hereby grants permission to reproduce the tables and figures in this paper
    /// solely for use in journalistic or") in display type above the title, so it is a title block too.
    public static func choose(metadata: String?, printedTitles: [String], firstHeading: String?) -> String? {
        let blocks = printedTitles.compactMap(tidy)
        let printed = blocks.dropLast().first { !readsAsSentence($0) } ?? blocks.last
        return choose(metadata: metadata, printedTitle: printed, firstHeading: firstHeading)
    }

    /// The title page 1 prints in its largest display type: the first run of lines at the largest size
    /// that is at least 1.5 pt over the body text. A contents or front-matter label ("Contents",
    /// "Preface") is not a title, a subtitle or editor line in smaller type is left out, and a run that
    /// reads as a sentence (a notice set in display type) is not a title. Nil when page 1 sets nothing
    /// in display type.
    public static func displayTitle(onPageOne lines: [PageLine], bodySize: Double) -> String? {
        func isCandidate(_ line: PageLine) -> Bool {
            guard line.pointSize >= bodySize + 1.5, let text = tidy(line.text), text.count >= 2,
                  text.contains(where: \.isLetter), !isStructuralLabel(text), !isFrontMatterLine(text) else { return false }
            return true
        }
        let candidates = lines.indices.filter { isCandidate(lines[$0]) }
        guard let titleSize = candidates.map({ lines[$0].pointSize }).max(),
              let first = candidates.first(where: { abs(lines[$0].pointSize - titleSize) < 0.3 }) else { return nil }
        var run: [String] = []
        var index = first
        while index < lines.count, isCandidate(lines[index]), abs(lines[index].pointSize - titleSize) < 0.3 {
            run.append(lines[index].text)
            index += 1
        }
        guard let title = tidy(run.joined(separator: " ")), !readsAsSentence(title) else { return nil }
        return title
    }

    /// "Edited by …", "Translated by …", "© 2026 …", an ISBN, DOI or address: the credit and imprint lines under or
    /// beside a title, not part of it.
    static func isFrontMatterLine(_ text: String) -> Bool {
        text.range(
            of: #"^(?:(?:edited|translated|illustrated|compiled|foreword|introduction|photographs|published|printed) by\b|copyright\b|©|\(c\)|isbn\b|doi:|https?://|all rights reserved)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// "Contents", "Table of Contents", "1 Introduction", "Preface", "Part II", "Chapter 3": a part of a book or paper, not its name.
    static func isStructuralLabel(_ text: String) -> Bool {
        text.range(
            of: #"^(?:(?:[0-9]+|[ivxlcdm]+)[.)]?\s+)?(?:table of contents|contents|preface|foreword|introduction|prologue|epigraph|dedication|acknowledg(?:e)?ments?|copyright|about the authors?|abstract|summary|(?:chapter|part|volume|book|section) (?:[0-9]+|[ivxlcdm]+))\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Twelve or more words, two in three starting lower case, ending with a full stop or broken off mid-sentence
    /// ("… for use in journalistic or"): a notice, not a title. A long title in sentence case ends on a word or a
    /// question mark, and only a block with another after it is passed over.
    static func readsAsSentence(_ text: String) -> Bool {
        let words = text.split(separator: " ").filter { $0.first?.isLetter == true }
        guard words.count >= 12, words.filter({ $0.first?.isLowercase == true }).count * 3 >= words.count * 2 else { return false }
        return text.hasSuffix(".") || text.range(
            of: #"\s(?:and|or|but|nor|the|a|an|of|to|in|for|with|by|on|at|as|from|that|which|is|are|be)$"#,
            options: .regularExpression
        ) != nil
    }

    /// "Microsoft Word - report.docx", "Untitled", "report.pdf", "paper.tex": what an authoring
    /// tool leaves behind when nobody typed a title.
    public static func isPlaceholder(_ title: String) -> Bool {
        let text = tidy(title)?.lowercased() ?? ""
        if text.isEmpty { return true }
        if text.range(of: #"^(?:untitled|untitled document|title|document|no title|\(anonymous\)|anonymous|powerpoint presentation|slide)(?:\s*-?\s*\d+)?$"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"^microsoft (?:word|powerpoint|excel|publisher)\s*[-–—]\s*"#, options: .regularExpression) != nil {
            return true
        }
        return text.range(of: #"^\S+\.(?:docx?|pptx?|xlsx?|pdf|tex|dvi|rtf|odt|indd|qxd|txt|pages|key)$"#, options: .regularExpression) != nil
    }

    private static func tidy(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}
