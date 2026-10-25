import AVFoundation
import SessionKit
import SessionKitAudio
import SessionKitFeeds
import SessionKitSharing
import SwiftUI
import UIKit

enum ShareMarginDraftFilter: String, CaseIterable, Identifiable {
    case all
    case starred

    var id: String { rawValue }
}

enum ShareAutoCleanPreference {
    static let decisionRecordedKey = "sharingAutoCleanDecisionRecordedV1"
    static let enabledKey = "sharingAutoCleanSelectedEnabledV1"

    static var hasRecordedDecision: Bool {
        UserDefaults.standard.bool(forKey: decisionRecordedKey)
    }

    static var isEnabled: Bool {
        hasRecordedDecision && UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func record(enabled: Bool) {
        UserDefaults.standard.set(true, forKey: decisionRecordedKey)
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
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
    var draftFilter: ShareMarginDraftFilter = .all
    var autoCleanSelectedEnabled = ShareAutoCleanPreference.isEnabled
    var needsAutoCleanDecision = !ShareAutoCleanPreference.hasRecordedDecision
    var automaticallyCleanedDraftIDs: Set<String> = []
    /// Set by the export screen, which prepares drafts from the session picked there. The
    /// sheet's `begin` keeps them once instead of rebuilding from the open item's session.
    var draftsPreparedForExport = false
}

struct SpokenMarginsPackageImportReview: Identifiable {
    let id = UUID()
    let packageURL: URL
    let extractionDirectory: URL
    let contents: VerifiedSpokenMarginsPackage
    let matchingItemId: String?
    /// A map packet whose item already carries a different shared map: adding this one replaces it.
    var replacesExistingMap = false
    /// Removes the file the packet was opened from (the Share inbox copy), once it is imported or cancelled (#2123).
    var releaseSource: (@MainActor () -> Void)?

    /// A file that carries a Listening Map for an article or PDF and no Margins (#1471).
    var isListeningMap: Bool { ListeningMapPacket.isMapPacket(contents.manifest) }

    var mapChapterCount: Int? { ListeningMapPacket.proposal(in: contents)?.scenes.count }

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
        // A PDF or EPUB can't be fetched from a link, so the listener picks their copy even when the sender had a link.
        let needsPickedFile = isListeningMap && contents.manifest.item.itemType != .text
        return (contents.manifest.itemTransport.kind == .recipientSupplied || needsPickedFile) && matchingItemId == nil
    }
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

    var measurementText: String {
        switch self {
        case .word(let segment): return segment.text
        case .pause(let decision):
            let duration = Double(max(0, decision.endMs - decision.startMs)) / 1_000
            return String(format: "[%.1fs pause]", duration)
        }
    }
}

private struct MarginTranscriptFullHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct MarginTranscriptLimitedHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
                        FailureMessageLabel(error)
                            .font(.callout)
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
            return "Spoken Margins found this item in your library and will place the shared Margins in it. Nothing will play automatically."
        }
        switch review.contents.manifest.itemTransport.kind {
        case .embeddedText:
            return "The sender included the exact text they listened to. Spoken Margins will add it to your library and resolve the Margins. Nothing will play automatically."
        case .reference:
            return "Spoken Margins will reconstruct this linked item and then place the shared Margins in it. Nothing will play automatically."
        case .recipientSupplied:
            if SharedEpisodeFeedMatcher.isPrivatePodcastSource(review.contents.manifest) {
                return "These Margins came from a private podcast feed, so the episode is not included. Add the same episode to your library, for example by pasting your own feed link in the import screen, then reopen this .spokenmargins file."
            }
            return "The item is not included. Add the same text, PDF, or EPUB to your library, then reopen this .spokenmargins file so its Margins can be attached safely."
        }
    }
}

struct InterjectionSharingView: View {
    static let collapsedTranscriptLineLimit = 10

    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var expandedTranscriptIDs: Set<String> = []
    @State private var transcriptFullHeights: [String: CGFloat] = [:]
    @State private var transcriptLimitedHeights: [String: CGFloat] = [:]

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
                                    Text("The package includes only selected Margins, the reviewed text and voice version shown below, the words around each Margin, item identity, and optional acoustic signatures. It never includes the podcast audio, raw diagnostics, or unrelated sessions.")
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

                            curationFilterPanel

                            bulkPreparationPanel

                            ForEach(visibleDrafts) { draft in
                                shareDraftCard(draft)
                                    .disabled(model.sharingState.isBulkPreparing)
                            }

                            if let error = model.sharingState.errorMessage {
                                FailureMessageLabel(error)
                                    .font(.callout)
                            }

                            Button {
                                model.exportSharedInterjections()
                            } label: {
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
        .onPreferenceChange(MarginTranscriptFullHeightKey.self) {
            transcriptFullHeights.merge($0, uniquingKeysWith: { _, new in new })
        }
        .onPreferenceChange(MarginTranscriptLimitedHeightKey.self) {
            transcriptLimitedHeights.merge($0, uniquingKeysWith: { _, new in new })
        }
    }

    private var starredDraftCount: Int {
        model.sharingState.drafts.filter { $0.interjection.isStarredForSharing == true }.count
    }

    private var visibleDrafts: [ShareInterjectionDraft] {
        switch model.sharingState.draftFilter {
        case .all:
            return model.sharingState.drafts
        case .starred:
            return model.sharingState.drafts.filter { $0.interjection.isStarredForSharing == true }
        }
    }

    @ViewBuilder
    private var curationFilterPanel: some View {
        if starredDraftCount > 0 {
            ProductPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sharing shortlist")
                        .font(.headline)
                    Picker("Margins shown", selection: $model.sharingState.draftFilter) {
                        Text("All (\(model.sharingState.drafts.count))").tag(ShareMarginDraftFilter.all)
                        Text("Starred (\(starredDraftCount))").tag(ShareMarginDraftFilter.starred)
                    }
                    .segmentedUnlessLargeText()
                    .accessibilityIdentifier("sharing.marginFilter")
                    Text("Stars choose the initial shortlist. Include this Margin is still the final choice for this share. Private sharing notes are shown below but are never sent.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
        }
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

                if draft.interjection.isStarredForSharing == true {
                    Label("Starred for sharing", systemImage: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.green)
                }
                if let note = draft.interjection.privateSharingNote?.nilIfEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Private sharing note")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppColors.secondaryText)
                        Text(note)
                            .font(.callout)
                        Text("Only you can see this note; it is not included in the package.")
                            .font(.caption2)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }

                Text("Reviewed transcript")
                    .font(.caption.weight(.semibold))
                if let aligned = draft.interjection.alignedTranscript {
                    let tokens = reviewTokens(for: draft, aligned: aligned)
                    let measurementText = tokens.map(\.measurementText).joined(separator: " ")
                    let isExpanded = expandedTranscriptIDs.contains(draft.id)
                    let isLong = transcriptIsLong(draft.id)
                    transcriptMeasurement(draftID: draft.id, text: measurementText)
                    Text("Tap a word or bracketed pause to remove or restore it. Crossed-out edits are removed from both the transcript and Cleaned voice; new words cannot be inserted into recorded audio.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    if isLong, !isExpanded {
                        Text(draft.approvedTranscript)
                            .font(.body)
                            .lineLimit(Self.collapsedTranscriptLineLimit)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                            .background(AppColors.inputBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .increasedContrastEdge(cornerRadius: 12)
                        Text("Expand to edit individual words and pauses.")
                            .font(.caption2)
                            .foregroundStyle(AppColors.secondaryText)
                    } else {
                        MarginWordWrapLayout(horizontalSpacing: 4, verticalSpacing: 6) {
                            ForEach(tokens) { token in
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
                    }
                    if isLong {
                        Button {
                            toggleTranscriptExpansion(draft.id)
                        } label: {
                            Label(
                                isExpanded ? "Show first \(Self.collapsedTranscriptLineLimit) lines" : "Show full editable transcript",
                                systemImage: isExpanded ? "chevron.up" : "chevron.down"
                            )
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("sharing.transcriptExpansion.\(draft.id)")
                    }
                    AdaptiveStack {
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
                    let isExpanded = expandedTranscriptIDs.contains(draft.id)
                    let isLong = transcriptIsLong(draft.id)
                    transcriptMeasurement(draftID: draft.id, text: draft.approvedTranscript)
                    Text(draft.approvedTranscript)
                        .lineLimit(isExpanded ? nil : Self.collapsedTranscriptLineLimit)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                        .padding(10)
                        .background(AppColors.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .increasedContrastEdge(cornerRadius: 12)
                    if isLong {
                        Button {
                            toggleTranscriptExpansion(draft.id)
                        } label: {
                            Label(
                                isExpanded ? "Show first \(Self.collapsedTranscriptLineLimit) lines" : "Show full transcript",
                                systemImage: isExpanded ? "chevron.up" : "chevron.down"
                            )
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("sharing.transcriptExpansion.\(draft.id)")
                    }
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
                .segmentedUnlessLargeText()

                AdaptiveStack {
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

                DisclosureGroup("Words around the Margin") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Context before", text: Binding(
                            get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.anchorBefore ?? "" },
                            set: { model.setShareDraftAnchorBefore(draft.id, value: $0) }
                        ), axis: .vertical)
                        TextField("Context after", text: Binding(
                            get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.anchorAfter ?? "" },
                            set: { model.setShareDraftAnchorAfter(draft.id, value: $0) }
                        ), axis: .vertical)
                        Text("The quote after the Margin is capped at \(ExcerptCapRule.afterMaximum) characters, and the quote before it at up to \(ExcerptCapRule.beforeMaximum), depending on the length of your comment. Full item text is sent only when the item disclosure above says it is included.")
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

    private func transcriptIsLong(_ draftID: String) -> Bool {
        guard let full = transcriptFullHeights[draftID],
              let limited = transcriptLimitedHeights[draftID] else { return false }
        return Self.transcriptRequiresExpansion(fullHeight: full, limitedHeight: limited)
    }

    static func transcriptRequiresExpansion(fullHeight: CGFloat, limitedHeight: CGFloat) -> Bool {
        fullHeight > limitedHeight + 1
    }

    private func toggleTranscriptExpansion(_ draftID: String) {
        if expandedTranscriptIDs.contains(draftID) {
            expandedTranscriptIDs.remove(draftID)
        } else {
            expandedTranscriptIDs.insert(draftID)
        }
    }

    private func transcriptMeasurement(draftID: String, text: String) -> some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .font(.body)
                .lineLimit(Self.collapsedTranscriptLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MarginTranscriptLimitedHeightKey.self,
                            value: [draftID: proxy.size.height]
                        )
                    }
                }
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: MarginTranscriptFullHeightKey.self,
                            value: [draftID: proxy.size.height]
                        )
                    }
                }
        }
        .hidden()
        .frame(height: 0)
        .clipped()
        .accessibilityHidden(true)
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
    /// Runs when the share sheet reports the packet was sent (logged as an I4 `share`, #483).
    var onShared: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [SpokenMarginsPackageActivityItem(packageURL: packageURL)],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if completed { onShared() }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

final class SpokenMarginsPackageActivityItem: NSObject, UIActivityItemSource {
    let packageURL: URL

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        packageURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        packageURL
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        SpokenMarginsPackageHandoffStore.uniformTypeIdentifier
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        "Spoken Margins shared session"
    }
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
                    }
                }
                Button("Share File") { isActivityPresented = true }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Done") { model.isSharedSpokenMarginsPackagePresented = false }
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
            .padding(20)
            .navigationTitle("Share Margins")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $isActivityPresented) {
            SharedSpokenMarginsPackageActivityView(packageURL: packageURL) {
                model.listeningSignals.share(packetURL: packageURL)
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
