import Foundation

/// What the "PDF with your Margins" sheet shows and offers, as a value (#4338, PR 5).
///
/// The sheet lists the listener's own Margins in page order, each with where its comment will land, lets them leave
/// some out, and says what the button will do. None of that needs PDFKit, so it is decided here and host-tested; the
/// app gives it the plan (`MarginCommentPlan`) and, once PDFKit has placed the comments, where each one went.
public struct PDFCommentExportState: Equatable, Sendable {
    /// Where one comment landed, reduced to what the sheet says. `PDFMarginPlacement` (SessionKitPDF) is the full answer.
    public enum Spot: Equatable, Sendable {
        /// On the sentence (or the start of it) on this zero-based page.
        case sentence(page: Int)
        /// No exact place: a note at the top of this zero-based page.
        case pageNote(page: Int)
    }

    public enum RowStatus: Equatable, Sendable {
        case onItsSentence
        /// `page` is the zero-based page; the words say it one-based.
        case pageNoExactSpot(page: Int)
        case transcriptPending
        case noTranscript

        /// Whether the listener can choose to send this Margin at all. A Margin with no words is left out.
        public var canBeIncluded: Bool {
            switch self {
            case .onItsSentence, .pageNoExactSpot: return true
            case .transcriptPending, .noTranscript: return false
            }
        }

        /// The row's second line. Always words and an icon, never colour alone.
        public var words: String {
            switch self {
            case .onItsSentence: return "On its sentence"
            case .pageNoExactSpot(let page): return "On page \(page + 1), no exact spot"
            case .transcriptPending: return "Left out: transcript not ready yet"
            case .noTranscript: return "Left out: no transcript"
            }
        }

        /// An SF Symbol name for the status.
        public var systemImage: String {
            switch self {
            case .onItsSentence: return "text.quote"
            case .pageNoExactSpot: return "doc"
            case .transcriptPending: return "hourglass"
            case .noTranscript: return "exclamationmark.bubble"
            }
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        /// "p. 4", or nil when no page is known.
        public var pageLabel: String?
        /// The words the comment will carry. A Margin with none shows "Spoken Margin".
        public var text: String
        public var status: RowStatus
        public var isIncluded: Bool
    }

    public enum Phase: Equatable, Sendable {
        /// Finding where each Margin goes (placement runs off the main thread).
        case loading
        case ready
        /// The copy is being made. Rows are locked and a second tap does nothing.
        case exporting
        /// The copy could not be made; the Margins and the PDF are unchanged.
        case writeFailed
        /// The file takes no comments (a password, or its owner turned comments off).
        case locked
        /// The kept file or the item's text could not be read, so no comment can be placed.
        case unreadable
    }

    public private(set) var rows: [Row]
    public private(set) var phase: Phase
    /// The name each comment carries, as typed. Use `authorForComments` for what is written.
    public var authorName: String

    /// The longest name a comment carries.
    public static let authorNameLimit = 80

    /// - Parameters:
    ///   - plan: the listener's own Margins, in text order.
    ///   - spots: where each Margin of the plan was placed, by Margin id, or nil while placement is still running.
    ///   - authorName: the name last used on comments, or empty.
    public init(plan: MarginCommentPlan, spots: [String: Spot]?, authorName: String = "") {
        self.authorName = authorName
        self.phase = spots == nil ? .loading : .ready
        let built: [(page: Int?, row: Row)] = plan.entries.map { entry in
            let status: RowStatus
            let page: Int?
            switch entry.status {
            case .transcriptPending:
                status = .transcriptPending
                page = entry.pageIndex
            case .noTranscript:
                status = .noTranscript
                page = entry.pageIndex
            case .included:
                switch spots?[entry.marginId] {
                case .sentence(let found)?:
                    status = .onItsSentence
                    page = found
                case .pageNote(let found)?:
                    status = .pageNoExactSpot(page: found)
                    page = found
                case nil:
                    // Still placing (or this Margin could not be placed at all): the page the plan hinted at.
                    let hint = entry.pageIndex ?? 0
                    status = .pageNoExactSpot(page: hint)
                    page = entry.pageIndex
                }
            }
            let words = entry.commentText.trimmingCharacters(in: .whitespacesAndNewlines)
            let row = Row(
                id: entry.marginId,
                pageLabel: page.map { "p. \($0 + 1)" },
                text: words.isEmpty ? "Spoken Margin" : words,
                status: status,
                isIncluded: status.canBeIncluded
            )
            return (page, row)
        }
        // By the page each comment lands on, then the plan's order (the text order), so a comment found on the page before
        // its hint still reads in page order. A row with no page known goes last.
        self.rows = built.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.page ?? Int.max, rhs.element.page ?? Int.max)
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element.row)
    }

    // MARK: - What the sheet reads

    public var includedIds: [String] { rows.filter(\.isIncluded).map(\.id) }
    public var includedCount: Int { rows.filter(\.isIncluded).count }
    public var canExport: Bool { phase == .ready && includedCount > 0 }
    /// Rows can be toggled and the name edited only while the sheet is waiting for the listener.
    public var isEditable: Bool { phase == .ready }

    /// The pinned button's words.
    public var buttonTitle: String {
        if phase == .exporting { return "Placing comments…" }
        switch includedCount {
        case 0: return "Nothing to export"
        case 1: return "Export 1 comment"
        default: return "Export \(includedCount) comments"
        }
    }

    /// The name written on each comment: trimmed, one line, at most `authorNameLimit` characters. Empty means no author.
    public var authorForComments: String { Self.normalizedAuthor(authorName) }

    public static func normalizedAuthor(_ name: String) -> String {
        let oneLine = name.split(whereSeparator: \.isNewline).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(authorNameLimit)).trimmingCharacters(in: .whitespaces)
    }

    public static func leadLine(title: String) -> String {
        "Makes a copy of “\(title)” with each of your Margins as a comment on its sentence. The original stays as it is."
    }

    public static let footnote = "Only your own Margins are included. Spoken Margins go as their words; the recording stays on your iPhone."

    /// The banner after the share sheet reports the file was sent.
    public static func doneMessage(count: Int) -> String {
        count == 1 ? "Exported 1 comment." : "Exported \(count) comments."
    }

    public static let writeFailedMessage = "Couldn't make the copy. Your Margins and the PDF are unchanged."
    public static let lockedMessage = "This PDF is locked, so comments can't be added to it."
    public static let unreadableMessage = "Couldn't read this PDF. Your Margins and the PDF are unchanged."

    // MARK: - What the listener does

    /// Includes or leaves out one Margin. A Margin with no words cannot be included, and nothing changes while the
    /// sheet is loading, exporting or showing a refusal.
    public mutating func toggle(_ id: String) {
        guard isEditable, let index = rows.firstIndex(where: { $0.id == id }), rows[index].status.canBeIncluded else { return }
        rows[index].isIncluded.toggle()
    }

    /// Starts an export. False (and no change) when one is running already or there is nothing to send, so a second tap
    /// starts nothing.
    public mutating func beginExport() -> Bool {
        guard canExport else { return false }
        phase = .exporting
        return true
    }

    /// Goes back to waiting for the listener: the share sheet was cancelled, or the copy failed (`failed`).
    public mutating func endExport(failed: Bool) {
        guard phase == .exporting else { return }
        phase = failed ? .writeFailed : .ready
    }

    /// "Try again" after a failure: back to the full list.
    public mutating func dismissFailure() {
        if phase == .writeFailed { phase = .ready }
    }

    /// The file takes no comments.
    public mutating func markLocked() {
        phase = .locked
    }

    /// The file or the item's text could not be read.
    public mutating func markUnreadable() {
        phase = .unreadable
    }
}

/// The name of the exported copy: `<title> (with Margins).pdf` (#4338, PR 5).
public enum PDFCommentExportFileName {
    public static let suffix = " (with Margins)"
    public static let titleLimit = 120

    /// `title` with slashes, colons and control characters made spaces, runs of white space made one, trimmed and capped
    /// at `titleLimit` characters. An empty result reads "PDF".
    public static func make(title: String) -> String {
        var cleaned = ""
        for scalar in title.unicodeScalars {
            let bad = scalar == "/" || scalar == "\\" || scalar == ":" || scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format || scalar.properties.isWhitespace
            cleaned.unicodeScalars.append(bad ? " " : scalar)
        }
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        var name = String(collapsed.prefix(titleLimit)).trimmingCharacters(in: .whitespaces)
        // A leading dot would hide the file.
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "PDF" }
        return name + suffix + ".pdf"
    }
}
