import Foundation

/// What a PDF's Paper note section on the item screen shows (#4340 PR 4): the citation line, then the slots Purpose, Key
/// findings and three Evidence, each empty or filled by a Margin that carries that role, and the Margins "Choose a
/// Margin" offers. Pure rules over plain values, so host tests check the citation fallbacks and the slot order; the
/// section only draws it.
///
/// A role answered twice shows both answers under the role name, in page order (the order the Paper notes table uses).
/// Evidence always shows three rows, empty ones after the filled; a fourth and later piece adds a row, and once three are
/// filled the section offers "Add more evidence".
public struct PaperNoteSlots: Equatable, Sendable {
    /// One of the listener's own Margins on the paper, with the page it sits on when the paper's structure says.
    public struct Answer: Equatable, Sendable, Identifiable {
        public var margin: Interjection
        /// One-based page, or nil when the paper has no structure or the page isn't certain.
        public var page: Int?

        public var id: String { "\(margin.sessionId)::\(margin.id)" }

        /// "p. 7", or the item screen's usual "At 40%" / "No place" when the page isn't known.
        public var placeLine: String {
            if let page { return "p. \(page)" }
            return MarginPlacePresentation.itemScreenLine(for: margin)
        }
    }

    public enum Row: Equatable, Sendable, Identifiable {
        /// `index` tells the empty Evidence rows apart; it is 0 for Purpose and Key findings.
        case empty(PaperNoteRole, index: Int)
        case filled(Answer)

        public var id: String {
            switch self {
            case .empty(let role, let index): "empty.\(role.rawValue).\(index)"
            case .filled(let answer): "filled.\(answer.id)"
            }
        }

        public var role: PaperNoteRole {
            switch self {
            case .empty(let role, _): role
            case .filled(let answer): answer.margin.paperRole ?? .evidence
            }
        }
    }

    /// The paper as the section reads it. `margins` are the listener's own Margins on any item; only this paper's
    /// active, item-level ones count. Friends' Margins are another type and never passed in.
    public struct Paper: Sendable {
        public var itemId: String
        public var title: String
        public var author: String?
        public var bibliography: PDFBibliography?
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

    public static let evidenceRows = 3

    public var citation: String
    public var rows: [Row]
    /// Shown once three Evidence rows are filled.
    public var offersMoreEvidence: Bool
    /// The listener's own Margins on this paper, in page order, for "Choose a Margin". Empty hides that choice.
    public var choices: [Answer]

    public init(paper: Paper) {
        let own = paper.margins
            .filter { PaperNoteOrder.isOwnOnPaper($0, itemId: paper.itemId) }
            .map { Answer(margin: $0, page: paper.document?.pageNumber(atCharacter: $0.anchor.startChar)) }
            .sorted { PaperNoteOrder.precedes(
                .init(page: $0.page, startChar: $0.margin.anchor.startChar, createdAt: $0.margin.createdAt, id: $0.margin.id),
                .init(page: $1.page, startChar: $1.margin.anchor.startChar, createdAt: $1.margin.createdAt, id: $1.margin.id)
            ) }
        choices = own
        func answers(_ role: PaperNoteRole) -> [Answer] { own.filter { $0.margin.paperRole == role } }

        var rows: [Row] = []
        for role in [PaperNoteRole.purpose, .keyFinding] {
            let filled = answers(role)
            rows += filled.isEmpty ? [.empty(role, index: 0)] : filled.map(Row.filled)
        }
        let evidence = answers(.evidence)
        rows += evidence.map(Row.filled)
        rows += (evidence.count..<max(evidence.count, Self.evidenceRows)).map { Row.empty(.evidence, index: $0) }
        self.rows = rows
        offersMoreEvidence = evidence.count >= Self.evidenceRows
        citation = Self.citation(title: paper.title, author: paper.author, bibliography: paper.bibliography)
    }

    /// No answer and no Margin to choose: the section shows its questions and the footnote that says how to begin.
    public var hasNoMargins: Bool { choices.isEmpty }

    // MARK: Words

    public static let heading = "Paper note"
    public static let subheading = "Purpose, findings and evidence, each tied to its page"
    /// The footnote while the paper has no Margin of the listener's own to choose (PR 5 brings Write it and its own wording).
    public static let noMarginsFootnote = "Make a Margin while you listen, then choose it here."
    public static let addMoreEvidence = "Add more evidence"

    /// The slot's name on the item screen: "Purpose", "Key findings", "Evidence".
    public static func slotName(_ role: PaperNoteRole) -> String {
        switch role {
        case .purpose: "Purpose"
        case .keyFinding: "Key findings"
        case .evidence: "Evidence"
        }
    }

    /// The role's name for one Margin, on its details screen and in Choose a Margin: "Purpose", "Key finding", "Evidence".
    public static func roleName(_ role: PaperNoteRole) -> String {
        switch role {
        case .purpose: "Purpose"
        case .keyFinding: "Key finding"
        case .evidence: "Evidence"
        }
    }

    public static func question(_ role: PaperNoteRole) -> String {
        switch role {
        case .purpose: "What is this paper trying to find out or show?"
        case .keyFinding: "What did it find?"
        case .evidence: "What supports a finding? Mention where it is."
        }
    }

    /// "Choose a Margin for Purpose".
    public static func chooseTitle(_ role: PaperNoteRole) -> String { "Choose a Margin for \(slotName(role))" }

    /// The citation line. With a DOI or arXiv id: "Smith, Jones · 2021 · doi:10.1234/abcd" (two authors, then "et al.",
    /// each part left out when unknown; the item's author when the bibliography has none). Without one: "<title> · <author>",
    /// both the item's, or the title alone.
    public static func citation(title: String, author: String?, bibliography: PDFBibliography?) -> String {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let authors = (bibliography?.authors ?? []).compactMap(clean)
        let identifier = clean(bibliography?.doi).map { "doi:" + $0 } ?? clean(bibliography?.arxivId).map { "arXiv:" + $0 }
        let cleanTitle = clean(title) ?? clean(bibliography?.title) ?? "Untitled"
        let byline = authors.isEmpty ? clean(author) : authors.prefix(2).joined(separator: ", ") + (authors.count > 2 ? " et al." : "")
        // The Design: without an identifier the line is the item's own title and author, as the Library shows them.
        guard let identifier else { return [cleanTitle, clean(author)].compactMap { $0 }.joined(separator: " · ") }
        return [byline, bibliography?.year.map(String.init), identifier].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The one rule for which Margins answer a paper and in what order, shared by the Paper note section and the table.
enum PaperNoteOrder {
    struct Key {
        var page: Int?
        var startChar: Int
        var createdAt: Date
        var id: String
    }

    /// The listener's own, active, item-level Margin on this paper.
    static func isOwnOnPaper(_ margin: Interjection, itemId: String) -> Bool {
        margin.itemId == itemId && margin.targetType == .item && margin.status == "active"
    }

    /// Page order: known pages first and ascending, then by place in the text, then oldest first, then id.
    static func precedes(_ lhs: Key, _ rhs: Key) -> Bool {
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
