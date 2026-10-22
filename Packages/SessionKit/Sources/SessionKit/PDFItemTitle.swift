import Foundation

/// #2062: which title an imported PDF gets.
///
/// An arXiv paper with a bookmark outline was titled "1 Introduction": the printed title keeps no
/// heading level when the PDF has an outline, so the first level-1 heading was the first outline
/// entry. The printed title now wins over an outline heading, and a metadata title that is only a
/// file name or a word processor's default is not a title.
public enum PDFItemTitle {
    /// The metadata title when it says something, else the printed title (given only for a PDF
    /// that has an outline), else the first level-1 heading.
    public static func choose(metadata: String?, printedTitle: String?, firstHeading: String?) -> String? {
        if let metadata = tidy(metadata), !isPlaceholder(metadata) { return metadata }
        return tidy(printedTitle) ?? tidy(firstHeading)
    }

    /// "Microsoft Word - report.docx", "Untitled", "report.pdf", "paper.tex": what an authoring
    /// tool leaves behind when nobody typed a title.
    public static func isPlaceholder(_ title: String) -> Bool {
        let text = tidy(title)?.lowercased() ?? ""
        if text.isEmpty { return true }
        if text.range(of: #"^(?:untitled|untitled document|title|document|no title|\(anonymous\)|anonymous)\s*\d*$"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"^microsoft (?:word|powerpoint|excel|publisher)\s*-\s*"#, options: .regularExpression) != nil {
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
