import Foundation

extension MarginMarkdownShare {
    /// "Export all Margins" (#1866): every item's Margins in one file, item by item in the order given, each item
    /// under its own heading and its Margins in source order. Nil when no Margin has a note.
    public static func file(forAllMargins marginsByItem: [[Interjection]], engine: SessionEngine) throws -> MarginMarkdownFile? {
        var sections: [String] = []
        for margins in marginsByItem {
            guard let file = try file(forItemMargins: margins, engine: engine) else { continue }
            sections.append(file.markdown)
        }
        guard !sections.isEmpty else { return nil }
        return MarginMarkdownFile(fileName: "Margins - All.md", markdown: sections.joined(separator: separator))
    }
}
