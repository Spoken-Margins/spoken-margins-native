import Foundation

/// One table of a listener's Paper notes: a row per paper, filled from the Margins that carry a `PaperNoteRole`
/// (#4340). Pure rules over plain values, so host tests check every cell and both file formats; no screen uses it yet.
///
/// Columns: Title, Authors, Year, DOI or arXiv, Purpose, Purpose page, Key findings, Key findings page, Evidence 1 to 3
/// with a page each, and More evidence. A role answered twice joins its answers with " / " in page order (pages the
/// same way, for the answers that have one). More evidence holds the fourth and later pieces, each as "text (p. N)".
/// Rows run by each paper's newest answer, newest first.
public struct PaperNoteTable: Equatable, Sendable {
    /// A paper and the listener's own Margins on it, as plain values the caller reads from the Library. Friends'
    /// Margins are another type and are never passed in.
    public struct Paper: Sendable {
        public var itemId: String
        public var title: String
        /// The item's own author line, used when the paper has no bibliography authors.
        public var author: String?
        public var bibliography: PDFBibliography?
        /// Gives each answer its page; without it the page cells stay empty.
        public var document: StructuredDocument?
        public var margins: [Interjection]

        public init(itemId: String, title: String, author: String? = nil, bibliography: PDFBibliography? = nil, document: StructuredDocument? = nil, margins: [Interjection]) {
            self.itemId = itemId
            self.title = title
            self.author = author
            self.bibliography = bibliography
            self.document = document
            self.margins = margins
        }
    }

    public static let columns = [
        "Title", "Authors", "Year", "DOI or arXiv",
        "Purpose", "Purpose page", "Key findings", "Key findings page",
        "Evidence 1", "Evidence 1 page", "Evidence 2", "Evidence 2 page", "Evidence 3", "Evidence 3 page",
        "More evidence",
    ]

    /// The cells of each row, in `columns` order.
    public var rows: [[String]]

    /// `scope` is the Margins tab's scope: the ids of the items in it, or nil for the whole Library. A paper with no
    /// answer in scope has no row.
    public init(papers: [Paper], scope: Set<String>? = nil) {
        let built = papers
            .filter { scope?.contains($0.itemId) ?? true }
            .compactMap(Self.row(for:))
            .sorted { lhs, rhs in
                if lhs.newest != rhs.newest { return lhs.newest > rhs.newest }
                return (lhs.cells[0], lhs.itemId) < (rhs.cells[0], rhs.itemId)
            }
        rows = built.map(\.cells)
    }

    public var isEmpty: Bool { rows.isEmpty }

    // MARK: Files

    /// A Markdown table. Backslashes and pipes are escaped and line breaks become `<br>`, so a cell never ends its row.
    /// Escaping runs over unicode scalars: a Foundation string replace skips a match followed by a combining mark.
    public func markdown() -> String {
        func cell(_ value: String) -> String {
            var result = String.UnicodeScalarView()
            var scalars = Array(value.unicodeScalars)[...]
            while let scalar = scalars.popFirst() {
                switch scalar {
                case "\\": result.append(contentsOf: "\\\\".unicodeScalars)
                case "|": result.append(contentsOf: "\\|".unicodeScalars)
                case "\r":
                    if scalars.first == "\n" { scalars.removeFirst() }
                    result.append(contentsOf: "<br>".unicodeScalars)
                case "\n", "\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}": result.append(contentsOf: "<br>".unicodeScalars)
                default: result.append(scalar)
                }
            }
            return String(result)
        }
        func line(_ cells: [String]) -> String { "| " + cells.map(cell).joined(separator: " | ") + " |" }
        return ([line(Self.columns), "|" + String(repeating: " --- |", count: Self.columns.count)] + rows.map(line)).joined(separator: "\n") + "\n"
    }

    /// RFC 4180 CSV with CRLF line ends. A cell that would open as a formula in a spreadsheet (starting, after any spaces,
    /// with `=`, `+`, `-` or `@`, or starting with a tab or a carriage return) gets an apostrophe in front.
    public func csv() -> String {
        func cell(_ value: String) -> String {
            let scalars = value.unicodeScalars
            let first = scalars.first(where: { $0 != " " })
            let formula = first.map { "=+-@".unicodeScalars.contains($0) } == true || scalars.first == "\t" || scalars.first == "\r"
            let guarded = formula ? "'" + value : value
            // Scalars, not Characters or a Foundation replace: "\r\n" is one Character, and a replace skips a match that a combining mark follows.
            guard guarded.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else { return guarded }
            var quoted = String.UnicodeScalarView()
            quoted.append("\"")
            for scalar in guarded.unicodeScalars {
                if scalar == "\"" { quoted.append("\"") }
                quoted.append(scalar)
            }
            quoted.append("\"")
            return String(quoted)
        }
        return ([Self.columns] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// The CSV as the file holds it: UTF-8 with a byte order mark, so Excel reads accents and emoji.
    public func csvData() -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(csv().utf8)
    }

    // MARK: Rows

    private struct Answer {
        var text: String
        var page: Int?
        var startChar: Int
        var createdAt: Date
        var id: String
    }

    private static func row(for paper: Paper) -> (cells: [String], newest: Date, itemId: String)? {
        var byRole: [PaperNoteRole: [Answer]] = [:]
        var newest: Date?
        for margin in paper.margins where margin.itemId == paper.itemId && margin.targetType == .item && margin.status == "active" {
            guard let role = margin.paperRole else { continue }
            let text = (margin.displayText ?? margin.cleanedTranscript ?? margin.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            byRole[role, default: []].append(Answer(
                text: text, page: paper.document?.pageNumber(atCharacter: margin.anchor.startChar),
                startChar: margin.anchor.startChar, createdAt: margin.createdAt, id: margin.id
            ))
            newest = max(newest ?? margin.createdAt, margin.createdAt)
        }
        guard let newest else { return nil }
        func answers(_ role: PaperNoteRole) -> [Answer] {
            (byRole[role] ?? []).sorted { lhs, rhs in
                switch (lhs.page, rhs.page) {
                case let (left?, right?) where left != right: return left < right
                case (nil, .some): return false
                case (.some, nil): return true
                default: break
                }
                if lhs.startChar != rhs.startChar { return lhs.startChar < rhs.startChar }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
        }
        func joined(_ answers: [Answer]) -> (String, String) {
            (answers.map(\.text).joined(separator: " / "), answers.compactMap(\.page).map(String.init).joined(separator: " / "))
        }
        let bibliography = paper.bibliography
        let authors = bibliography.map { $0.authors.joined(separator: ", ") }.flatMap { $0.isEmpty ? nil : $0 } ?? paper.author ?? ""
        let identifier = bibliography?.doi.flatMap { $0.isEmpty ? nil : $0 } ?? bibliography?.arxivId.flatMap { $0.isEmpty ? nil : "arXiv:" + $0 } ?? ""
        let (purpose, purposePage) = joined(answers(.purpose))
        let (findings, findingsPage) = joined(answers(.keyFinding))
        let evidence = answers(.evidence)
        var cells = [paper.title, authors, bibliography?.year.map(String.init) ?? "", identifier, purpose, purposePage, findings, findingsPage]
        for index in 0..<3 {
            cells += index < evidence.count ? [evidence[index].text, evidence[index].page.map(String.init) ?? ""] : ["", ""]
        }
        cells.append(evidence.dropFirst(3).map { answer in answer.page.map { "\(answer.text) (p. \($0))" } ?? answer.text }.joined(separator: " / "))
        return (cells, newest, paper.itemId)
    }
}
