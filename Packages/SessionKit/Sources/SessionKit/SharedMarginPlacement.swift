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
    /// A finished pass left this Margin unplaced, and the sender gave it nothing to find its spot by, only the
    /// clock time on their copy. The pass can place such a Margin only between two neighbours it did verify, and
    /// didn't. "Unresolved" would read as a match that failed, when the packet never gave it anything to match.
    case noPositionSent
    /// A finished pass's result: describe the resolution itself.
    case settled

    /// - Parameter hasPositionEvidence: whether the packet gave this Margin anything to match on
    ///   (`ImportedCommentaryInterjection.carriesPositionEvidence(in:)`). Only a Margin that has none and is still
    ///   unplaced once a pass has finished reads as sent without a position: before then, the pass may yet place
    ///   it between its verified neighbours. Defaults to true so a caller that doesn't know keeps the pass-based
    ///   wording.
    /// - Parameter awaitingPlacementPass: whether a pass is still to come for this Margin's layer
    ///   (`ImportedCommentaryLayer.awaitsPlacementPass`). A podcast layer is `.contextOnly` from the moment it is
    ///   imported, before the episode has downloaded, so its status can't say that no pass has run. Until one
    ///   finishes, an unplaced Margin is "not placed yet", not a failure. Defaults to false so a caller that
    ///   doesn't know keeps the pass-based wording.
    public init(
        resolution: ImportedAnchorResolution,
        marginId: String,
        layerStatus: ImportedSourceResolutionStatus,
        pass: SharedMarginPlacementPasses.Pass?,
        hasPositionEvidence: Bool = true,
        awaitingPlacementPass: Bool = false
    ) {
        // A pending layer's Margins were reset for a new edition, so their stored values aren't results.
        let hasResult = layerStatus != .pending && Self.isPlaced(resolution)
        if hasResult {
            self = .settled
        } else if let pass {
            self = .placing(previousMediaTimeMs: pass.previousMediaTimeMs[marginId])
        } else if layerStatus == .pending || awaitingPlacementPass {
            self = .notPlacedYet
        } else if !hasPositionEvidence, layerStatus != .wrongSource,
                  !resolution.isAmbiguous, resolution.evidenceClass != .ambiguous {
            // A layer that isn't this item's gets no pass, so it keeps the resolution's own wording.
            self = .noPositionSent
        } else {
            self = .settled
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
        case .noPositionSent: "Sent without a position"
        case .settled: nil
        }
    }

    /// A short state label for a Margin that isn't settled; nil means label the resolution as usual.
    public var label: String? {
        switch self {
        case .placing: "Placing"
        case .notPlacedYet: "Not placed yet"
        case .noPositionSent: "No position sent"
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

extension ImportedCommentaryLayer {
    /// Whether a placement pass is still to come for this layer: a podcast layer that no pass has finished for on
    /// the listener's file. A finished pass saves the file's digest with the layer, and a new edition clears it. The
    /// layer's status can't say this: a podcast layer is `.contextOnly` from the moment it is imported, before the
    /// episode has downloaded. A layer that isn't this item's (`.wrongSource`) gets no pass, ever.
    public var awaitsPlacementPass: Bool {
        itemIdentity.itemType == .podcast && sourceResolutionStatus != .wrongSource && resolvedRecipientEditionSHA256 == nil
    }
}

extension PortableAnchorEvidence {
    /// Whether the sender's own words around the Margin are long enough to find it by in a transcript: six
    /// words before or after. This is `PodcastTranscriptAnchorResolver.hasUsableContext`'s rule, counted the
    /// same way (runs of letters and numbers, as its `[\p{L}\p{N}]+` pattern finds them, so a combining mark or
    /// an emoji variation selector ends a word there and here). A host test keeps the two together.
    public var hasUsableTextContext: Bool {
        Self.wordCount(prefix) >= Self.minimumContextWords || Self.wordCount(suffix) >= Self.minimumContextWords
    }

    static let minimumContextWords = 6

    private static func wordCount(_ text: String?) -> Int {
        var count = 0
        var inWord = false
        for scalar in (text ?? "").unicodeScalars {
            let isWordScalar: Bool
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                isWordScalar = true
            default:
                isWordScalar = false
            }
            if isWordScalar, !inWord { count += 1 }
            inWord = isWordScalar
        }
        return count
    }
}

extension ImportedCommentaryInterjection {
    /// Whether the packet gave this Margin anything to find its spot by: audio fingerprints, a transcript
    /// context, or (through the layer) the sender's exact episode file. A Margin with none of these carries only
    /// the sender's clock time, which is never trusted on its own. A pass places it only between two neighbours
    /// it did verify (`PodcastAnchorFusionResolver.interpolatingBetweenVerifiedAnchors`), so call it sent without
    /// a position only once no pass is running (#872). A Margin that is already placed carries evidence by
    /// definition.
    public func carriesPositionEvidence(in layer: ImportedCommentaryLayer) -> Bool {
        sentPositionEvidence(in: layer) || SharedMarginPlacementStatus.isPlaced(resolution)
    }

    /// Whether the packet itself gave this Margin anything to match on, whatever a pass has made of it since. A
    /// podcast Margin without any carries only the sender's clock time (#3041).
    public func sentPositionEvidence(in layer: ImportedCommentaryLayer) -> Bool {
        guard layer.itemIdentity.itemType == .podcast else { return true }
        return !anchorEvidence.machineEvidenceAssetIds.isEmpty
            || !(podcastAnchorEvidence ?? []).isEmpty
            || anchorEvidence.hasUsableTextContext
            || layer.itemIdentity.exactEditionSHA256 != nil
    }
}

/// What one finished placement pass did with a layer's Margins, for the diagnostics export (#872). Counts only:
/// the export carries no Margin text or audio. It answers "why is this Margin still unplaced" without a device
/// trace: the packet sent no position, or it did and the pass couldn't find it in this copy.
public struct SharedMarginPlacementSummary: Equatable, Sendable {
    public private(set) var margins = 0
    public private(set) var placed = 0
    public private(set) var ambiguous = 0
    /// Had something to match on and the pass found no spot for it in this copy.
    public private(set) var notFound = 0
    /// Had nothing to match on: only the sender's clock time.
    public private(set) var noPositionSent = 0

    public init() {}

    /// The summary of a pass over these layers, as the pass left their Margins.
    public init(_ layers: [(ImportedCommentaryLayer, [ImportedCommentaryInterjection])]) {
        for (layer, records) in layers {
            for record in records {
                add(record.resolution, hasPositionEvidence: record.carriesPositionEvidence(in: layer))
            }
        }
    }

    public mutating func add(_ resolution: ImportedAnchorResolution, hasPositionEvidence: Bool) {
        margins += 1
        if SharedMarginPlacementStatus.isPlaced(resolution) {
            placed += 1
        } else if resolution.isAmbiguous || resolution.evidenceClass == .ambiguous {
            ambiguous += 1
        } else if hasPositionEvidence {
            notFound += 1
        } else {
            noPositionSent += 1
        }
    }

    public var diagnosticValue: String {
        "margins:\(margins) placed:\(placed) ambiguous:\(ambiguous) notFound:\(notFound) noPositionSent:\(noPositionSent)"
    }
}
