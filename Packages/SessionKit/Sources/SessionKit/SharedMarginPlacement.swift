import Foundation

/// Which items have a shared-Margin placement pass scheduled or running (#872).
///
/// A podcast placement pass resets a new edition's Margins to unresolved before it starts, then takes a
/// minute or more to write results. Read straight from the store, those Margins said "unresolved" while the
/// app was still working, and the listener had no reason to wait. The app records each pass here, with the
/// positions its Margins had before the reset, so the screen can say they are being placed instead.
/// Display only: playback reads the store, so a reset Margin never plays at its old edition's time.
public struct SharedMarginPlacementPasses: Equatable, Sendable {
    public enum Work: Hashable, Sendable {
        /// Matching the Margins' evidence against the listener's copy.
        case matching
        /// Transcribing the listener's copy for a second, transcript-assisted pass.
        case transcript
    }

    public struct Pass: Equatable, Sendable {
        /// Margin id to the media time it had before this pass reset it.
        public fileprivate(set) var previousMediaTimeMs: [String: Int] = [:]
        fileprivate var work: Set<Work> = []
    }

    private var passes: [String: Pass] = [:]

    public init() {}

    /// Records work starting for an item. `previous` is what the Margins showed when the work was scheduled;
    /// a position recorded by earlier work on the same item is kept, since a later pass sees the reset values.
    public mutating func begin(_ work: Work, itemId: String, previous: [String: ImportedAnchorResolution] = [:]) {
        var pass = passes[itemId] ?? Pass()
        pass.work.insert(work)
        for (id, resolution) in previous where pass.previousMediaTimeMs[id] == nil {
            if SharedMarginPlacementStatus.isPlaced(resolution), let time = resolution.localMediaTimeMs {
                pass.previousMediaTimeMs[id] = time
            }
        }
        passes[itemId] = pass
    }

    public mutating func end(_ work: Work, itemId: String) {
        guard var pass = passes[itemId] else { return }
        pass.work.remove(work)
        passes[itemId] = pass.work.isEmpty ? nil : pass
    }

    public func pass(itemId: String?) -> Pass? {
        itemId.flatMap { passes[$0] }
    }
}

/// What the listener is told about a shared Margin's position (#872).
public enum SharedMarginPlacementStatus: Equatable, Sendable {
    /// A pass is scheduled or running and hasn't placed this Margin yet. Carries the position it had before
    /// the pass reset it, when it had one.
    case placing(previousMediaTimeMs: Int?)
    /// Nothing is running and no pass has finished for this layer, for example before the episode downloads.
    case notPlacedYet
    /// A finished pass's result: describe the resolution itself.
    case settled

    public init(
        resolution: ImportedAnchorResolution,
        marginId: String,
        layerStatus: ImportedSourceResolutionStatus,
        pass: SharedMarginPlacementPasses.Pass?
    ) {
        // A pending layer's Margins were reset for a new edition, so their stored values aren't results.
        let hasResult = layerStatus != .pending && Self.isPlaced(resolution)
        if hasResult {
            self = .settled
        } else if let pass {
            self = .placing(previousMediaTimeMs: pass.previousMediaTimeMs[marginId])
        } else {
            self = layerStatus == .pending ? .notPlacedYet : .settled
        }
    }

    /// The position to draw a Margin at while it is being placed again.
    public var previousMediaTimeMs: Int? {
        if case .placing(let previous) = self { return previous }
        return nil
    }

    /// The position wording while the Margin isn't settled; nil means describe the resolution as usual.
    public var positionDescription: String? {
        switch self {
        case .placing(let previous?): "Placing again · was \(Self.clock(previous))"
        case .placing(nil): "Placing in your copy…"
        case .notPlacedYet: "Not placed yet"
        case .settled: nil
        }
    }

    /// A short state label for a Margin that isn't settled; nil means label the resolution as usual.
    public var label: String? {
        switch self {
        case .placing: "Placing"
        case .notPlacedYet: "Not placed yet"
        case .settled: nil
        }
    }

    /// Whether a resolution places the Margin where it can play: a verified or approximate media time, or a
    /// verified text position. The app's playback eligibility uses the same rule.
    public static func isPlaced(_ resolution: ImportedAnchorResolution) -> Bool {
        guard !resolution.isAmbiguous else { return false }
        if resolution.localMediaTimeMs != nil {
            switch resolution.evidenceClass {
            case .exactEdition, .transcriptVerified, .acousticVerified, .fused,
                 .mapInterpolated, .timestampFallback, .recipientConfirmed:
                return true
            case .articleTextVerified, .ambiguous, .absentFromRecipientEdition, .unresolved:
                return false
            }
        }
        guard resolution.localStartChar != nil else { return false }
        switch resolution.evidenceClass {
        case .articleTextVerified, .exactEdition, .recipientConfirmed:
            return true
        case .transcriptVerified, .acousticVerified, .fused, .mapInterpolated,
             .timestampFallback, .ambiguous, .absentFromRecipientEdition, .unresolved:
            return false
        }
    }

    static func clock(_ mediaTimeMs: Int) -> String {
        let seconds = max(0, mediaTimeMs / 1_000)
        return seconds >= 3_600
            ? String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
