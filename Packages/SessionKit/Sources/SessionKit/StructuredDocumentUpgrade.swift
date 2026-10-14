#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Everything that changes when an item moves to a new extraction, written in one
/// transaction (StructuredDocumentRepository.applyStructuredDocumentUpgrade).
public struct StructuredDocumentUpgrade: Sendable {
    public var item: Item
    public var listeningMap: ListeningMap?
    public var document: StructuredDocument
    /// Margins with their anchors moved to the same words in the new text.
    public var interjections: [Interjection]
    /// Sessions with their positions moved to the same place in the new text.
    public var sessions: [Session]
    /// Preparation is disposable: the repository retires all current records at
    /// commit, including those enqueued while this plan was being computed.
    let baseline: StructuredDocumentUpgradeBaseline

    public func validateBaseline(repository: any (SessionRepository & StructuredDocumentRepository)) throws {
        if try StructuredDocumentUpgradeBaseline.read(itemId: item.id, repository: repository) != baseline {
            throw StructuredDocumentUpgradeError.changedSincePlanned
        }
    }
}

/// Step 5 of C1 M3: when a PDF imported under an older extraction is imported
/// again, move the existing item to the new extraction only if nothing of the
/// listener's can land in the wrong place (I13 rule 1d). Otherwise it stays.
public enum StructuredDocumentUpgrader {
    public static func requireUnchangedSincePlanned(_ upgrade: StructuredDocumentUpgrade, repository: SessionRepository & StructuredDocumentRepository) throws {
        try upgrade.validateBaseline(repository: repository)
    }
    public enum StaysBecause: Error, Equatable, Sendable {
        case noText
        /// Margins imported from someone else's packet anchor into this text too.
        case importedCommentary
        case nonTextAnchor(marginIds: [String])
        case marginNotPlaced(marginIds: [String])
        case positionNotPlaced(sessionIds: [String])
    }

    public static func plan(
        existing: Item,
        document: StructuredDocument,
        listeningMap: ListeningMap?,
        repository: SessionRepository & StructuredDocumentRepository
    ) throws -> Result<StructuredDocumentUpgrade, StaysBecause> {
        let baseline: StructuredDocumentUpgradeBaseline
        if let store = repository as? any SessionRepositoryTransaction {
            baseline = try store.withSessionTransaction {
                try StructuredDocumentUpgradeBaseline.read(itemId: existing.id, repository: repository)
            }
        } else {
            baseline = try StructuredDocumentUpgradeBaseline.read(itemId: existing.id, repository: repository)
        }
        guard baseline.item == existing else { throw StructuredDocumentUpgradeError.changedSincePlanned }
        guard let oldText = existing.text, !oldText.isEmpty, !document.text.isEmpty else { return .failure(.noText) }
        if !baseline.commentary.isEmpty {
            return .failure(.importedCommentary)
        }
        let timeline = baseline.timeline?.timeline
        let sessions = baseline.sessions.map { session in
            // A session playing the rendered narration goes back to reading the text, at
            // the place its media time had reached; then it moves like any other. The stored
            // timeline describes the item's current render only: a session on an older one
            // (#277) keeps its saved character offset (#344). So does every session once the
            // narration is detached, since the timeline left behind can be a newer render's
            // than the session's, and nothing records which (#344 audit 3).
            guard PreparedNarrationFallback.canReadText(instead: session, item: existing) else { return session }
            let timelineDescribesTarget = PreparedNarrationFallback.media(existing.media, isTarget: session.currentTargetId)
            return PreparedNarrationFallback.liveSpeechSession(
                from: session, item: existing, timeline: timelineDescribesTarget ? timeline : nil
            )
        }
        let margins = baseline.margins
        let nonText = margins.filter { $0.anchor.anchorType != .text }.map(\.id)
        guard nonText.isEmpty else { return .failure(.nonTextAnchor(marginIds: nonText)) }

        // Margin ids are numbered per session ("ij-001" in each; the store keys them
        // by session and id), so a moved range is tracked by both.
        func key(_ margin: Interjection) -> String { "\(margin.sessionId)::\(margin.id)" }
        let anchors = margins.map {
            StructuredDocumentMigration.TextAnchor(
                id: key($0), start: $0.anchor.startChar, end: $0.anchor.endChar,
                before: $0.anchor.anchorBefore, after: $0.anchor.anchorAfter
            )
        }
        let placed: [String: Range<Int>]
        switch StructuredDocumentMigration.place(anchors, from: oldText, into: document.text) {
        case .moved(let ranges): placed = ranges
        case .stays(let unplaced): return .failure(.marginNotPlaced(marginIds: unplaced))
        }

        var movedSessions: [Session] = []
        var unplacedSessions: [String] = []
        for var session in sessions {
            // Only an item-text position counts in the PDF's text. A session paused in a
            // summary or AI reply counts in that turn's text, so it stays as it is.
            guard session.currentTargetType == .itemTextTTS else {
                movedSessions.append(session)
                continue
            }
            guard let offset = StructuredDocumentMigration.placePosition(session.position.charOffset, from: oldText, into: document.text) else {
                unplacedSessions.append(session.id)
                continue
            }
            session.position.charOffset = offset
            // Chapter ids belong to the old map; the new map's chapter at this offset replaces it.
            session.position.chapterId = session.position.chapterId == nil
                ? nil
                : listeningMap?.chapters.first { $0.startChar <= offset && offset < $0.endChar }?.id
            movedSessions.append(session)
        }
        guard unplacedSessions.isEmpty else { return .failure(.positionNotPlaced(sessionIds: unplacedSessions)) }

        let newEdition = SHA256.hash(data: Data(document.text.utf8)).map { String(format: "%02x", $0) }.joined()
        let movedMargins = margins.map { margin -> Interjection in
            var moved = margin
            if let range = placed[key(margin)] {
                moved.anchor.startChar = range.lowerBound
                moved.anchor.endChar = range.upperBound
            }
            // The offsets now count in the new text (PortableArticleAnchorResolver's exact edition).
            if moved.sourceExactEditionSHA256 != nil { moved.sourceExactEditionSHA256 = newEdition }
            return moved
        }
        var item = existing
        item.text = document.text
        item.deletedAt = nil
        if item.media?.sourceType == .generatedTTSPrerendered {
            item.media = nil
        }
        if listeningMap != nil { item.status = "ready" }
        return .success(StructuredDocumentUpgrade(
            item: item, listeningMap: listeningMap, document: document,
            interjections: movedMargins, sessions: movedSessions,
            baseline: baseline
        ))
    }
}

/// Immutable planning inputs. Searches run after the read transaction has closed;
/// commit compares these again inside its write transaction, including new rows.
struct StructuredDocumentUpgradeBaseline: Equatable, Sendable {
    var item: Item
    var document: StructuredDocument?
    var listeningMap: ListeningMap?
    var sessions: [Session]
    var margins: [Interjection]
    var timeline: SourceTranscriptTimeline?
    var commentary: [ImportedCommentaryLayer]

    static func read(itemId: String, repository: any (SessionRepository & StructuredDocumentRepository)) throws -> Self {
        let sessions = try repository.loadSessions(itemId: itemId).sorted { $0.id < $1.id }
        return try Self(
            item: repository.loadItem(id: itemId),
            document: repository.loadStructuredDocument(itemId: itemId),
            listeningMap: repository.loadListeningMap(itemId: itemId),
            sessions: sessions,
            margins: sessions.flatMap { try repository.loadInterjections(sessionId: $0.id) }
                .filter { $0.itemId == itemId }.sorted { ($0.sessionId, $0.id) < ($1.sessionId, $1.id) },
            timeline: repository.loadTranscriptTimeline(itemId: itemId),
            commentary: repository.loadImportedCommentaryLayers(itemId: itemId).sorted { $0.id < $1.id }
        )
    }
}

public enum StructuredDocumentUpgradeError: Error, Equatable, Sendable { case changedSincePlanned }
