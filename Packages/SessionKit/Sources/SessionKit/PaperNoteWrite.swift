import Foundation

/// What the Paper note's Write sheet needs to place and word an answer (#4340 PR 5 of the Design): the paper, its
/// structure for pages, and the listening session "Where you are" reads. Pure values, so host tests cover every place
/// line and every refusal; the sheet draws it and saves through `SessionEngine.addWrittenInterjection`.
public struct PaperNoteWriteContext: Sendable {
    public let item: Item
    public let document: StructuredDocument?
    /// The session Continue would resume (`PaperNotePlace.session`), which the answer is written to. Nil when the paper
    /// was never started: Write it is then off (Default 6 of the Design).
    public let session: Session?

    public init(item: Item, document: StructuredDocument?, sessions: [Session], addedAgainAt: Date?) {
        self.item = item
        self.document = document
        session = PaperNotePlace.session(addedAgainAt: addedAgainAt, sessions: sessions.filter { $0.itemId == item.id })
    }

    /// Write it is on: there is a session to write to and text to place the answer in.
    public var canWrite: Bool { session != nil && !(item.text ?? "").isEmpty }

    /// The places the Change menu offers, in its order. "Where you are" is left out when the session's saved place is
    /// not in the paper (a generated answer or summary was playing), so the sheet never offers a place it can't use.
    public var choices: [PaperNotePlace.Choice] {
        guard canWrite else { return [] }
        var choices: [PaperNotePlace.Choice] = []
        if (try? character(for: .whereYouAre)) != nil { choices.append(.whereYouAre) }
        choices.append(.startOfPaper)
        if pageCount != nil { choices.append(.startOfPage(1)) }
        return choices
    }

    /// The place each new prompt starts at: "Where you are" when it can be used, otherwise the start of the paper.
    public var defaultChoice: PaperNotePlace.Choice {
        choices.contains(.whereYouAre) ? .whereYouAre : .startOfPaper
    }

    /// The PDF's page count for "Start of a page…", or nil when the paper has no structure to find a page in.
    public var pageCount: Int? {
        guard let count = document?.extraction.pageCount, count > 0 else { return nil }
        return count
    }

    /// The character the answer starts at, by `PaperNotePlace.resolve`.
    public func character(for choice: PaperNotePlace.Choice) throws -> Int {
        try PaperNotePlace.resolve(item: item, document: document, session: session, choice: choice)
    }

    /// The one-based page `choice` lands on, when the structure says.
    public func page(for choice: PaperNotePlace.Choice) -> Int? {
        if case .startOfPage(let page) = choice { return page }
        guard let character = try? character(for: choice) else { return nil }
        return document?.pageNumber(atCharacter: character)
    }

    // MARK: Words

    /// The sheet's place line: "At p. 7, where you are", "At the start of the paper", "At the start of p. 3".
    public func placeLine(_ choice: PaperNotePlace.Choice) -> String {
        switch choice {
        case .whereYouAre: page(for: choice).map { "At p. \($0), where you are" } ?? "Where you are"
        case .startOfPaper: "At the start of the paper"
        case .startOfPage(let page): "At the start of p. \(page)"
        }
    }

    /// The Change menu's entry for `choice`: "Where you are (p. 7)", "Start of the paper", "Start of a page…".
    public func menuTitle(_ choice: PaperNotePlace.Choice) -> String {
        switch choice {
        case .whereYouAre: page(for: choice).map { "Where you are (p. \($0))" } ?? "Where you are"
        case .startOfPaper: "Start of the paper"
        case .startOfPage: "Start of a page…"
        }
    }

    public static let placeholder = "Type, or tap the microphone on the keyboard to speak."
    public static let saveFailed = "Couldn't save this answer. Try again."
    public static let placeFailed = "That place isn't in this paper. Choose another."
    public static let discardTitle = "Discard this answer?"
    public static let discard = "Discard"
    public static let keepWriting = "Keep writing"
    public static let pagePickerTitle = "Start of a page"

    /// "Purpose saved." after a Save.
    public static func savedLine(_ role: PaperNoteRole) -> String { "\(PaperNoteSlots.slotName(role)) saved." }
}

/// The order the Write sheet asks in (#4340): the slot whose Add was tapped first, then the other empty slots in the
/// section's order (Purpose, Key findings, Evidence). After each Save the sheet moves to the next; with none left it
/// closes. "Add more evidence" opens it with no empty slot left, so it asks for that one Evidence only.
public struct PaperNoteWritePrompts: Equatable, Sendable {
    public private(set) var remaining: [PaperNoteRole]

    public init(start: PaperNoteRole, slots: PaperNoteSlots) {
        var empty = slots.rows.compactMap { row -> PaperNoteRole? in
            if case .empty(let role, _) = row { return role }
            return nil
        }
        if let index = empty.firstIndex(of: start) { empty.remove(at: index) }
        remaining = [start] + empty
    }

    /// "Change answer" › Write it: that one role, then the sheet closes.
    public init(only role: PaperNoteRole) {
        remaining = [role]
    }

    /// The role being asked for now; nil once every prompt is answered.
    public var current: PaperNoteRole? { remaining.first }

    /// Moves past the current prompt after its answer saved.
    public mutating func advance() {
        if !remaining.isEmpty { remaining.removeFirst() }
    }
}
