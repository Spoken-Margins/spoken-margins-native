import Foundation

/// The parts of an item's detail that Skim's loaded map and summary assets depend on (#2184).
///
/// The model reassigns `selectedItem` on every reload: a pause, a saved position, a new Margin. Almost none of those
/// change the map, but each one used to drop Skim's resources, so the next snapshot tick re-read the map projection,
/// its proposals, the shared layers and the whole owned-asset table on the main thread. Only a change to this key drops
/// them now, so a mapped episode reads them once per item and map change.
///
/// A layer's proposals are fixed when it is imported, so a layer counts by its identity and the fields that can change.
/// Map writes that don't reach `selectedItem` (a community map, a finished episode map, a package import) still refresh
/// Skim explicitly, as they did before.
public struct SkimResourceKey: Equatable, Sendable {
    public let itemId: String
    let scenes: [MediaTimelineChapter]
    let summarySpans: [SceneSummarySpan]
    let layers: [Layer]

    struct Layer: Equatable, Sendable {
        let id: String
        let deletedAt: Date?
        let sourceResolutionStatus: ImportedSourceResolutionStatus
        let resolvedRecipientEditionSHA256: String?
    }

    public init(_ item: ItemDetailState) {
        itemId = item.id
        scenes = item.listeningMapScenes
        summarySpans = item.listeningMapSummarySpans
        layers = item.importedCommentaryLayers.map {
            Layer(id: $0.id, deletedAt: $0.deletedAt, sourceResolutionStatus: $0.sourceResolutionStatus,
                  resolvedRecipientEditionSHA256: $0.resolvedRecipientEditionSHA256)
        }
    }
}
