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
    /// What the plan read. A store that applies the upgrade checks inside its transaction that none of it
    /// changed, so a plan made off the main thread can't overwrite a Margin saved while it was running.
    public var basis: Basis?

    public struct Basis: Equatable, Sendable {
        /// The whole row, not just its text: the write replaces it, so any other field changed meanwhile would be lost.
        var item: Item
        var sessions: [Session]
        var margins: [Interjection]
    }
}

public enum StructuredDocumentUpgradeError: Error, Equatable, Sendable {
    /// The item, its sessions or its Margins changed between planning and applying.
    case changedSincePlanned
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
        /// A Margin, session or audio render landed between planning and writing (only possible off the main thread).
        case changedWhilePlanning
    }

    /// Plans and writes the upgrade without touching engine state, so a caller can run it off the main thread.
    /// The store re-checks the plan's inputs inside the write's transaction; if any changed, nothing is written.
    public static func planAndApply(
        existing: Item,
        document: StructuredDocument,
        listeningMap: ListeningMap?,
        repository: SessionRepository & StructuredDocumentRepository
    ) throws -> Result<StructuredDocumentUpgrade, StaysBecause> {
        let planned = try plan(existing: existing, document: document, listeningMap: listeningMap, repository: repository)
        guard case .success(let upgrade) = planned else { return planned }
        do {
            try repository.applyStructuredDocumentUpgrade(upgrade)
            return .success(upgrade)
        } catch StructuredDocumentUpgradeError.changedSincePlanned {
            return .failure(.changedWhilePlanning)
        }
    }

    /// Called by a store inside the transaction that applies `upgrade`.
    public static func requireUnchangedSincePlanned(
        _ upgrade: StructuredDocumentUpgrade,
        repository: SessionRepository & StructuredDocumentRepository
    ) throws {
        guard let basis = upgrade.basis else { return }
        guard try currentBasis(itemId: upgrade.item.id, repository: repository) == basis else {
            throw StructuredDocumentUpgradeError.changedSincePlanned
        }
    }

    /// The item row plus every session and Margin on it, in a fixed order; nil when something the
    /// upgrade cannot carry (imported Margins, prepared audio, a deleted item) is now present.
    private static func currentBasis(itemId: String, repository: SessionRepository & StructuredDocumentRepository) throws -> StructuredDocumentUpgrade.Basis? {
        let item: Item
        do { item = try repository.loadItem(id: itemId) }
        catch SessionKitError.missingFixture { return nil }
        guard item.deletedAt == nil,
              try repository.loadImportedCommentaryLayers(itemId: itemId).isEmpty,
              try repository.loadPreparedAudioManifests(itemId: itemId).isEmpty else { return nil }
        let (sessions, margins) = try sessionsAndMargins(itemId: itemId, repository: repository)
        return StructuredDocumentUpgrade.Basis(item: item, sessions: sessions, margins: margins)
    }

    private static func sessionsAndMargins(itemId: String, repository: SessionRepository & StructuredDocumentRepository) throws -> ([Session], [Interjection]) {
        let sessions = try repository.loadSessions(itemId: itemId).sorted { $0.id < $1.id }
        let margins = try sessions.flatMap { try repository.loadInterjections(sessionId: $0.id) }
            .filter { $0.itemId == itemId }
            .sorted { ($0.sessionId, $0.id) < ($1.sessionId, $1.id) }
        return (sessions, margins)
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
        let (sessions, margins) = try sessionsAndMargins(itemId: existing.id, repository: repository)
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
        if listeningMap != nil { item.status = "ready" }
        return .success(StructuredDocumentUpgrade(
            item: item, listeningMap: listeningMap, document: document,
            interjections: movedMargins, sessions: movedSessions,
            basis: StructuredDocumentUpgrade.Basis(item: existing, sessions: sessions, margins: margins)
        ))
    }
}
