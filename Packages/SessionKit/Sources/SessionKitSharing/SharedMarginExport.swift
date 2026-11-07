import Foundation
import SessionKit

/// Pure sender rules for reviewed Margin packets.
public enum SharedMarginExport {
    public static func anchorWarning(for interjection: Interjection, isNativeAudio: Bool) -> String? {
        guard isNativeAudio && (interjection.podcastAnchorEvidence ?? []).isEmpty else {
            return nil
        }
        switch interjection.podcastAnchorEvidenceCaptureStatus {
        case .pendingPostResumeSample:
            return "High-reliability evidence is capturing. Continue podcast playback for about 12 seconds before sharing this Margin."
        case .pendingExactLocalCapture:
            return "High-reliability evidence is being prepared from the podcast edition currently playing."
        case .ready:
            return nil
        case .unavailable, nil:
            return "High-reliability anchor evidence was unavailable at capture. Transcript context may still resolve this Margin; a timestamp alone will not be treated as verified."
        }
    }

    /// The one map a packet carries: the one the item plays (its resolved projection's), else the newest stored.
    /// Every stored proposal used to travel, one manifest descriptor each, and old Listening Edition revisions piled
    /// up in the store (#2118).
    ///
    /// `item` is the source the map describes: its model-written scene titles and summaries leave the device only
    /// when it carries a public-source mark (#3449, `MapTextDisclosure`). There is no overload without it.
    public static func mapProposals(
        _ proposals: [PortableListeningMapProposalArtifact], currentProposalID: String?, for item: Item
    ) -> [PortableListeningMapProposalArtifact] {
        mapProposals(currentProposal(in: proposals, currentProposalID: currentProposalID).map { [$0] } ?? [], for: item)
    }

    /// How many scenes of the map a packet would carry stay on this phone because the source is not marked public, for the
    /// share review's note (#3449). Counts exactly what `mapProposals(_:currentProposalID:for:)` strips.
    public static func withheldSceneCount(
        _ proposals: [PortableListeningMapProposalArtifact], currentProposalID: String?, for item: Item
    ) -> Int {
        MapTextDisclosure.withheldSceneCount(currentProposal(in: proposals, currentProposalID: currentProposalID).map { [$0] } ?? [], for: item)
    }

    private static func currentProposal(in proposals: [PortableListeningMapProposalArtifact], currentProposalID: String?) -> PortableListeningMapProposalArtifact? {
        proposals.first { $0.id == currentProposalID }
            ?? proposals.max { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public static func mapProposals(_ proposals: [PortableListeningMapProposalArtifact], for item: Item) -> [PortableListeningMapProposalArtifact] {
        // The app exports reviewed Margins and textual map proposals, not the
        // local/imported Skim audio. Do not reference unselected voice assets.
        MapTextDisclosure.proposals(proposals, for: item).map { proposal in
            PortableListeningMapProposalArtifact(
                id: proposal.id, schemaVersion: proposal.schemaVersion,
                languageCode: proposal.languageCode, createdAt: proposal.createdAt,
                generator: proposal.generator,
                scenes: proposal.scenes.map { scene in
                    PortableListeningMapScene(
                        id: scene.id, order: scene.order, title: scene.title,
                        summaryText: scene.summaryText, summaryAssetId: nil,
                        summaryProvenance: scene.summaryProvenance,
                        eligibility: scene.eligibility, eligibilityReason: scene.eligibilityReason,
                        startAnchor: scene.startAnchor, endAnchor: scene.endAnchor
                    )
                }
            )
        }
    }

    public static func itemTransport(
        item: Item,
        identity: SharedItemIdentity,
        isAppAuthored: Bool,
        confirmsPrivateRights: Bool
    ) -> ReviewedItemTransportSelection {
        if identity.canonicalURL != nil {
            return .reference
        }
        let text = item.text ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isAppAuthored || confirmsPrivateRights {
            return .embeddedText(
                text: text,
                originalMediaType: identity.itemType.rawValue,
                rightsBasis: isAppAuthored ? .appAuthored : .senderConfirmedPrivateRights
            )
        }
        return .recipientSupplied
    }

    public static func anchor(
        for interjection: Interjection,
        item: Item,
        isNativeAudio: Bool,
        mediaChapters: [MediaTimelineChapter],
        machineEvidenceAssetIds: [String]
    ) -> PortableAnchorEvidence {
        let exactText: String?
        if !isNativeAudio,
           interjection.anchor.endChar > interjection.anchor.startChar,
           interjection.anchor.endChar <= (item.text ?? "").count {
            let text = item.text ?? ""
            let lower = text.index(text.startIndex, offsetBy: interjection.anchor.startChar)
            let upper = text.index(text.startIndex, offsetBy: interjection.anchor.endChar)
            exactText = String(text[lower..<upper])
        } else {
            exactText = nil
        }
        let chapter = mediaChapters.last {
            $0.startMs <= (interjection.anchor.mediaTimeMs ?? -1)
        }?.title
        return PortableAnchorEvidence(
            anchorType: interjection.anchor.anchorType,
            startChar: isNativeAudio ? nil : interjection.anchor.startChar,
            endChar: isNativeAudio ? nil : interjection.anchor.endChar,
            exactText: exactText,
            prefix: interjection.anchor.anchorBefore,
            suffix: interjection.anchor.anchorAfter,
            mediaTimeMs: interjection.anchor.mediaTimeMs,
            roughPercent: interjection.roughPercent,
            transcriptSegmentId: interjection.anchor.transcriptSegmentId,
            chapterTitle: chapter,
            machineEvidenceAssetIds: machineEvidenceAssetIds
        )
    }

    public static func fileName(_ value: String) -> String {
        let normalized = value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((normalized.isEmpty ? "Spoken-Margins" : normalized).prefix(80))
    }
}
