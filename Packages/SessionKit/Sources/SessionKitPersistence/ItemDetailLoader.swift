import Foundation
import SessionKit

/// Loads item presentation while retaining the store's existing read and write policies.
public struct ItemDetailLoader {
    public static func load(
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
        // Chapters and duration only: the full timeline is thousands of segments, several MB of JSON (#2073).
        let timelineSummary = try store.loadTranscriptTimelineSummary(itemId: id)
        let mediaChapters = timelineSummary?.chapters ?? []
        let projection = try store.loadResolvedListeningMapProjection(itemId: id)
        let committed = try store.loadPortableListeningMapProposals(itemId: id)
        let proposal = SharedListeningMapPlacement.proposal(
            for: projection, committed: committed,
            layers: try store.loadImportedCommentaryLayers(itemId: id))
        let sceneStarts = SceneStarts(scenes: proposal?.scenes ?? [], projection: projection)
        let listeningMapScenes = sceneStarts.chapters
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
        // Only a Margin that is placed by media time needs the segments to name its surrounding words.
        let needsSegments = isNativeAudio && storedInterjections.contains {
            $0.targetType == .item && $0.anchor.mediaTimeMs != nil
        }
        let anchorContexts = try needsSegments
            ? store.resolveSourceAnchorContexts(
                itemId: id,
                mediaTimesMs: Set(storedInterjections.compactMap { $0.targetType == .item ? $0.anchor.mediaTimeMs : nil })
            )
            : [:]
        let interjections = storedInterjections.map { interjection -> Interjection in
            guard isNativeAudio,
                  interjection.targetType == .item,
                  let mediaTimeMs = interjection.anchor.mediaTimeMs,
                  let answer = anchorContexts[mediaTimeMs] else {
                return interjection
            }
            var resolved = interjection
            if let context = answer {
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
        // Worked out here so the Item screen's `body` doesn't read the store for it on every render (#2506).
        let sharedMapRefusalReason = SharedListeningMapPlacement.storedRefusalReason(
            layers: importedLayers,
            listenerHasMap: SharedListeningMapPlacement.listenerHasMap(
                proposalIds: committed.map(\.id), hasTimelineChapters: !mediaChapters.isEmpty))
        return ItemDetailState(
            id: item.id,
            title: item.title,
            status: item.status,
            text: item.text ?? "",
            externalReference: item.externalReference ?? "",
            publishedDateText: ItemMetadata.publishedDateText(item.publishedAt),
            descriptionText: item.descriptionText,
            externalReferenceType: item.externalReferenceType ?? "",
            overview: map?.overview ?? "",
            navigation: canonicalSource?.navigation ?? [],
            chapters: map?.chapters ?? [],
            mediaChapters: mediaChapters,
            listeningMapScenes: listeningMapScenes,
            listeningMapSummarySpans: sceneStarts.summarySpans,
            mediaDurationMs: item.media?.durationMs ?? timelineSummary?.durationMs,
            isNativeAudio: isNativeAudio,
            documentStructure: item.documentStructure,
            sessions: sessions,
            sessionRows: sessionRows,
            interjections: interjections,
            importedCommentaryLayers: importedLayers,
            importedCommentaryInterjections: importedInterjections,
            sharedMarginPlacement: placementPasses.pass(itemId: item.id),
            sharedMapRefusalReason: sharedMapRefusalReason,
            turns: turns
        ).includingTimelineSource(
            try? store.loadStructuredDocument(itemId: id),
            elements: try? store.loadSourceElements(itemId: id))
    }
}
