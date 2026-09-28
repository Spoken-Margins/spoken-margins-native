import CryptoKit
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
}

/// Step 5 of C1 M3: when a PDF imported under an older extraction is imported
/// again, move the existing item to the new extraction only if nothing of the
/// listener's can land in the wrong place (I13 rule 1d). Otherwise it stays.
public enum StructuredDocumentUpgrader {
    public enum StaysBecause: Error, Equatable, Sendable {
        case noText
        /// Margins imported from someone else's packet anchor into this text too.
        case importedCommentary
        /// Prepared audio was rendered from the old text.
        case preparedAudio
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
        guard let oldText = existing.text, !oldText.isEmpty, !document.text.isEmpty else { return .failure(.noText) }
        if try !repository.loadImportedCommentaryLayers(itemId: existing.id).isEmpty {
            return .failure(.importedCommentary)
        }
        if try !repository.loadPreparedAudioManifests(itemId: existing.id).isEmpty {
            return .failure(.preparedAudio)
        }
        let sessions = try repository.loadSessions(itemId: existing.id)
        let margins = try sessions.flatMap { try repository.loadInterjections(sessionId: $0.id) }
            .filter { $0.itemId == existing.id }
        let nonText = margins.filter { $0.anchor.anchorType != .text }.map(\.id)
        guard nonText.isEmpty else { return .failure(.nonTextAnchor(marginIds: nonText)) }

        let anchors = margins.map {
            StructuredDocumentMigration.TextAnchor(
                id: $0.id, start: $0.anchor.startChar, end: $0.anchor.endChar,
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
            if let range = placed[margin.id] {
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
        if listeningMap != nil { item.status = "ready" }
        return .success(StructuredDocumentUpgrade(
            item: item, listeningMap: listeningMap, document: document,
            interjections: movedMargins, sessions: movedSessions
        ))
    }
}
