import Foundation

/// Moves Margins that landed in a live session (usually an automatic Quick session) onto the Library item the listener
/// meant (#4233). Each moved Margin keeps its words, its recording (the same file) and its capture time. It gets a place
/// on the item only when the app saved one at capture (`LiveSessionPlayingThen`, or a player run still in memory) and the
/// item has a media clock that holds it; otherwise it is on the item with no place (`MovedMarginOrigin.placeKnown ==
/// false`) and never gets an invented one: not the item's resume point, not the live session's clock or page.
///
/// This type holds the rules and the item-side writes; the live session's own files are changed by
/// `LiveSessionFileWorker.removeMovedMargins` and put back by `restoreMovedMargins`. The order is: the item side in one
/// transaction (`execute`), then the live side. An app that dies between the two finishes on the next launch with
/// `LiveSessionFileWorker.reconcileMovedMargins`, so a Margin is never shown in both places.
///
/// The move never writes the item's `Session`: the item's resume point, percent, finished state and `updatedAt` stay as
/// they were, and so does a playing item's place.
public enum LiveMarginMove {
    /// The store a move reads and writes: Margins, sessions by item, and moved Margins' origins.
    public typealias Repository = SessionRepository & StructuredDocumentRepository

    // MARK: What can move (Design 2.4)

    /// Why a Margin can't move, or nil when it can.
    public enum Unmovable: Equatable, Sendable {
        /// The session was saved as a Library item: its Margins are on that item already. Nothing is shown.
        case savedSession
        /// An item Margin has nowhere to keep the photo.
        case hasPhoto
        /// A Mark has no words or recording to carry.
        case isMark

        /// The line shown in place of Move, or nil for a saved session, which shows nothing.
        public var reason: String? {
            switch self {
            case .savedSession: nil
            case .hasPhoto: "Margins with a page photo stay in the session."
            case .isMark: "A Mark has no words or recording to move."
            }
        }
    }

    public static func movability(margin: LiveSessionMargin, in session: LiveSession) -> Unmovable? {
        if session.savedItemId != nil { return .savedSession }
        if margin.photo != nil { return .hasPhoto }
        if !margin.isSpoken && margin.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .isMark }
        return nil
    }

    /// The Margins of `session` that can move, in the session's order.
    public static func movableMargins(in session: LiveSession) -> [LiveSessionMargin] {
        session.margins.filter { movability(margin: $0, in: session) == nil }
    }

    /// Whether the session offers Move at all (the finish card, the Margins pane): unsaved, with a Margin that can move.
    public static func offersMove(in session: LiveSession) -> Bool {
        !movableMargins(in: session).isEmpty
    }

    /// Whether moving `marginIds` out of `session` removes the session: it is a Quick session the listener never renamed,
    /// not saved, and nothing is left in it. `LiveSessionFiling.tidy` would remove it at the next filing pass anyway; the
    /// move does it now. A named or renamed session stays, emptied, so its title and description are kept.
    public static func removesSession(_ session: LiveSession, movingIds marginIds: Set<String>) -> Bool {
        session.isQuick == true && !session.isRenamedQuick && session.savedItemId == nil
            && session.margins.allSatisfy { marginIds.contains($0.id) }
    }

    // MARK: Where they go (Design 2.9.2)

    /// One Margin as it will be written.
    public struct PlannedMargin: Equatable, Sendable {
        public var margin: LiveSessionMargin
        /// The place on the item, or nil for a Margin that will be on the item with no place.
        public var positionMs: Int?
        /// What gave the place: `MovedMarginOrigin.placeSource`.
        public var placeSource: String?

        public var isPlaced: Bool { positionMs != nil }
    }

    /// A move worked out before it is confirmed: the dialog's counts come from the same check `execute` writes by.
    public struct Plan: Equatable, Sendable {
        /// The live session as it was when planned, kept for Undo's recreate.
        public var session: LiveSession
        public var itemId: String
        public var itemTitle: String
        /// The item-side session the Margins go into: `StoredSessionMargin.targetSession`.
        public var targetSessionId: String
        /// Whether the item's place is a media time (an episode) or a text place (an article, a PDF).
        public var itemHasMediaClock: Bool
        public var itemDurationMs: Int?
        public var margins: [PlannedMargin]
        /// Whether the move empties and removes the live session (`removesSession`).
        public var removesSession: Bool

        public var count: Int { margins.count }
        public var placedCount: Int { margins.filter(\.isPlaced).count }
        public var unplacedCount: Int { count - placedCount }
        public var liveMarginIds: Set<String> { Set(margins.map(\.margin.id)) }
    }

    public enum Failure: Error, Equatable {
        /// None of the chosen Margins can move (gone from the session, or unmovable).
        case nothingToMove
        case itemNotFound
        /// The item has no session to write on: the listener hasn't started it.
        case noSession
    }

    public static let placeSourceSavedRun = "savedRun"
    public static let placeSourceWatchTarget = "watchTarget"

    /// Works out where each of `margins` goes on `itemId`. Margins no longer in `session`, or that can't move, are left
    /// out; if none are left it throws `nothingToMove`. `runs` are the player's in-memory runs (`PlayerRunRecorder`).
    public static func plan(
        margins: [LiveSessionMargin], session: LiveSession, itemId: String,
        runs: [LiveSessionFiling.PlayerRun] = [], repository: Repository
    ) throws -> Plan {
        let present = Set(session.margins.map(\.id))
        let chosen = margins.filter { present.contains($0.id) && movability(margin: $0, in: session) == nil }
            .sorted { ($0.markedAt, $0.id) < ($1.markedAt, $1.id) }
        guard !chosen.isEmpty else { throw Failure.nothingToMove }
        guard let item = try? repository.loadItem(id: itemId), item.deletedAt == nil else { throw Failure.itemNotFound }
        guard let target = StoredSessionMargin.targetSession(in: try repository.loadSessions(itemId: itemId)) else {
            throw Failure.noSession
        }
        let canPlace = PlayerItemMargin.canPlace(itemId: itemId, repository: repository)
        let durationMs = item.media?.durationMs
        let planned = chosen.map { margin -> PlannedMargin in
            guard canPlace, let durationMs, let (position, source) = savedPlace(of: margin, on: itemId, runs: runs),
                  position >= 0, position < durationMs else {
                return PlannedMargin(margin: margin, positionMs: nil, placeSource: nil)
            }
            return PlannedMargin(margin: margin, positionMs: position, placeSource: source)
        }
        return Plan(
            session: session, itemId: itemId, itemTitle: item.title, targetSessionId: target.id,
            itemHasMediaClock: PlayerItemMargin.hasMediaClock(target), itemDurationMs: durationMs, margins: planned,
            removesSession: removesSession(session, movingIds: Set(chosen.map(\.id)))
        )
    }

    /// The place on `itemId` the app saved for `margin` at capture: its `playingThen` for that item with a position, else a
    /// player run of that item still in memory that held its time. Never anything else.
    static func savedPlace(of margin: LiveSessionMargin, on itemId: String, runs: [LiveSessionFiling.PlayerRun]) -> (Int, String)? {
        if let hint = margin.playingThen, hint.itemId == itemId, let position = hint.positionMs {
            return (position, hint.source == .watchTarget ? placeSourceWatchTarget : placeSourceSavedRun)
        }
        if let run = LiveSessionFiling.holdingRun(of: itemId, at: margin.markedAt, runs: runs) {
            return (run.positionMs(at: min(margin.markedAt, run.endedAt)), placeSourceSavedRun)
        }
        return nil
    }

    // MARK: Which items to offer (Design 2.5)

    /// The picker's two sections: the started items the chosen Margins' `playingThen` names, newest Margin first, then
    /// every other started item in `choices`' order (newest listening first). `choices` are the started, not deleted
    /// items (`StoredSessionMargin.itemChoices(startedOnly: true)`), so an item that is gone is never suggested.
    public static func suggestions(
        margins: [LiveSessionMargin], choices: [StoredSessionMargin.ItemChoice]
    ) -> (playingThen: [StoredSessionMargin.ItemChoice], recent: [StoredSessionMargin.ItemChoice]) {
        let byId = Dictionary(choices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var named: [StoredSessionMargin.ItemChoice] = []
        for margin in margins.sorted(by: { ($0.markedAt, $0.id) > ($1.markedAt, $1.id) }) {
            guard let id = margin.playingThen?.itemId, let choice = byId[id], !named.contains(choice) else { continue }
            named.append(choice)
        }
        let namedIds = Set(named.map(\.id))
        return (named, choices.filter { !namedIds.contains($0.id) })
    }

    // MARK: The item side (Design 2.9.4 step 1)

    /// The id a moved Margin has on the item. Fixed by its live id, so a second `execute` of the same move finds the rows
    /// the first wrote and writes no second copy.
    public static func movedMarginId(liveMarginId: String) -> String { "ij-moved-\(liveMarginId)" }

    /// Writes every planned Margin and its origin record onto the item in one transaction, and returns the written
    /// Margins with their origins attached. If anything throws, nothing is left written. A Margin already written by an
    /// earlier call of the same move is returned as it is. The live session is not touched.
    public static func execute(
        plan: Plan, repository: Repository, movedAt: Date = Date()
    ) throws -> [Interjection] {
        try execute(plan: plan, repository: repository, movedAt: movedAt, afterEachWrite: { _ in })
    }

    /// `execute`, with a hook run after each Margin is written, which a test uses to stop the move part way.
    static func execute(
        plan: Plan, repository: Repository, movedAt: Date, afterEachWrite: (Int) throws -> Void
    ) throws -> [Interjection] {
        // What is already written is read inside the transaction, so two overlapping calls of one move can't both
        // write it: the second sees the first's rows and returns them (Design 2.9.4).
        var rows: [(Interjection, MovedMarginOrigin)] = []
        var written: [(Interjection, MovedMarginOrigin)] = []
        func write() throws {
            let existing = Dictionary(
                try repository.loadInterjections(sessionId: plan.targetSessionId).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            rows = plan.margins.map { planned -> (Interjection, MovedMarginOrigin) in
                let id = movedMarginId(liveMarginId: planned.margin.id)
                if let already = existing[id], let origin = already.movedOrigin { return (already, origin) }
                return build(planned, plan: plan, movedAt: movedAt)
            }
            for (margin, origin) in rows where existing[margin.id]?.movedOrigin == nil {
                try repository.saveInterjection(margin)
                written.append((margin, origin))
                try repository.saveMovedMarginOrigin(origin)
                try afterEachWrite(written.count)
            }
        }
        if let store = repository as? any SessionRepositoryTransaction {
            try store.withSessionTransaction {
                // An item deleted for good after the plan was made takes nothing with it, so nothing is written for it.
                guard try store.hasItemRow(id: plan.itemId) else { throw Failure.itemNotFound }
                try write()
            }
        } else {
            do {
                try write()
            } catch {
                for (margin, _) in written { try? repository.deleteMovedMargin(id: margin.id, sessionId: margin.sessionId) }
                throw error
            }
        }
        return rows.map { margin, origin in
            var attached = margin
            attached.movedOrigin = origin
            return attached
        }
    }

    /// The item Margin and its origin for one planned Margin: the fields the capture engine would set, with values that
    /// say what is known and nothing more (Design 2.9.2).
    static func build(_ planned: PlannedMargin, plan: Plan, movedAt: Date) -> (Interjection, MovedMarginOrigin) {
        let live = planned.margin
        let id = movedMarginId(liveMarginId: live.id)
        let words = live.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor: Anchor
        let percent: Int
        if let position = planned.positionMs, let duration = plan.itemDurationMs, duration > 0 {
            anchor = Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: position)
            percent = min(100, max(0, Int(Double(position) / Double(duration) * 100)))
        } else {
            anchor = Anchor(
                anchorType: plan.itemHasMediaClock ? .media : .text, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "",
                mediaTimeMs: nil)
            percent = 0
        }
        let spoken = live.isSpoken
        let margin = Interjection(
            id: id, itemId: plan.itemId, sessionId: plan.targetSessionId, targetType: .item, targetId: plan.itemId,
            createdAt: live.markedAt, roughPercent: percent, anchor: anchor,
            audioPath: live.audioPath, audioStatus: spoken ? "saved" : "discarded",
            transcriptionStatus: spoken && words.isEmpty ? "pending" : "transcribed",
            transcript: words.isEmpty ? nil : words, cleanedTranscript: nil,
            displayText: spoken || words.isEmpty ? nil : words,
            status: "active",
            // No place, no context job. A placed one is pending like any new Margin at a media time, and the app queues it.
            anchorContextStatus: planned.isPlaced ? Interjection.contextStatus(for: anchor) : .ready,
            // The fingerprint is taken only while recording, so a friend places a moved podcast Margin by time alone.
            podcastAnchorEvidenceCaptureStatus: .unavailable,
            captureKind: spoken ? .audio : .written
        )
        let origin = MovedMarginOrigin(
            marginId: id, itemId: plan.itemId, sessionId: plan.targetSessionId,
            liveMarginId: live.id, fromLiveSessionId: plan.session.id,
            fromLiveSessionTitle: LiveSessionFileWorker.title(of: plan.session),
            sessionPlaceLabel: placeLabel(for: live, in: plan.session),
            markedAt: live.markedAt, deviceMarkedAt: live.deviceMarkedAt, movedAt: movedAt,
            placeKnown: planned.isPlaced, placeSource: planned.placeSource,
            filingNote: live.filingNote, clockNote: live.clockNote, spokenOn: live.spokenOn, durationMs: live.durationMs
        )
        return (margin, origin)
    }

    /// The Margins pane's position line, kept only when it says where the Margin was in the outside source ("about 1:23:10",
    /// "page 118"). A line that only gives the session's own clock adds nothing to "Moved from".
    static func placeLabel(for margin: LiveSessionMargin, in session: LiveSession) -> String? {
        let label = LiveSessionMarginsList.positionLabel(for: margin, in: session).trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    // MARK: Undo (Design 2.7)

    /// Why Undo can't put the Margins back. The live side adds two of its own (`LiveSessionFileWorker.RestoreOutcome`).
    public enum UndoRefusal: Equatable, Sendable {
        /// The listener changed a moved Margin on the item.
        case changedOnItem(title: String)
        case savedAsNotes
        case discarded

        public var message: String {
            switch self {
            case let .changedOnItem(title): "Couldn't put the Margins back. They've changed on “\(title)”."
            case .savedAsNotes: "Couldn't put the Margins back. The session was saved as notes."
            case .discarded: "Couldn't put the Margins back. The session was discarded."
            }
        }
    }

    /// Whether the listener changed any of `moved` on the item since the move: deleted it, starred it, wrote a private
    /// note, shared it, answered its tidy version, edited its words, or replied to it. A transcription or a context job
    /// finishing is not the listener's change and doesn't count. A Margin no longer in the store counts as changed.
    public static func listenerChanged(_ moved: [Interjection], repository: Repository) -> Bool {
        for original in moved {
            guard let now = (try? repository.loadInterjections(sessionId: original.sessionId))?.first(where: { $0.id == original.id }) else {
                return true
            }
            if now.status != original.status { return true }
            if (now.isStarredForSharing ?? false) != (original.isStarredForSharing ?? false) { return true }
            if (now.privateSharingNote ?? "") != (original.privateSharingNote ?? "") { return true }
            if !(now.sharedAs ?? []).isEmpty { return true }
            if now.tidyDecision != original.tidyDecision { return true }
            if let shown = now.displayText, shown != original.displayText, shown != now.transcript, shown != now.cleanedTranscript {
                return true
            }
            let identities = Set(now.sharedAs ?? [])
            if !identities.isEmpty,
               let sessions = try? repository.loadSessions(itemId: now.itemId),
               sessions.contains(where: { session in
                   ((try? repository.loadInterjections(sessionId: session.id)) ?? [])
                       .contains { $0.replyTo.map { identities.contains($0.parent) } ?? false }
               }) {
                return true
            }
        }
        return false
    }

    /// Takes the moved Margins back off the item: each row and its origin outright, with no file cleanup (the live session
    /// names the recording again). Returns the words a transcription found meanwhile, by live Margin id, for the restored
    /// live Margins. Run only after `listenerChanged` said no.
    @discardableResult
    public static func undoItemSide(_ moved: [Interjection], repository: Repository) throws -> [String: String] {
        var words: [String: String] = [:]
        func remove() throws {
            for margin in moved {
                let current = (try? repository.loadInterjections(sessionId: margin.sessionId))?.first { $0.id == margin.id }
                if let liveId = current?.movedOrigin?.liveMarginId ?? margin.movedOrigin?.liveMarginId,
                   let found = current?.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !found.isEmpty,
                   current?.captureKind != .written {
                    words[liveId] = found
                }
                try repository.deleteMovedMargin(id: margin.id, sessionId: margin.sessionId)
            }
        }
        if let store = repository as? any SessionRepositoryTransaction {
            try store.withSessionTransaction(remove)
        } else {
            try remove()
        }
        return words
    }

    // MARK: Words (Design 2.5 to 2.7)

    public enum Wording {
        public static func movingLine(count: Int) -> String {
            count == 1 ? "Moving 1 Margin" : "Moving \(count) Margins"
        }

        public static let movingThis = "Moving this Margin"

        public static func dialogTitle(count: Int, title: String) -> String {
            count == 1 ? "Move this Margin to “\(title)”?" : "Move \(count) Margins to “\(title)”?"
        }

        /// The dialog's message for `placed` Margins with a place and `unplaced` without one.
        public static func dialogMessage(placed: Int, unplaced: Int, title: String) -> String {
            let count = placed + unplaced
            if count == 1 {
                return placed == 1
                    ? "It will sit where “\(title)” was playing when you made it."
                    : "No playback place was saved with this Margin, so it will be on the item without a place."
            }
            if unplaced == 0 { return "They'll sit where “\(title)” was playing when you made them." }
            if placed == 0 { return "No playback place was saved with them, so they'll be on the item without a place." }
            let first = placed == 1
                ? "1 will sit where it was playing when you made it."
                : "\(placed) will sit where it was playing when you made them."
            let second = unplaced == 1
                ? "1 had no playback place saved and will be on the item without a place."
                : "\(unplaced) had no playback place saved and will be on the item without a place."
            return first + " " + second
        }

        public static func confirmButton(count: Int) -> String {
            count == 1 ? "Move Margin" : "Move \(count) Margins"
        }

        public static func moved(count: Int, title: String) -> String {
            count == 1 ? "Moved the Margin to “\(title)”." : "Moved \(count) Margins to “\(title)”."
        }

        public static func putBack(count: Int) -> String {
            count == 1 ? "Margin put back." : "Margins put back."
        }

        public static func moveFailed(count: Int) -> String {
            count == 1 ? "Couldn't move the Margin. Nothing was changed." : "Couldn't move the Margins. Nothing was changed."
        }

        public static let marginsGone = "Those Margins are no longer in this session."
        public static let loading = "Loading your Library…"
        public static let loadFailed = "Couldn't load your Library."
        public static let emptyTitle = "Nothing to move to yet"
        public static let emptyMessage = "Margins move onto something you've started listening to. Play it once, then come back."

        public static func noHits(_ query: String) -> String {
            "No started item matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”."
        }

        public static let playingThenSection = "Playing when you made it"
        public static let playingThenLine = "Was playing then"
        public static let recentSection = "Recently played"
        public static let chooseIntro = "Pick the Margins that belong to an item."
        public static let notTranscribed = "Spoken Margin, not transcribed yet"
    }
}
