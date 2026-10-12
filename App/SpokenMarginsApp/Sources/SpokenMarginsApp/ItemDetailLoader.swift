import Foundation
import SessionKit
import SessionKitPersistence

/// Loads item presentation while retaining the store's existing read and write policies.
struct ItemDetailLoader {
    static func load(
        id: String,
        store: SQLiteSessionStore,
        snapshotItemId: String?,
        snapshotSessionId currentSnapshotSessionId: String?,
        placementPasses: SharedMarginPlacementPasses
    ) throws -> ItemDetailState {
        let item = try store.loadItem(id: id)
        var map = try store.loadListeningMap(itemId: id)
        let canonicalSource = try store.loadCanonicalSource(itemId: id)
        if map == nil,
           let canonicalSource,
           let derivedMap = canonicalSource.derivedListeningMap() {
            try store.saveListeningMap(derivedMap)
            map = derivedMap
        }
        let mediaTimeline = try store.loadTranscriptTimeline(itemId: id)?.timeline
        let mediaChapters = mediaTimeline?.chapters ?? []
        let projection = try store.loadResolvedListeningMapProjection(itemId: id)
        let proposal = SharedListeningMapPlacement.proposal(
            for: projection, committed: try store.loadPortableListeningMapProposals(itemId: id),
            layers: try store.loadImportedCommentaryLayers(itemId: id))
        let listeningMapScenes = SceneStarts(scenes: proposal?.scenes ?? [], projection: projection).chapters
        let sessions = try store.loadSessions(itemId: id)
        // A snapshot session is valid only for its own item. Without this
        // ownership check, an asynchronous selection bug can display one
        // item's title with another item's interjections and turns.
        let snapshotSessionId = snapshotItemId == id ? currentSnapshotSessionId : nil
        let activeSessionId = snapshotSessionId.flatMap { candidate in
            sessions.contains(where: { $0.id == candidate }) ? candidate : nil
        } ?? sessions.first?.id
        let storedInterjections = activeSessionId.flatMap {
            try? store.loadInterjections(sessionId: $0).filter { $0.status == "active" }
        } ?? []
        let isNativeAudio = item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream
        let interjections = storedInterjections.map { interjection -> Interjection in
            guard isNativeAudio,
                  interjection.targetType == .item,
                  let mediaTimeMs = interjection.anchor.mediaTimeMs,
                  let mediaTimeline else {
                return interjection
            }
            var resolved = interjection
            if let context = SourceAnchorContextResolver.resolve(
                mediaTimeMs: mediaTimeMs,
                timeline: mediaTimeline
            ) {
                resolved.anchor.anchorBefore = context.anchorBefore
                resolved.anchor.anchorAfter = context.anchorAfter
                resolved.anchor.transcriptSegmentId = context.transcriptSegmentId
                resolved.anchor.startChar = context.startChar
                resolved.anchor.endChar = context.endChar
                resolved.anchorContextStatus = .ready
            } else {
                resolved.anchor.anchorBefore = ""
                resolved.anchor.anchorAfter = ""
                resolved.anchor.transcriptSegmentId = nil
                resolved.anchor.startChar = 0
                resolved.anchor.endChar = 0
                resolved.anchorContextStatus = .unavailable
            }
            return resolved
        }
        let activeInterjectionIDs = Set(storedInterjections.map(\.id))
        let turns = (activeSessionId.flatMap { try? store.loadTurns(sessionId: $0) } ?? []).filter { turn in
            guard turn.turnType == "interjection_summary", !turn.sourceInterjectionIds.isEmpty else {
                return true
            }
            return Set(turn.sourceInterjectionIds).isSubset(of: activeInterjectionIDs)
        }
        let sessionRows = sessions.map { session in
            let notes = ((try? store.loadInterjections(sessionId: session.id)) ?? [])
                .filter { $0.status == "active" }
            return SessionPresentation(
                session: session,
                interjectionCount: notes.count,
                interjectionPreview: notes.reversed().compactMap { note in
                    let text = note.cleanedTranscript ?? note.transcript ?? note.displayText
                    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
                }.first
            )
        }
        let importedLayers = try store.loadImportedCommentaryLayers(itemId: id)
            .filter { $0.deletedAt == nil }
        let importedInterjections = Dictionary(uniqueKeysWithValues: importedLayers.map { layer in
            (layer.id, (try? store.loadImportedCommentaryInterjections(layerId: layer.id)) ?? [])
        })
        return ItemDetailState(
            id: item.id,
            title: item.title,
            status: item.status,
            text: item.text ?? "",
            externalReference: item.externalReference ?? "",
            overview: map?.overview ?? "",
            navigation: canonicalSource?.navigation ?? [],
            chapters: map?.chapters ?? [],
            mediaChapters: mediaChapters,
            listeningMapScenes: listeningMapScenes,
            mediaDurationMs: item.media?.durationMs ?? mediaTimeline?.durationMs,
            isNativeAudio: isNativeAudio,
            documentStructure: item.documentStructure,
            sessions: sessions,
            sessionRows: sessionRows,
            interjections: interjections,
            importedCommentaryLayers: importedLayers,
            importedCommentaryInterjections: importedInterjections,
            sharedMarginPlacement: placementPasses.pass(itemId: item.id),
            turns: turns
        ).includingTimelineSource(try? store.loadStructuredDocument(itemId: id))
    }
}
