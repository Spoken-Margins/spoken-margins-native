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
            case .sceneOutOfOrder(let id): "scene \(id) starts before an earlier scene"
            case .sceneOverlapsPrevious(let id): "scene \(id) overlaps an earlier scene"
            case .summaryQuotesSource(let id): "scene \(id) summary quotes \(verbatimRunWords) or more words of its source text"
            }
        }
    }

    /// Every rule the proposal breaks, in scene order. `itemText` is the item text the packet embeds, if any.
    public static func violations(
        in proposal: PortableListeningMapProposalArtifact,
        itemText: String? = nil
    ) -> [Violation] {
        let item = itemText.flatMap { $0.isEmpty ? nil : EmbeddedText($0) }
        var result: [Violation] = []
        // The furthest start and end reached so far, carried across scenes with no comparable position so
        // a scene placed only by rough percentages can't hide an overlap between its neighbours.
        var reachedStart = Position(mediaTimeMs: nil, character: nil)
        var reachedEnd = Position(mediaTimeMs: nil, character: nil)
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
            let start = position(scene.startAnchor, isEnd: false)
            let end = position(scene.endAnchor, isEnd: true)
            if let start, let end, let order = compare(start, end), order > 0 {
                result.append(.sceneEndsBeforeItStarts(sceneId: scene.id))
            }
            if let start {
                if isPast(reachedStart, start) {
                    result.append(.sceneOutOfOrder(sceneId: scene.id))
                } else if isPast(reachedEnd, start) {
                    result.append(.sceneOverlapsPrevious(sceneId: scene.id))
                }
            }
            if let summary = scene.summaryText, !summary.isEmpty, quotesSource(summary, scene: scene, item: item) {
                result.append(.summaryQuotesSource(sceneId: scene.id))
            }
            reachedStart = furthest(reachedStart, start)
            reachedEnd = furthest(reachedEnd, end)
        }
        return result
    }

    /// The proposals a packet can carry: ineligible summaries removed, and any proposal that still breaks
    /// a rule left out. A proposal is optional and never activated automatically, so a bad one must not
    /// stop the Margins travelling with it, whether the sender is this build or Build 29 (#480).
    public static func forSharing(
        _ proposals: [PortableListeningMapProposalArtifact],
        itemText: String? = nil
    ) -> [PortableListeningMapProposalArtifact] {
        proposals.map(withoutIneligibleSummaries).filter { violations(in: $0, itemText: itemText).isEmpty }
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
        sharesRun(words(text), runs(words(source), length: length), length: length)
    }

    /// Whether a summary quotes the source text the packet carries for its scene: its anchors' quoted
    /// text and context, and the scene's span of the embedded item text (all of it when the scene has no
    /// character range).
    private static func quotesSource(_ summary: String, scene: PortableListeningMapScene, item: EmbeddedText?) -> Bool {
        let summaryWords = words(summary)
        guard summaryWords.count >= verbatimRunWords else { return false }
        // Prefix, quoted text and suffix are one contiguous stretch of source, so a run may cross them.
        let anchorTexts = [scene.startAnchor, scene.endAnchor].map { anchor in
            [anchor.prefix, anchor.exactText, anchor.suffix].compactMap { $0 }.joined(separator: " ")
        }
        if anchorTexts.contains(where: { sharesRun(summaryWords, runs(words($0), length: verbatimRunWords), length: verbatimRunWords) }) {
            return true
        }
        guard let item else { return false }
        let lower = scene.startAnchor.startChar ?? scene.startAnchor.endChar
        let upper = scene.endAnchor.endChar ?? scene.endAnchor.startChar
        if let lower, let upper, 0 <= lower, lower < upper, upper <= item.characters.count {
            let span = String(item.characters[lower..<upper])
            return sharesRun(summaryWords, runs(words(span), length: verbatimRunWords), length: verbatimRunWords)
        }
        return sharesRun(summaryWords, item.allRuns, length: verbatimRunWords)
    }

    /// Embedded item text, split once per proposal rather than once per scene.
    private final class EmbeddedText {
        let characters: [Character]
        private let text: String
        private(set) lazy var allRuns: Set<String> = runs(words(text), length: verbatimRunWords)

        init(_ text: String) {
            self.text = text
            self.characters = Array(text)
        }
    }

    private static func runs(_ words: [String], length: Int) -> Set<String> {
        guard length > 0, words.count >= length else { return [] }
        return Set((0...(words.count - length)).map { words[$0..<($0 + length)].joined(separator: " ") })
    }

    private static func sharesRun(_ textWords: [String], _ sourceRuns: Set<String>, length: Int) -> Bool {
        guard length > 0, textWords.count >= length, !sourceRuns.isEmpty else { return false }
        return (0...(textWords.count - length)).contains {
            sourceRuns.contains(textWords[$0..<($0 + length)].joined(separator: " "))
        }
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

    /// True when `reached` lies beyond `start` on any position both carry. A prepared text-and-audio map
    /// runs forward on media time and on characters alike, so either going backwards is a violation.
    private static func isPast(_ reached: Position, _ start: Position) -> Bool {
        if let left = reached.mediaTimeMs, let right = start.mediaTimeMs, left > right { return true }
        if let left = reached.character, let right = start.character, left > right { return true }
        return false
    }

    private static func furthest(_ reached: Position, _ next: Position?) -> Position {
        guard let next else { return reached }
        func later(_ lhs: Int?, _ rhs: Int?) -> Int? { [lhs, rhs].compactMap { $0 }.max() }
        return Position(
            mediaTimeMs: later(reached.mediaTimeMs, next.mediaTimeMs),
            character: later(reached.character, next.character)
        )
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
