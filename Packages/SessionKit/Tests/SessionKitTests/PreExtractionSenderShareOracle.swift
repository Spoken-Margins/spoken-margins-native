import Foundation
import SessionKit
import SessionKitSharing

// Test-only historical oracle for #977 / PR #1166. The five marked declarations
// are verbatim from cc555ce9e873d58ebc82d9e1313d41b5e5e74fac
// (the PR's merge base), App/SpokenMarginsApp/Sources/SpokenMarginsApp/Gate1AppModel.swift.
// The state adapters and forwarding methods below are outside those declarations.
// Keep this oracle until it has been committed and reviewed; remove it only in a
// separate commit, preserving the packet golden checks in SharedMarginExportTests.
struct PreExtractionSenderShareOracle {
    struct SelectedItem {
        let isNativeAudio: Bool
        let mediaChapters: [MediaTimelineChapter]
    }

    struct SharingState {
        let isAppAuthoredItem: Bool
        let confirmsPrivateSharingRights: Bool
    }

    let selectedItem: SelectedItem
    let sharingState: SharingState

    func anchorWarning(for interjection: Interjection) -> String? {
        shareAnchorWarning(for: interjection)
    }

    func itemTransport(item: Item, identity: SharedItemIdentity) -> ReviewedItemTransportSelection {
        reviewedItemTransport(for: item, identity: identity)
    }

    func anchor(for interjection: Interjection, item: Item, machineEvidenceAssetIds: [String]) -> PortableAnchorEvidence {
        portableAnchor(for: interjection, item: item, machineEvidenceAssetIds: machineEvidenceAssetIds)
    }

    func mapProposals(_ proposals: [PortableListeningMapProposalArtifact]) -> [PortableListeningMapProposalArtifact] {
        Self.mapProposalsForMarginExport(proposals)
    }

    func fileName(_ value: String) -> String {
        safeShareFilename(value)
    }

    // BEGIN VERBATIM shareAnchorWarning
    private func shareAnchorWarning(for interjection: Interjection) -> String? {
        guard selectedItem.isNativeAudio && (interjection.podcastAnchorEvidence ?? []).isEmpty else {
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
    // END VERBATIM shareAnchorWarning

    // BEGIN VERBATIM mapProposalsForMarginExport
    static func mapProposalsForMarginExport(_ proposals: [PortableListeningMapProposalArtifact]) -> [PortableListeningMapProposalArtifact] {
        // The app exports reviewed Margins and textual map proposals, not the
        // local/imported Skim audio. Do not reference unselected voice assets.
        proposals.map { proposal in
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
    // END VERBATIM mapProposalsForMarginExport

    // BEGIN VERBATIM reviewedItemTransport
    private func reviewedItemTransport(
        for item: Item,
        identity: SharedItemIdentity
    ) -> ReviewedItemTransportSelection {
        if identity.canonicalURL != nil {
            return .reference
        }
        let text = item.text ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sharingState.isAppAuthoredItem || sharingState.confirmsPrivateSharingRights {
            return .embeddedText(
                text: text,
                originalMediaType: identity.itemType.rawValue,
                rightsBasis: sharingState.isAppAuthoredItem ? .appAuthored : .senderConfirmedPrivateRights
            )
        }
        return .recipientSupplied
    }
    // END VERBATIM reviewedItemTransport

    // BEGIN VERBATIM portableAnchor
    private func portableAnchor(
        for interjection: Interjection,
        item: Item,
        machineEvidenceAssetIds: [String]
    ) -> PortableAnchorEvidence {
        let exactText: String?
        if !selectedItem.isNativeAudio,
           interjection.anchor.endChar > interjection.anchor.startChar,
           interjection.anchor.endChar <= (item.text ?? "").count {
            let text = item.text ?? ""
            let lower = text.index(text.startIndex, offsetBy: interjection.anchor.startChar)
            let upper = text.index(text.startIndex, offsetBy: interjection.anchor.endChar)
            exactText = String(text[lower..<upper])
        } else {
            exactText = nil
        }
        let chapter = selectedItem.mediaChapters.last {
            $0.startMs <= (interjection.anchor.mediaTimeMs ?? -1)
        }?.title
        return PortableAnchorEvidence(
            anchorType: interjection.anchor.anchorType,
            startChar: selectedItem.isNativeAudio ? nil : interjection.anchor.startChar,
            endChar: selectedItem.isNativeAudio ? nil : interjection.anchor.endChar,
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
    // END VERBATIM portableAnchor

    // BEGIN VERBATIM safeShareFilename
    private func safeShareFilename(_ value: String) -> String {
        let normalized = value.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((normalized.isEmpty ? "Spoken-Margins" : normalized).prefix(80))
    }
    // END VERBATIM safeShareFilename

}
