import Foundation

/// The rules behind when a shared podcast Margin may ask for a transcript of the listener's copy, and which
/// layers a placement pass works on. The app's `ImportedPodcastPlacementCoordinator` keeps the state (who holds
/// the transcription slot, when the last transcript started) and runs the work; these functions decide.
public enum ImportedPodcastPlacementPolicy {
    /// A transient transcript may start again this long after the last one started.
    public static let transientCooldown: TimeInterval = 60

    /// Whether a transient transcript may start now: outside the cooldown (measured from when the last attempt
    /// started, so a refused request never moves it) and with the item's transcription slot free.
    public static func transientTranscriptMayStart(lastStart: Date?, now: Date, slotIsFree: Bool) -> Bool {
        guard slotIsFree else { return false }
        guard let lastStart else { return true }
        return now.timeIntervalSince(lastStart) >= transientCooldown
    }

    /// The layers a placement pass works on, each with its Margins. A layer is skipped when it is deleted,
    /// is not a podcast, has no readable Margins, or has neither Margins nor map artifacts: an empty list
    /// would otherwise count as fully resolved (`[].allSatisfy` is true).
    public static func podcastLayerRecords(
        layers: [ImportedCommentaryLayer],
        loadRecords: (ImportedCommentaryLayer) -> [ImportedCommentaryInterjection]?
    ) -> [(ImportedCommentaryLayer, [ImportedCommentaryInterjection])] {
        layers.compactMap { layer -> (ImportedCommentaryLayer, [ImportedCommentaryInterjection])? in
            guard layer.deletedAt == nil,
                  layer.itemIdentity.itemType == .podcast,
                  let records = loadRecords(layer),
                  !records.isEmpty || ImportedMarginResends.hasLayerArtifacts(layer) else { return nil }
            return (layer, records)
        }
    }

    /// Whether any Margin on the item's podcast layers could still be placed by a transcript of the listener's
    /// copy. `recordNeedsTranscript` is the per-Margin rule (not placed inline yet, enough sender context).
    public static func commentaryNeedsTranscript(
        layers: [ImportedCommentaryLayer],
        loadRecords: (ImportedCommentaryLayer) -> [ImportedCommentaryInterjection]?,
        recordNeedsTranscript: (ImportedCommentaryInterjection) -> Bool
    ) -> Bool {
        podcastLayerRecords(layers: layers, loadRecords: loadRecords)
            .contains { $0.1.contains(where: recordNeedsTranscript) }
    }
}
