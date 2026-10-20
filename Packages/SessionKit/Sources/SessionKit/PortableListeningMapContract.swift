import Foundation

/// Rules a portable Listening Map proposal must meet before it travels in a packet (#480, #88).
///
/// The schema checks shape. These are the meaning rules it can't express: only an eligible scene
/// carries a summary, scenes run forward without overlapping, and a summary, title or eligibility
/// reason is a derivative, never a 10-word quotation of the scene's source text.
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
        case sceneNoteQuotesSource(sceneId: String)

        public var description: String {
            switch self {
            case .eligibleSceneLacksSummary(let id): "eligible scene \(id) lacks a grounded summary"
            case .ineligibleSceneCarriesSummary(let id): "excluded or unknown scene \(id) carries a summary"
            case .sceneEndsBeforeItStarts(let id): "scene \(id) ends before it starts"
            case .sceneOutOfOrder(let id): "scene \(id) starts before an earlier scene"
            case .sceneOverlapsPrevious(let id): "scene \(id) overlaps an earlier scene"
            case .summaryQuotesSource(let id): "scene \(id) summary quotes \(verbatimRunWords) or more words of its source text"
            case .sceneNoteQuotesSource(let id): "scene \(id) title or eligibility reason quotes \(verbatimRunWords) or more words of its source text"
            }
        }
    }

    /// Every rule the proposal breaks, in scene order. `itemText` is the item text the packet embeds, if any.
    public static func violations(
        in proposal: PortableListeningMapProposalArtifact,
        itemText: String? = nil
    ) -> [Violation] {
        violations(in: proposal, sources: SourceTexts(itemText.map { [$0] } ?? []))
    }

    /// Every rule the proposal breaks, checking quotations against each of `sourceTexts`. Each text keeps
    /// its own character offsets, so an item's text and an episode's transcript are passed separately,
    /// never joined: a scene's character range is read in each text it fits.
    ///
    /// `withheldTexts` are source texts the packet doesn't carry, such as the device's transcript of an
    /// episode shared by reference. Any 10-word run of one is a leak wherever the scene sits, so they are
    /// checked whole, never just the scene's range (Codex audit on 555209f).
    public static func violations(
        in proposal: PortableListeningMapProposalArtifact,
        sourceTexts: [String],
        withheldTexts: [String] = []
    ) -> [Violation] {
        violations(in: proposal, sources: SourceTexts(sourceTexts, withheld: withheldTexts))
    }

    private static func violations(in proposal: PortableListeningMapProposalArtifact, sources: SourceTexts) -> [Violation] {
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
            if let start, let end, isPast(start, end) {
                result.append(.sceneEndsBeforeItStarts(sceneId: scene.id))
            }
            if let start {
                if isPast(reachedStart, start) {
                    result.append(.sceneOutOfOrder(sceneId: scene.id))
                } else if isPast(reachedEnd, start) {
                    result.append(.sceneOverlapsPrevious(sceneId: scene.id))
                }
            }
            if let summary = scene.summaryText, !summary.isEmpty, quotesSource(summary, scene: scene, sources: sources) {
                result.append(.summaryQuotesSource(sceneId: scene.id))
            }
            let notes = [scene.title, scene.eligibilityReason, scene.startAnchor.chapterTitle, scene.endAnchor.chapterTitle]
            if notes.contains(where: { $0.map { quotesSource($0, scene: scene, sources: sources) } ?? false }) {
                result.append(.sceneNoteQuotesSource(sceneId: scene.id))
            }
            reachedStart = furthest(reachedStart, start)
            reachedEnd = furthest(reachedEnd, end)
        }
        return result
    }

    /// The proposals a packet can carry: ineligible summaries and quoting titles or eligibility reasons
    /// removed, and any proposal that still breaks a rule left out. A proposal is optional and never
    /// activated automatically, so a bad one must not stop the Margins travelling with it, whether the
    /// sender is this build or Build 29 (#480).
    public static func forSharing(
        _ proposals: [PortableListeningMapProposalArtifact],
        itemText: String? = nil
    ) -> [PortableListeningMapProposalArtifact] {
        forSharing(proposals, sources: SourceTexts(itemText.map { [$0] } ?? []))
    }

    /// `forSharing`, checking quotations against each of `sourceTexts` in its own coordinates and
    /// against the whole of each of `withheldTexts`, as `violations(in:sourceTexts:withheldTexts:)` does.
    public static func forSharing(
        _ proposals: [PortableListeningMapProposalArtifact],
        sourceTexts: [String],
        withheldTexts: [String] = []
    ) -> [PortableListeningMapProposalArtifact] {
        forSharing(proposals, sources: SourceTexts(sourceTexts, withheld: withheldTexts))
    }

    private static func forSharing(
        _ proposals: [PortableListeningMapProposalArtifact],
        sources: SourceTexts
    ) -> [PortableListeningMapProposalArtifact] {
        proposals
            .map { withoutQuotingNotes(withoutIneligibleSummaries($0), sources: sources) }
            .filter { violations(in: $0, sources: sources).isEmpty }
    }

    /// The same proposal without any scene title, anchor chapter title or eligibility reason that quotes
    /// the source. All are optional labels, and the on-device labeller bounds a reason's length but not
    /// what it copies, so a quoting one is dropped and the map kept (Codex audit on 17614c9).
    private static func withoutQuotingNotes(
        _ proposal: PortableListeningMapProposalArtifact,
        sources: SourceTexts
    ) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(
            id: proposal.id,
            schemaVersion: proposal.schemaVersion,
            languageCode: proposal.languageCode,
            createdAt: proposal.createdAt,
            generator: proposal.generator,
            scenes: proposal.scenes.map { scene in
                func kept(_ note: String?) -> String? {
                    note.flatMap { quotesSource($0, scene: scene, sources: sources) ? nil : $0 }
                }
                func kept(_ anchor: PortableAnchorEvidence) -> PortableAnchorEvidence {
                    guard anchor.chapterTitle != nil, kept(anchor.chapterTitle) == nil else { return anchor }
                    return PortableAnchorEvidence(
                        anchorType: anchor.anchorType, startChar: anchor.startChar, endChar: anchor.endChar,
                        exactText: anchor.exactText, prefix: anchor.prefix, suffix: anchor.suffix,
                        mediaTimeMs: anchor.mediaTimeMs, roughPercent: anchor.roughPercent,
                        transcriptSegmentId: anchor.transcriptSegmentId, chapterTitle: nil,
                        machineEvidenceAssetIds: anchor.machineEvidenceAssetIds
                    )
                }
                return PortableListeningMapScene(
                    id: scene.id, order: scene.order, title: kept(scene.title),
                    summaryText: scene.summaryText, summaryAssetId: scene.summaryAssetId,
                    summaryProvenance: scene.summaryProvenance,
                    eligibility: scene.eligibility, eligibilityReason: kept(scene.eligibilityReason),
                    startAnchor: kept(scene.startAnchor), endAnchor: kept(scene.endAnchor)
                )
            }
        )
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

    /// The words an anchor quotes from its source, by the same count `withoutLongAnchorQuotations` applies. An
    /// apostrophe or hyphen splits a word, so "father's" is two.
    public static func quotedWordCount(of anchor: PortableAnchorEvidence) -> Int {
        words([anchor.prefix, anchor.exactText, anchor.suffix].compactMap { $0 }.joined(separator: " ")).count
    }

    /// The same proposal with any scene anchor quotation of `verbatimRunWords` words or more removed.
    /// A packet that shares its item by reference carries none of its text, so a map anchor must not
    /// carry a long quotation of it either (#480). The anchor keeps its times, character offsets and
    /// segment ids, which are what place it; a shorter quotation can't hold a 10-word run and stays.
    public static func withoutLongAnchorQuotations(
        _ proposal: PortableListeningMapProposalArtifact
    ) -> PortableListeningMapProposalArtifact {
        func trimmed(_ anchor: PortableAnchorEvidence) -> PortableAnchorEvidence {
            guard quotedWordCount(of: anchor) >= verbatimRunWords else { return anchor }
            return PortableAnchorEvidence(
                anchorType: anchor.anchorType, startChar: anchor.startChar, endChar: anchor.endChar,
                mediaTimeMs: anchor.mediaTimeMs, roughPercent: anchor.roughPercent,
                transcriptSegmentId: anchor.transcriptSegmentId, chapterTitle: anchor.chapterTitle,
                machineEvidenceAssetIds: anchor.machineEvidenceAssetIds
            )
        }
        return PortableListeningMapProposalArtifact(
            id: proposal.id,
            schemaVersion: proposal.schemaVersion,
            languageCode: proposal.languageCode,
            createdAt: proposal.createdAt,
            generator: proposal.generator,
            scenes: proposal.scenes.map { scene in
                PortableListeningMapScene(
                    id: scene.id, order: scene.order, title: scene.title,
                    summaryText: scene.summaryText, summaryAssetId: scene.summaryAssetId,
                    summaryProvenance: scene.summaryProvenance,
                    eligibility: scene.eligibility, eligibilityReason: scene.eligibilityReason,
                    startAnchor: trimmed(scene.startAnchor), endAnchor: trimmed(scene.endAnchor)
                )
            }
        )
    }

    /// True when `text` repeats `words` consecutive words of `source`, ignoring case and punctuation.
    public static func sharesRun(_ text: String, _ source: String, words length: Int = verbatimRunWords) -> Bool {
        sharesRun(words(text), runs(words(source), length: length), length: length)
    }

    /// Whether a scene's text quotes its source: its anchors' quoted text and context, the scene's span
    /// of each source text (all of that text when the scene's character range doesn't fit it), and the
    /// whole of each withheld text.
    private static func quotesSource(_ text: String, scene: PortableListeningMapScene, sources: SourceTexts) -> Bool {
        let summaryWords = words(text)
        guard summaryWords.count >= verbatimRunWords else { return false }
        // Prefix, quoted text and suffix are one contiguous stretch of source, so a run may cross them.
        let anchorTexts = [scene.startAnchor, scene.endAnchor].map { anchor in
            [anchor.prefix, anchor.exactText, anchor.suffix].compactMap { $0 }.joined(separator: " ")
        }
        if anchorTexts.contains(where: { sharesRun(summaryWords, runs(words($0), length: verbatimRunWords), length: verbatimRunWords) }) {
            return true
        }
        let lower = scene.startAnchor.startChar ?? scene.startAnchor.endChar
        let upper = scene.endAnchor.endChar ?? scene.endAnchor.startChar
        return sources.texts.contains { source in
            if !source.isWithheld, let lower, let upper, 0 <= lower, lower < upper, upper <= source.characters.count {
                let span = String(source.characters[lower..<upper])
                return sharesRun(summaryWords, runs(words(span), length: verbatimRunWords), length: verbatimRunWords)
            }
            return sharesRun(summaryWords, source.allRuns, length: verbatimRunWords)
        }
    }

    /// The source texts a proposal is checked against, each split once per call rather than once per scene.
    private struct SourceTexts {
        let texts: [SourceText]

        init(_ texts: [String], withheld: [String] = []) {
            self.texts = texts.filter { !$0.isEmpty }.map { SourceText($0, isWithheld: false) }
                + withheld.filter { !$0.isEmpty }.map { SourceText($0, isWithheld: true) }
        }
    }

    private final class SourceText {
        let characters: [Character]
        let isWithheld: Bool
        private let text: String
        private(set) lazy var allRuns: Set<String> = runs(words(text), length: verbatimRunWords)

        init(_ text: String, isWithheld: Bool) {
            self.text = text
            self.isWithheld = isWithheld
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

    /// Where an anchor sits in the producing edition. Keep both coordinates so either can reveal an
    /// inverted range or overlap. Rough percentages are hints, never positions.
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

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
