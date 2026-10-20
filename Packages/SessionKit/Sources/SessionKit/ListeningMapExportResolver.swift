import Foundation

/// The Listening Map an export carries for an item: what the item's Timeline shows (#2121).
///
/// An item's map can sit in either of two stores. Text items and publisher chapters use the
/// legacy `ListeningMap` record (or the one the canonical source derives). Podcast, community,
/// friend's and imported maps are a portable proposal placed by a resolved projection, which the
/// Timeline turns into scenes with `SceneStarts`. Reading only the legacy record left podcast
/// handoffs with no map at all, whatever the toggle said.
///
/// The export keeps its `ListeningMap` shape (no format change): placed scenes become chapters at
/// their percent of the episode, after any legacy chapters. Scenes that can't be placed on this
/// copy are left out, as the Timeline leaves them out.
public enum ListeningMapExportResolver {
    /// `durationMs` is the transcript's length, used when the item doesn't know its own, as the Timeline does.
    public static func resolve(item: Item, repository: SessionRepository, durationMs: Int?) throws -> ListeningMap? {
        let legacy = try repository.loadListeningMap(itemId: item.id)
            ?? (try? repository.loadCanonicalSource(itemId: item.id))?.derivedListeningMap()
        let projection = try repository.loadResolvedListeningMapProjection(itemId: item.id)
        let proposal = SharedListeningMapPlacement.proposal(
            for: projection,
            committed: try repository.loadPortableListeningMapProposals(itemId: item.id),
            layers: try repository.loadImportedCommentaryLayers(itemId: item.id)
        )
        let scenes = SceneStarts(scenes: proposal?.scenes ?? [], projection: projection).chapters
        guard !scenes.isEmpty else { return legacy }

        let duration = (item.media?.durationMs ?? durationMs).flatMap { $0 > 0 ? $0 : nil }
            ?? sceneEnd(proposal: proposal, projection: projection)
        let legacyChapterIDs = Set(legacy?.chapters.map(\.id) ?? [])
        let sceneChapters = scenes.filter { !legacyChapterIDs.contains($0.id) }.map { scene in
            Chapter(id: scene.id, title: scene.title, startChar: 0, endChar: 0, percent: percent(scene.startMs, of: duration))
        }
        return ListeningMap(
            id: legacy?.id ?? proposal?.id ?? "map-\(item.id)",
            itemId: item.id,
            overview: legacy?.overview ?? "",
            chapters: (legacy?.chapters ?? []) + sceneChapters
        )
    }

    /// With no known duration, the last placed scene end stands in, so percents still rise through the map.
    private static func sceneEnd(proposal: PortableListeningMapProposalArtifact?, projection: ResolvedListeningMapProjection?) -> Int? {
        let starts = SceneStarts(scenes: proposal?.scenes ?? [], projection: projection)
        return (starts.sceneEnds.compactMap { $0 } + starts.sceneStarts.compactMap { $0 }).max().flatMap { $0 > 0 ? $0 : nil }
    }

    private static func percent(_ startMs: Int, of durationMs: Int?) -> Int {
        guard let durationMs else { return 0 }
        return max(0, min(100, Int((Double(startMs) / Double(durationMs) * 100).rounded())))
    }
}
