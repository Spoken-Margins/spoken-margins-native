import Foundation

/// Rules a portable Listening Map proposal must meet before it travels in a packet (#480, #88).
///
/// The schema checks shape. These are the meaning rules it can't express: only an eligible scene
/// carries a summary, scenes run forward without overlapping, and a summary is a derivative, never a
/// 10-word quotation of the source text the packet carries for its scene.
public enum PortableListeningMapContract {
    /// A summary that repeats this many consecutive source words is quoting, not summarising.
    /// The on-device labeller refuses the same run length (LocalListeningMapOutputValidator).
    public static let verbatimRunWords = 10

    public enum Violation: Equatable, Sendable, CustomStringConvertible {
        case eligibleSceneLacksSummary(sceneId: String)
        case ineligibleSceneCarriesSummary(sceneId: String)
        case sceneEndsBeforeItStarts(sceneId: String)
        case sceneOutOfOrder(sceneId: String)
        case sceneOverlapsPrevious(sceneId: String)
        case summaryQuotesSource(sceneId: String)

        public var description: String {
            switch self {
            case .eligibleSceneLacksSummary(let id): "eligible scene \(id) lacks a grounded summary"
            case .ineligibleSceneCarriesSummary(let id): "excluded or unknown scene \(id) carries a summary"
            case .sceneEndsBeforeItStarts(let id): "scene \(id) ends before it starts"
            case .sceneOutOfOrder(let id): "scene \(id) starts before the previous scene"
            case .sceneOverlapsPrevious(let id): "scene \(id) overlaps the previous scene"
            case .summaryQuotesSource(let id): "scene \(id) summary quotes \(verbatimRunWords) or more words of its source text"
            }
        }
    }

    /// Every rule the proposal breaks, in scene order. `itemText` is the item text the packet embeds, if any.
    public static func violations(
        in proposal: PortableListeningMapProposalArtifact,
        itemText: String? = nil
    ) -> [Violation] {
        var result: [Violation] = []
        var previous: PortableListeningMapScene?
        for scene in proposal.scenes {
            let hasSummary = scene.summaryText?.isEmpty == false || scene.summaryAssetId != nil
            switch scene.eligibility {
            case .eligible:
                if scene.summaryText?.isEmpty != false || scene.summaryProvenance == nil {
                    result.append(.eligibleSceneLacksSummary(sceneId: scene.id))
                }
            case .excluded, .unknown:
                if hasSummary { result.append(.ineligibleSceneCarriesSummary(sceneId: scene.id)) }
            }
            if let start = position(scene.startAnchor, isEnd: false),
               let end = position(scene.endAnchor, isEnd: true),
               let order = compare(start, end), order > 0 {
                result.append(.sceneEndsBeforeItStarts(sceneId: scene.id))
            }
            if let previous {
                let previousStart = position(previous.startAnchor, isEnd: false)
                let previousEnd = position(previous.endAnchor, isEnd: true)
                let start = position(scene.startAnchor, isEnd: false)
                if let previousStart, let start, let order = compare(previousStart, start), order > 0 {
                    result.append(.sceneOutOfOrder(sceneId: scene.id))
                } else if let previousEnd, let start, let order = compare(previousEnd, start), order > 0 {
                    result.append(.sceneOverlapsPrevious(sceneId: scene.id))
                }
            }
            if let summary = scene.summaryText, !summary.isEmpty,
               sourceTexts(for: scene, itemText: itemText).contains(where: { sharesRun(summary, $0) }) {
                result.append(.summaryQuotesSource(sceneId: scene.id))
            }
            previous = scene
        }
        return result
    }

    /// The same proposal with summaries removed from excluded and unknown scenes. Build 29 exports the
    /// on-device labeller's description for every scene, so its packets carry summaries on scenes the
    /// contract says must not be summarised; this keeps their map without keeping those summaries.
    public static func withoutIneligibleSummaries(
        _ proposal: PortableListeningMapProposalArtifact
    ) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(
            id: proposal.id,
            schemaVersion: proposal.schemaVersion,
            languageCode: proposal.languageCode,
            createdAt: proposal.createdAt,
            generator: proposal.generator,
            scenes: proposal.scenes.map { scene in
                guard scene.eligibility != .eligible else { return scene }
                return PortableListeningMapScene(
                    id: scene.id, order: scene.order, title: scene.title,
                    summaryText: nil, summaryAssetId: nil, summaryProvenance: nil,
                    eligibility: scene.eligibility, eligibilityReason: scene.eligibilityReason,
                    startAnchor: scene.startAnchor, endAnchor: scene.endAnchor
                )
            }
        )
    }

    /// True when `text` repeats `words` consecutive words of `source`, ignoring case and punctuation.
    public static func sharesRun(_ text: String, _ source: String, words length: Int = verbatimRunWords) -> Bool {
        let textWords = words(text)
        let sourceWords = words(source)
        guard length > 0, textWords.count >= length, sourceWords.count >= length else { return false }
        let sourceRuns = Set((0...(sourceWords.count - length)).map {
            sourceWords[$0..<($0 + length)].joined(separator: " ")
        })
        return (0...(textWords.count - length)).contains {
            sourceRuns.contains(textWords[$0..<($0 + length)].joined(separator: " "))
        }
    }

    /// The source text the packet carries for a scene: its anchors' quoted text and context, and the
    /// scene's span of the embedded item text (all of it when the scene has no character range).
    static func sourceTexts(for scene: PortableListeningMapScene, itemText: String?) -> [String] {
        var texts = [scene.startAnchor, scene.endAnchor].flatMap { anchor in
            [anchor.exactText, anchor.prefix, anchor.suffix].compactMap { $0 }
        }
        if let itemText, !itemText.isEmpty {
            let lower = scene.startAnchor.startChar ?? scene.startAnchor.endChar
            let upper = scene.endAnchor.endChar ?? scene.endAnchor.startChar
            if let lower, let upper, 0 <= lower, lower < upper, upper <= itemText.count {
                let start = itemText.index(itemText.startIndex, offsetBy: lower)
                let end = itemText.index(itemText.startIndex, offsetBy: upper)
                texts.append(String(itemText[start..<end]))
            } else {
                texts.append(itemText)
            }
        }
        return texts
    }

    private struct Position {
        let mediaTimeMs: Int?
        let character: Int?
    }

    /// Where an anchor sits in the producing edition. Media time wins; character offsets are used when
    /// either side has no media time. Rough percentages are hints, never positions.
    private static func position(_ anchor: PortableAnchorEvidence, isEnd: Bool) -> Position? {
        let character = isEnd ? (anchor.endChar ?? anchor.startChar) : (anchor.startChar ?? anchor.endChar)
        guard anchor.mediaTimeMs != nil || character != nil else { return nil }
        return Position(mediaTimeMs: anchor.mediaTimeMs, character: character)
    }

    private static func compare(_ lhs: Position, _ rhs: Position) -> Int? {
        if let left = lhs.mediaTimeMs, let right = rhs.mediaTimeMs { return left < right ? -1 : (left == right ? 0 : 1) }
        if let left = lhs.character, let right = rhs.character { return left < right ? -1 : (left == right ? 0 : 1) }
        return nil
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
