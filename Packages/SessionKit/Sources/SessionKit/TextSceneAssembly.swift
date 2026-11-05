import Foundation

/// The pure steps that turn an article's or PDF's scene drafts and the model's labels into the portable proposal
/// Skim reads (#3450). It is the text twin of `EpisodeMapAssembly`: the same `PortableListeningMapScene`, the same
/// `ListeningMapSummaryValidator.storedSummary` rule, placed by character instead of by media time.
public enum TextSceneAssembly {
    /// The proposal's `generator`, which a sender exports and a recipient reads.
    public static let generator = "on-device-text-scene-map.v1"
    /// How many characters of the scene's own words an anchor quotes, so a copy of the text can place it again.
    public static let quotedCharacters = 80
    public static let contextCharacters = 40

    public static func proposalId(safeItemComponent: String) -> String {
        "text-scene-map-\(safeItemComponent)"
    }

    /// True for a proposal this device's model wrote from the listener's own text.
    public static func isModelProposal(_ proposal: PortableListeningMapProposalArtifact) -> Bool {
        proposal.generator == generator
    }

    /// One scene: its place in the text from the draft, its words from the label the model produced for it (nil when
    /// none was accepted). Only a scene the model called editorial keeps a summary, as on a podcast.
    public static func scene(
        draft: TextSceneDraft,
        label: ListeningMapSummaryValidator.SceneLabel?,
        characters: [Character]
    ) -> PortableListeningMapScene {
        let stored = ListeningMapSummaryValidator.storedSummary(for: label)
        let title = label?.title ?? draft.fallbackTitle
        return PortableListeningMapScene(
            id: draft.id,
            order: draft.order,
            title: title,
            summaryText: stored.text,
            summaryAssetId: nil,
            summaryProvenance: stored.provenance,
            eligibility: label?.eligibility ?? .unknown,
            eligibilityReason: label?.eligibilityReason,
            startAnchor: startAnchor(draft, characters: characters, title: title),
            endAnchor: endAnchor(draft, characters: characters, title: title)
        )
    }

    public static func proposal(
        safeItemComponent: String, scenes: [PortableListeningMapScene], createdAt: Date = Date()
    ) -> PortableListeningMapProposalArtifact {
        PortableListeningMapProposalArtifact(
            id: proposalId(safeItemComponent: safeItemComponent),
            createdAt: createdAt,
            generator: generator,
            scenes: scenes
        )
    }

    /// The scene's first words, with the text before them, so the scene is found again in another copy of the text.
    static func startAnchor(_ draft: TextSceneDraft, characters: [Character], title: String) -> PortableAnchorEvidence {
        let start = clamped(draft.startChar, characters.count)
        let quoteEnd = min(characters.count, min(draft.endChar, start + quotedCharacters))
        return PortableAnchorEvidence(
            anchorType: .text,
            startChar: start,
            endChar: quoteEnd,
            exactText: String(characters[start..<quoteEnd]),
            prefix: start > 0 ? String(characters[max(0, start - contextCharacters)..<start]) : nil,
            chapterTitle: title
        )
    }

    /// The scene's last words, with the text after them.
    static func endAnchor(_ draft: TextSceneDraft, characters: [Character], title: String) -> PortableAnchorEvidence {
        let end = clamped(draft.endChar, characters.count)
        let quoteStart = max(draft.startChar, end - quotedCharacters)
        return PortableAnchorEvidence(
            anchorType: .text,
            startChar: quoteStart,
            endChar: end,
            exactText: String(characters[clamped(quoteStart, characters.count)..<end]),
            suffix: end < characters.count ? String(characters[end..<min(characters.count, end + contextCharacters)]) : nil,
            chapterTitle: title
        )
    }

    private static func clamped(_ value: Int, _ count: Int) -> Int { min(max(0, value), count) }

    /// The line a finished run shows.
    public static func completionStatus(scenes: [PortableListeningMapScene]) -> String {
        let summarised = scenes.filter { $0.summaryText?.isEmpty == false }.count
        return summarised == 0
            ? "Ready with chapters"
            : "Ready with scene summaries (\(summarised) of \(scenes.count) scenes)"
    }

    // MARK: what leaves the device

    /// The proposal as it may leave the device: for one this device's model wrote, scene starts and ends only. The
    /// model's titles, summaries, reasons and chapter titles stay on the phone until the source is known to be public
    /// (#3449); the scene positions, which are the listener's own text, still travel. Any other proposal is returned
    /// as it was.
    public static func withoutModelWords(_ proposal: PortableListeningMapProposalArtifact) -> PortableListeningMapProposalArtifact {
        guard isModelProposal(proposal) else { return proposal }
        func plain(_ anchor: PortableAnchorEvidence) -> PortableAnchorEvidence {
            PortableAnchorEvidence(
                anchorType: anchor.anchorType, startChar: anchor.startChar, endChar: anchor.endChar,
                exactText: anchor.exactText, prefix: anchor.prefix, suffix: anchor.suffix,
                mediaTimeMs: anchor.mediaTimeMs, roughPercent: anchor.roughPercent,
                transcriptSegmentId: anchor.transcriptSegmentId, chapterTitle: nil,
                machineEvidenceAssetIds: anchor.machineEvidenceAssetIds
            )
        }
        return PortableListeningMapProposalArtifact(
            id: proposal.id, schemaVersion: proposal.schemaVersion, languageCode: proposal.languageCode,
            createdAt: proposal.createdAt, generator: proposal.generator,
            scenes: proposal.scenes.map { scene in
                PortableListeningMapScene(
                    id: scene.id, order: scene.order, title: nil, summaryText: nil, summaryAssetId: nil,
                    summaryProvenance: nil, eligibility: .unknown, eligibilityReason: nil,
                    startAnchor: plain(scene.startAnchor), endAnchor: plain(scene.endAnchor)
                )
            }
        )
    }
}
