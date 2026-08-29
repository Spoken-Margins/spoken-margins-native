import AVFoundation
import SessionKit
import SessionKitAudio
import SessionKitSharing
import SwiftUI
import UIKit

enum ShareMarginRepresentationChoice: String, CaseIterable, Identifiable {
    case original
    case cleaned
    case textOnly

    var id: String { rawValue }
}

struct ShareInterjectionDraft: Identifiable {
    var id: String { interjection.id }
    var interjection: Interjection
    var isIncluded = true
    var approvedTranscript: String
    var cleanup: InterjectionCleanupResult?
    var cleanedAudioURL: URL?
    var cleanedAudioDurationMs: Int?
    var representationChoice: ShareMarginRepresentationChoice
    var warning: String?
    var anchorBefore: String
    var anchorAfter: String
}

struct InterjectionSharingState {
    var drafts: [ShareInterjectionDraft] = []
    var senderDisplayLabel = UserDefaults.standard.string(forKey: "sharingSenderDisplayLabel") ?? ""
    var includesAcousticEvidence = true
    var isPreparing = false
    var isExporting = false
    var errorMessage: String?
}

struct SpokenMarginsPackageImportReview: Identifiable {
    let id = UUID()
    let packageURL: URL
    let extractionDirectory: URL
    let contents: VerifiedSpokenMarginsPackage
    let matchingItemId: String?

    var marginCount: Int {
        contents.commentaryLayers.reduce(0) { $0 + $1.interjections.count }
    }

    var senderLabel: String {
        contents.manifest.senderDisplayLabel?.nilIfEmpty ?? "Unsigned sender"
    }
}

struct ImportedCommentaryPrompt: Identifiable {
    var id: String { interjection.id }
    let layer: ImportedCommentaryLayer
    let interjection: ImportedCommentaryInterjection
    let index: Int
    let count: Int

    var senderLabel: String { layer.displayLabel?.nilIfEmpty ?? "Unsigned sender" }
}

struct SpokenMarginsPackageImportView: View {
    @EnvironmentObject private var model: Gate1AppModel
    let review: SpokenMarginsPackageImportReview

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ProductPanel {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(review.contents.manifest.source.title)
                                .font(.title3.weight(.semibold))
                            Text(review.senderLabel)
                                .font(.headline)
                            Text("Integrity checked · Sender identity is not verified")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                            Text("\(review.marginCount) shared Margin\(review.marginCount == 1 ? "" : "s")")
                        }
                    }

                    Text(review.matchingItemId == nil
                        ? "Spoken Margins will add this podcast, download the recipient edition, and then resolve the shared anchors. Nothing will play automatically."
                        : "Spoken Margins found this item in your library. It will use the downloaded recipient edition to resolve shared anchors. Nothing will play automatically.")
                        .font(.callout)

                    DisclosureGroup("Package contents") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Voice files: \(review.contents.manifest.assets.filter { [SpokenMarginsAssetRole.originalVoice, SpokenMarginsAssetRole.cleanedVoice].contains($0.role) }.count)")
                            Text("Acoustic anchor signatures: \(review.contents.manifest.assets.filter { $0.role == SpokenMarginsAssetRole.acousticSignature }.count)")
                            Text("Listening Map proposals: \(review.contents.listeningMapProposals.count) (stored as proposals; not activated)")
                            Text("Podcast audio: not included")
                        }
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    }

                    if let error = model.spokenMarginsPackageImportError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(AppColors.dangerText)
                    }

                    Button("Import & Resolve Margins") {
                        model.confirmSpokenMarginsPackageImport()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isImportingSpokenMarginsPackage)

                    Button("Cancel", role: .cancel) {
                        model.cancelSpokenMarginsPackageImport()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.isImportingSpokenMarginsPackage)

                    if model.isImportingSpokenMarginsPackage {
                        ProgressView("Importing without autoplay…")
                    }
                }
                .padding(20)
            }
            .navigationTitle("Import Shared Margins")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(model.isImportingSpokenMarginsPackage)
    }
}

struct InterjectionSharingView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.sharingState.isPreparing {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Preparing private review copies…")
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ProductPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Review what you are sending")
                                        .font(.headline)
                                    Text("The package includes only selected Margins, the reviewed text and voice version shown below, bounded anchor context, source identity, and optional acoustic signatures. It never includes the podcast audio, raw diagnostics, or unrelated sessions.")
                                        .font(.callout)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                            }

                            TextField("Your display label (optional)", text: $model.sharingState.senderDisplayLabel)
                                .textFieldStyle(.roundedBorder)

                            Toggle("Include high-reliability podcast anchor evidence", isOn: $model.sharingState.includesAcousticEvidence)
                            Text("Recommended. These ShazamKit signatures help a recipient find the same spoken passage when their download contains different ads. They are not playable podcast audio.")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)

                            ForEach(model.sharingState.drafts) { draft in
                                shareDraftCard(draft)
                            }

                            if let error = model.sharingState.errorMessage {
                                Text(error)
                                    .font(.callout)
                                    .foregroundStyle(AppColors.dangerText)
                            }

                            Button(action: model.exportSharedInterjections) {
                                if model.sharingState.isExporting {
                                    ProgressView().frame(maxWidth: .infinity)
                                } else {
                                    Text("Share Reviewed Margins").frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(
                                model.sharingState.drafts.allSatisfy { !$0.isIncluded }
                                    || model.sharingState.isExporting
                            )
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Share Margins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func shareDraftCard(_ draft: ShareInterjectionDraft) -> some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Include this Margin",
                    isOn: Binding(
                        get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.isIncluded ?? false },
                        set: { model.setShareDraftIncluded(draft.id, included: $0) }
                    )
                )
                .font(.headline)

                Text("Reviewed transcript")
                    .font(.caption.weight(.semibold))
                TextEditor(text: Binding(
                    get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.approvedTranscript ?? "" },
                    set: { model.setShareDraftTranscript(draft.id, transcript: $0) }
                ))
                .frame(minHeight: 90)
                .padding(8)
                .background(AppColors.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(!draft.isIncluded)

                Picker(
                    "Voice sent",
                    selection: Binding(
                        get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.representationChoice ?? .textOnly },
                        set: { model.setShareDraftRepresentation(draft.id, choice: $0) }
                    )
                ) {
                    Text("Original voice").tag(ShareMarginRepresentationChoice.original)
                    if draft.cleanedAudioURL != nil {
                        Text("Cleaned voice").tag(ShareMarginRepresentationChoice.cleaned)
                    }
                    Text("Text only").tag(ShareMarginRepresentationChoice.textOnly)
                }
                .pickerStyle(.segmented)

                HStack {
                    if let originalURL = model.originalAudioURL(forShareDraft: draft.id) {
                        ShareRevisionAudioPreviewButton(title: "Preview Original", url: originalURL)
                    }
                    if let cleanedURL = draft.cleanedAudioURL {
                        ShareRevisionAudioPreviewButton(title: "Preview Cleaned", url: cleanedURL)
                    }
                }

                if draft.interjection.alignedTranscript != nil {
                    if draft.cleanup == nil {
                        Button("Remove Fillers & Long Pauses") {
                            model.prepareCleanup(forShareDraft: draft.id)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    } else {
                        cleanupReview(draft)
                        Button("Restore Original") {
                            model.restoreOriginalShareDraft(draft.id)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                } else {
                    Text("Word timing is unavailable for this older recording, so automatic audio cleanup is disabled. You can still share the original voice or text.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }

                if let warning = draft.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                DisclosureGroup("Shared anchor context") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Context before", text: Binding(
                            get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.anchorBefore ?? "" },
                            set: { model.setShareDraftAnchorBefore(draft.id, value: $0) }
                        ), axis: .vertical)
                        TextField("Context after", text: Binding(
                            get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.anchorAfter ?? "" },
                            set: { model.setShareDraftAnchorAfter(draft.id, value: $0) }
                        ), axis: .vertical)
                        Text("Each side is capped at 500 characters. Full source text is not sent.")
                            .font(.caption2)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
            }
        }
        .opacity(draft.isIncluded ? 1 : 0.62)
    }

    @ViewBuilder
    private func cleanupReview(_ draft: ShareInterjectionDraft) -> some View {
        if let decisions = draft.cleanup?.decisions {
            VStack(alignment: .leading, spacing: 8) {
                Text("Proposed edits — turn any edit off to undo it")
                    .font(.subheadline.weight(.semibold))
                ForEach(decisions) { decision in
                    Toggle(
                        decisionLabel(decision),
                        isOn: Binding(
                            get: {
                                model.sharingState.drafts
                                    .first(where: { $0.id == draft.id })?
                                    .cleanup?.decisions.first(where: { $0.id == decision.id })?.accepted ?? false
                            },
                            set: {
                                model.setCleanupDecision(
                                    draftID: draft.id,
                                    decisionID: decision.id,
                                    accepted: $0
                                )
                            }
                        )
                    )
                    .font(.caption)
                }
            }
        }
    }

    private func decisionLabel(_ decision: InterjectionCleanupDecision) -> String {
        switch decision.kind {
        case .filler: return "Remove “\(decision.originalText ?? "filler")”"
        case .isolatedPhrase: return "Remove isolated “\(decision.originalText ?? "phrase")”"
        case .longPause: return "Shorten \(max(0, decision.endMs - decision.startMs)) ms pause"
        }
    }
}

private struct ShareRevisionAudioPreviewButton: View {
    let title: String
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        Button {
            if isPlaying {
                player?.stop()
                isPlaying = false
            } else if let audio = try? AVAudioPlayer(contentsOf: url) {
                player = audio
                audio.play()
                isPlaying = true
            }
        } label: {
            Label(isPlaying ? "Stop" : title, systemImage: isPlaying ? "stop.fill" : "play.fill")
        }
        .buttonStyle(SecondaryButtonStyle())
    }
}

struct SharedSpokenMarginsPackageActivityView: UIViewControllerRepresentable {
    let packageURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [packageURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SharedSpokenMarginsPackageReadyView: View {
    @EnvironmentObject private var model: Gate1AppModel
    let packageURL: URL
    @State private var isActivityPresented = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                ProductPanel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Package ready")
                            .font(.headline)
                        Text(packageURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        Text("Use the recipient test path to import this exact package back onto this device and experience it in a separate listening session.")
                            .font(.callout)
                    }
                }
                Button("Share File") { isActivityPresented = true }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Create Recipient Test Session") {
                    model.createRecipientTestSessionFromLastSharedPackage()
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Done") { model.isSharedSpokenMarginsPackagePresented = false }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
            .padding(20)
            .navigationTitle("Share Margins")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $isActivityPresented) {
            SharedSpokenMarginsPackageActivityView(packageURL: packageURL)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
