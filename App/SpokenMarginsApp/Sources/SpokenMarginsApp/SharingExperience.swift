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

struct ShareMarginEditState: Equatable {
    var automaticCleanupEnabled = false
    var restoredAutomaticDecisionIds: Set<String> = []
    var manuallyDeletedSegmentIds: Set<String> = []

    static let original = ShareMarginEditState()
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
    var acousticPauseDecisions: [InterjectionCleanupDecision] = []
    var editHistory: [ShareMarginEditState] = [.original]
    var editHistoryIndex = 0
    var isAnalyzingPauses = false
    var isPreparingCleanup = false
    var preparationMessage: String?
    var renderGeneration = 0

    var currentEditState: ShareMarginEditState {
        editHistory[min(max(0, editHistoryIndex), editHistory.count - 1)]
    }

    var canUndoEdit: Bool { editHistoryIndex > 0 }
    var canRedoEdit: Bool { editHistoryIndex + 1 < editHistory.count }
}

struct InterjectionSharingState {
    var drafts: [ShareInterjectionDraft] = []
    var senderDisplayLabel = UserDefaults.standard.string(forKey: "sharingSenderDisplayLabel") ?? ""
    var includesAcousticEvidence = true
    var itemReferenceURL: String?
    var canEmbedLinklessItem = false
    var isAppAuthoredItem = false
    var confirmsPrivateSharingRights = false
    var isPreparing = false
    var isBulkPreparing = false
    var bulkPreparationCompleted = 0
    var bulkPreparationTotal = 0
    var bulkPreparationFailureCount = 0
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

    var includesEmbeddedItem: Bool {
        contents.manifest.itemTransport.kind == .embeddedText
    }

    var requiresRecipientItem: Bool {
        contents.manifest.itemTransport.kind == .recipientSupplied && matchingItemId == nil
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

private enum MarginReviewToken: Identifiable {
    case word(AlignedTranscriptSegment)
    case pause(InterjectionCleanupDecision)

    var id: String {
        switch self {
        case .word(let segment): return "word:\(segment.id)"
        case .pause(let decision): return "pause:\(decision.id)"
        }
    }

    var startMs: Int {
        switch self {
        case .word(let segment): return segment.startMs
        case .pause(let decision): return decision.startMs
        }
    }
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
                            Text(review.contents.manifest.item.title)
                                .font(.title3.weight(.semibold))
                            Text(review.senderLabel)
                                .font(.headline)
                            Text("Integrity checked · Sender identity is not verified")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                            Text("\(review.marginCount) shared Margin\(review.marginCount == 1 ? "" : "s")")
                        }
                    }

                    Text(importExplanation)
                        .font(.callout)

                    DisclosureGroup("Package contents") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Voice files: \(review.contents.manifest.assets.filter { [SpokenMarginsAssetRole.originalVoice, SpokenMarginsAssetRole.cleanedVoice].contains($0.role) }.count)")
                            Text("Acoustic anchor signatures: \(review.contents.manifest.assets.filter { $0.role == SpokenMarginsAssetRole.acousticSignature }.count)")
                            Text("Listening Map proposals: \(review.contents.listeningMapProposals.count) (stored as proposals; not activated)")
                            Text(review.includesEmbeddedItem ? "Full listened-to item: included" : "Full listened-to item: not included")
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
                    .disabled(model.isImportingSpokenMarginsPackage || review.requiresRecipientItem)

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

    private var importExplanation: String {
        if review.matchingItemId != nil {
            return "Spoken Margins found this item in your library and will resolve the shared anchors against it. Nothing will play automatically."
        }
        switch review.contents.manifest.itemTransport.kind {
        case .embeddedText:
            return "The sender included the exact text they listened to. Spoken Margins will add it to your library and resolve the Margins. Nothing will play automatically."
        case .reference:
            return "Spoken Margins will reconstruct this linked item and then resolve the shared anchors. Nothing will play automatically."
        case .recipientSupplied:
            return "The item is not included. Add the same text, PDF, or EPUB to your library, then reopen this .spokenmargins file so its Margins can be attached safely."
        }
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
                                    Text("The package includes only selected Margins, the reviewed text and voice version shown below, bounded anchor context, item identity, and optional acoustic signatures. It never includes the podcast audio, raw diagnostics, or unrelated sessions.")
                                        .font(.callout)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                            }

                            TextField("Your display label (optional)", text: $model.sharingState.senderDisplayLabel)
                                .textFieldStyle(.roundedBorder)

                            itemTransportReview

                            Toggle("Include high-reliability podcast anchor evidence", isOn: $model.sharingState.includesAcousticEvidence)
                            Text("Recommended. These ShazamKit signatures help a recipient find the same spoken passage when their download contains different ads. They are not playable podcast audio.")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)

                            bulkPreparationPanel

                            ForEach(model.sharingState.drafts) { draft in
                                shareDraftCard(draft)
                                    .disabled(model.sharingState.isBulkPreparing)
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
                                    || model.sharingState.isBulkPreparing
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
                    Button("Cancel") {
                        model.cancelBulkSharePreparation()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear(perform: model.cancelBulkSharePreparation)
    }

    @ViewBuilder
    private var bulkPreparationPanel: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Prepare Margins in Bulk")
                    .font(.headline)
                Text("Removes suggested fillers, tightens pauses, and prepares cleaned review copies for every included Margin with word timing. Private recordings are never changed.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                if model.sharingState.isBulkPreparing {
                    ProgressView(
                        value: Double(model.sharingState.bulkPreparationCompleted),
                        total: Double(max(1, model.sharingState.bulkPreparationTotal))
                    )
                    .accessibilityIdentifier("sharing.bulkPreparationProgress")
                    Text("Prepared \(model.sharingState.bulkPreparationCompleted) of \(model.sharingState.bulkPreparationTotal)")
                        .font(.caption.weight(.semibold))
                    Button("Cancel Bulk Preparation", role: .cancel) {
                        model.cancelBulkSharePreparation()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("sharing.bulkPreparationCancel")
                } else {
                    Button {
                        model.prepareAllIncludedShareDrafts()
                    } label: {
                        Label(
                            "Prepare All Included (\(model.bulkSharePreparationEligibleCount))",
                            systemImage: "wand.and.stars"
                        )
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.bulkSharePreparationEligibleCount == 0 || model.sharingState.isExporting)
                    .accessibilityIdentifier("sharing.bulkPreparationStart")
                    if model.sharingState.bulkPreparationTotal > 0 {
                        Text(
                            model.sharingState.bulkPreparationFailureCount == 0
                                ? "Bulk preparation completed. Review any Margin below before sharing."
                                : "Bulk preparation completed with \(model.sharingState.bulkPreparationFailureCount) Margin fallback\(model.sharingState.bulkPreparationFailureCount == 1 ? "" : "s"). Original voice or text remains available below."
                        )
                        .font(.caption)
                        .foregroundStyle(
                            model.sharingState.bulkPreparationFailureCount == 0
                                ? AppColors.secondaryText
                                : .orange
                        )
                    }
                }
                Text("Preparation runs one recording at a time to keep memory, heat, and battery use bounded—even for dozens of Margins.")
                    .font(.caption2)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    @ViewBuilder
    private var itemTransportReview: some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Item being listened to")
                    .font(.headline)
                if let reference = model.sharingState.itemReferenceURL {
                    Label("Linked item", systemImage: "link")
                        .font(.subheadline.weight(.semibold))
                    Text(reference)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Text("The recipient will reconstruct the item from this reference. The full item is not included.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                } else if model.sharingState.canEmbedLinklessItem {
                    Toggle(
                        "I’m sharing this privately and have the right to share this item",
                        isOn: $model.sharingState.confirmsPrivateSharingRights
                    )
                    .disabled(model.sharingState.isAppAuthoredItem)
                    if model.sharingState.isAppAuthoredItem {
                        Text("This Spoken Margins sample is app-authored, so its full listened-to text will be included.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    } else if model.sharingState.confirmsPrivateSharingRights {
                        Text("The full listened-to text will be included so the recipient can add and listen to the item.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    } else {
                        Label(
                            "Only your Margins will be sent. Make sure the recipient already has the same text, PDF, or EPUB.",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } else {
                    Text("The item itself cannot be included. Make sure the recipient already has the same item.")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
                if let aligned = draft.interjection.alignedTranscript {
                    Text("Tap a word or bracketed pause to remove or restore it. Crossed-out edits are removed from both the transcript and Cleaned voice; new words cannot be inserted into recorded audio.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    MarginWordWrapLayout(horizontalSpacing: 4, verticalSpacing: 6) {
                        ForEach(reviewTokens(for: draft, aligned: aligned)) { token in
                            switch token {
                            case .word(let segment):
                                let deleted = model.isShareDraftWordDeleted(draftID: draft.id, segmentID: segment.id)
                                Button {
                                    model.toggleShareDraftWord(draftID: draft.id, segmentID: segment.id)
                                } label: {
                                    Text(segment.text)
                                        .font(.body)
                                        .foregroundStyle(deleted ? AppColors.dangerText : AppColors.text)
                                        .strikethrough(deleted, color: AppColors.dangerText)
                                }
                                .buttonStyle(.plain)
                                .disabled(!draft.isIncluded)
                                .contentShape(Rectangle())
                                .accessibilityLabel("\(deleted ? "Restore" : "Remove") \(segment.text)")
                            case .pause(let decision):
                                Button {
                                    model.setCleanupDecision(
                                        draftID: draft.id,
                                        decisionID: decision.id,
                                        accepted: !decision.accepted
                                    )
                                } label: {
                                    Text(pauseLabel(decision))
                                        .font(.body)
                                        .foregroundStyle(decision.accepted ? AppColors.dangerText : AppColors.secondaryText)
                                        .strikethrough(decision.accepted, color: AppColors.dangerText)
                                }
                                .buttonStyle(.plain)
                                .disabled(!draft.isIncluded)
                                .contentShape(Rectangle())
                                .accessibilityLabel("\(decision.accepted ? "Restore" : "Shorten") pause")
                            }
                        }
                    }
                    HStack {
                        Button {
                            model.undoShareDraftEdit(draft.id)
                        } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!draft.canUndoEdit)
                        Button {
                            model.redoShareDraftEdit(draft.id)
                        } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!draft.canRedoEdit)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Text(draft.approvedTranscript)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                        .padding(10)
                        .background(AppColors.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

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
                        Button("Remove Fillers & Tighten Pauses") {
                            model.prepareCleanup(forShareDraft: draft.id)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button("Restore Original") {
                            model.restoreOriginalShareDraft(draft.id)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if draft.isAnalyzingPauses {
                        ProgressView("Analyzing the recording for quiet gaps…")
                            .font(.caption)
                    }
                    if draft.isPreparingCleanup {
                        ProgressView("Preparing cleaned voice…")
                            .font(.caption)
                    } else if draft.currentEditState.automaticCleanupEnabled {
                        Label(
                            draft.cleanedAudioURL != nil
                                ? "Cleaned voice prepared"
                                : (draft.cleanup == nil
                                    ? "Reviewed—no automatic edits suggested"
                                    : "Reviewed text prepared; original voice retained"),
                            systemImage: "checkmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
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
                if let message = draft.preparationMessage {
                    Label(message, systemImage: "exclamationmark.circle")
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
                        Text("Each side is capped at 500 characters. Full item text is sent only when the item disclosure above says it is included.")
                            .font(.caption2)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
            }
        }
        .opacity(draft.isIncluded ? 1 : 0.62)
    }

    private func reviewTokens(
        for draft: ShareInterjectionDraft,
        aligned: AlignedInterjectionTranscript
    ) -> [MarginReviewToken] {
        let words = aligned.segments.map(MarginReviewToken.word)
        let pauses = (draft.cleanup?.decisions ?? [])
            .filter { $0.kind == .longPause }
            .map(MarginReviewToken.pause)
        return (words + pauses).sorted {
            if $0.startMs == $1.startMs { return $0.id < $1.id }
            return $0.startMs < $1.startMs
        }
    }

    private func pauseLabel(_ decision: InterjectionCleanupDecision) -> String {
        let duration = Double(max(0, decision.endMs - decision.startMs)) / 1_000
        return String(format: "[%.1fs pause]", duration)
    }
}

private struct MarginWordWrapLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? max(0, x - horizontalSpacing), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
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
