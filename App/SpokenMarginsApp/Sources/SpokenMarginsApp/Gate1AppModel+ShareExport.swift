import Combine
import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

extension Gate1AppModel {
    func shareAnchorWarning(for interjection: Interjection) -> String? {
        SharedMarginExport.anchorWarning(for: interjection, isNativeAudio: selectedItem.isNativeAudio)
    }

    func exportSharedInterjections(presentsReadySheet: Bool = true) {
        guard !sharingState.isBulkPreparing else {
            sharingState.errorMessage = "Finish or cancel bulk preparation before sharing."
            return
        }
        let (drafts, omission) = SharedMarginTextRequirement.shareable(sharingState.drafts.filter(\.isIncluded), text: \.approvedTranscript)
        guard !drafts.isEmpty else {
            sharingState.errorMessage = omission ?? "Select at least one Margin with reviewed text."
            return
        }
        sharingState.isExporting = true
        sharingState.errorMessage = nil
        var prepared: PreparedSpokenMarginsPackage?
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: selectedItem.id)
            let itemIdentity = sharedItemIdentity(for: item, drafts: drafts)
            let itemTransport = SharedMarginExport.itemTransport(item: item, identity: itemIdentity, isAppAuthored: sharingState.isAppAuthoredItem, confirmsPrivateRights: sharingState.confirmsPrivateSharingRights)
            var machineEvidence: [ReviewedMachineEvidenceAsset] = []
            var selections: [ReviewedInterjectionSelection] = []

            for (index, draft) in drafts.enumerated() {
                let revisionID = "share-revision-\(UUID().uuidString.lowercased())"
                let cleanedPath = draft.representationChoice == .cleaned ? draft.cleanedAudioURL?.path : nil
                let revision = InterjectionShareRevision(
                    id: revisionID,
                    interjectionId: draft.interjection.id,
                    itemId: draft.interjection.itemId,
                    sessionId: draft.interjection.sessionId,
                    createdAt: Date(),
                    approvedTranscript: draft.approvedTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
                    cleanedAudioPath: cleanedPath,
                    cleanedAudioDurationMs: draft.representationChoice == .cleaned ? draft.cleanedAudioDurationMs : nil,
                    decisions: draft.cleanup?.decisions ?? [],
                    anchorBefore: draft.anchorBefore,
                    anchorAfter: draft.anchorAfter,
                    status: .senderApproved
                )
                try store.saveInterjectionShareRevision(revision)

                let evidence = sharingState.includesAcousticEvidence
                    ? (draft.interjection.podcastAnchorEvidence ?? []).filter { FileManager.default.fileExists(atPath: $0.localPath) }
                    : []
                machineEvidence.append(contentsOf: evidence.map {
                    ReviewedMachineEvidenceAsset(
                        id: $0.id,
                        path: "assets/evidence/\($0.id).shazamsignature",
                        sourceURL: URL(fileURLWithPath: $0.localPath),
                        durationMs: $0.durationMs,
                        anchorOffsetMs: $0.anchorOffsetMs,
                        provenance: ($0.provenance ?? .exactLocalPlaybackEdition).rawValue
                    )
                })
                let anchor = SharedMarginExport.anchor(
                    for: draft.interjection,
                    item: item,
                    isNativeAudio: selectedItem.isNativeAudio,
                    mediaChapters: selectedItem.mediaChapters,
                    machineEvidenceAssetIds: evidence.map(\.id)
                )
                let representation: ReviewedRepresentationSelection
                switch draft.representationChoice {
                case .original:
                    guard let url = draft.interjection.audioPath.flatMap(resolvedInterjectionAudioURL(for:)),
                          let duration = audioDurationMs(at: url) else {
                        throw SessionKitError.persistenceFailed("selected_original_margin_audio_unavailable")
                    }
                    representation = .originalAudio(sourceURL: url, durationMs: duration)
                case .cleaned:
                    guard let url = draft.cleanedAudioURL else {
                        throw SessionKitError.persistenceFailed("selected_cleaned_margin_audio_unavailable")
                    }
                    representation = .cleanedAudio(sourceURL: url)
                case .textOnly:
                    representation = .textOnly
                }
                selections.append(ReviewedInterjectionSelection(
                    packageScopedId: String(format: "margin-%04d", index + 1),
                    revision: revision,
                    anchor: anchor,
                    representation: representation, replyTo: draft.interjection.replyTo
                ))
            }

            let mapProposals = SharedMarginExport.mapProposals(
                try store.loadPortableListeningMapProposals(itemId: item.id),
                currentProposalID: try store.loadResolvedListeningMapProjection(itemId: item.id)?.proposalId
            )
            let fingerprintSpines = sharingState.includesAcousticEvidence
                ? try store.loadEditionFingerprintSpine(itemId: item.id).map { [$0] } ?? []
                : []
            let phraseSketches = try store.loadTranscriptPhraseSketch(itemId: item.id).map { [$0] } ?? []
            if let spine = fingerprintSpines.first {
                let directory = try episodeMapDirectory(itemId: item.id)
                let existingEvidenceIDs = Set(machineEvidence.map(\.id))
                for landmark in spine.landmarks where !existingEvidenceIDs.contains(landmark.signatureAssetId) {
                    let url = directory.appending(path: "\(landmark.signatureAssetId).shazamsignature")
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    machineEvidence.append(ReviewedMachineEvidenceAsset(
                        id: landmark.signatureAssetId,
                        path: "assets/evidence/\(landmark.signatureAssetId).shazamsignature",
                        sourceURL: url,
                        durationMs: max(1, landmark.sourceMediaEndMs - landmark.sourceMediaStartMs),
                        anchorOffsetMs: 0,
                        provenance: landmark.provenance.rawValue
                    ))
                }
            }

            let packageID = "package-\(UUID().uuidString.lowercased())"
            let package = try SpokenMarginsPackageBuilder.prepare(
                packageId: packageID,
                createdAt: Date(),
                item: itemIdentity,
                itemTransportSelection: itemTransport,
                selections: selections,
                mapProposals: mapProposals, localSourceTexts: [item.text, store.loadTranscriptTimeline(itemId: item.id)?.timeline.segments.map(\.text).joined(separator: " ")].compactMap { $0 },
                fingerprintSpines: fingerprintSpines,
                phraseSketches: phraseSketches,
                machineEvidence: machineEvidence,
                senderDisplayLabel: sharingState.senderDisplayLabel.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
            prepared = package
            let directory = try applicationSupportDirectory()
                .appending(path: "SpokenMargins/SharedPackages", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: "\(SharedMarginExport.fileName(item.title))-\(packageID.suffix(8)).spokenmargins")
            let writtenManifest = try SpokenMarginsPackageArchive.write(package, to: destination); try? SpokenMarginsPackageExportRecord.recordExport(manifest: writtenManifest, selections: selections, repository: store) // replies link back through the recorded identity; the share still succeeds without it (#473)
            listeningSignals.export(itemId: item.id, packetId: packageID, marginCount: drafts.count, packetURL: destination)
            UserDefaults.standard.set(sharingState.senderDisplayLabel, forKey: "sharingSenderDisplayLabel")
            sharedSpokenMarginsPackageURL = destination
            sharingState.isExporting = false
            if presentsReadySheet {
                isSharingInterjectionsPresented = false
                isSharedSpokenMarginsPackagePresented = true
            }
            diagnostics["lastSharedPackage"] = "margins=\(drafts.count);evidence=\(machineEvidence.count);map=\(mapProposals.isEmpty ? "preparing_or_unavailable" : "included")"
            if let omission { reportWarning(omission) }
        } catch {
            sharingState.isExporting = false
            let failure = SharedPacketExportFailure(error: error, prepared: prepared)
            sharingState.errorMessage = failure.listenerMessage
            diagnostics["lastSharedPackageFailure"] = failure.diagnostic
        }
    }

    private func sharedItemIdentity(
        for item: Item,
        drafts: [ShareInterjectionDraft]
    ) -> SharedItemIdentity {
        SharedItemIdentityBuilder.exportIdentity(
            for: item,
            draftEditionDigests: drafts.map(\.interjection.sourceExactEditionSHA256),
            localAudioDigest: localAudiobookDigest(for: item)
        )
    }

    /// Mirrors the link the packet builder keeps, so the share screen never promises a private feed link (#168).
    func secureSharedItemURL<Fields: LibraryItemFields>(for item: Fields) -> String? {
        ShareableLinkPolicy.shareableLink(
            item.externalReference.flatMap(SharedItemIdentityBuilder.normalizedSharingURL)
                ?? item.media?.url.flatMap(SharedItemIdentityBuilder.normalizedSharingURL)
        )
    }

    func sharedItemType<Fields: LibraryItemFields>(for item: Fields) -> SharedItemType {
        SharedPacketItemMatcher.itemType(for: item)
    }

    private func audioDurationMs(at url: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        return max(1, Int((Double(file.length) / file.processingFormat.sampleRate * 1_000).rounded()))
    }
}
