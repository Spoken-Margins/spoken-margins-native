import Foundation
import SessionKitSharing
import AVFoundation
import SwiftUI

enum Build23SenderPresentation {
    static func filteredMargins(in snapshot: Build23SharingSnapshot) -> [Build23SharingMarginSnapshot] {
        switch snapshot.filter {
        case .all:
            snapshot.margins
        case .starred:
            snapshot.margins.filter(\.isStarred)
        }
    }

    static func expandedMargins(
        in snapshot: Build23SharingSnapshot,
        among candidates: [Build23SharingMarginSnapshot]? = nil
    ) -> [Build23SharingMarginSnapshot] {
        guard let selectedMarginID = snapshot.selectedMarginID,
              let selected = (candidates ?? snapshot.margins).first(where: { $0.id == selectedMarginID }) else {
            return []
        }
        return [selected]
    }

    static func reviewExpandedMargins(in snapshot: Build23SharingSnapshot) -> [Build23SharingMarginSnapshot] {
        let included = snapshot.margins.filter(\.isIncluded)
        if let selectedMarginID = snapshot.selectedMarginID,
           let selected = included.first(where: { $0.id == selectedMarginID }) {
            return [selected]
        }
        return included.first.map { [$0] } ?? []
    }

    /// #536: a failed share used to just sit there. When episode matching data (the fingerprint
    /// spine, its landmarks or their signatures) is what failed, the Margins can travel without it,
    /// so the sheet offers that. Other failures don't: turning matching off wouldn't fix them.
    static func offersShareWithoutMatching(previewState: Build23SharingPreviewState, includesAcousticEvidence: Bool) -> Bool {
        guard includesAcousticEvidence, case .failed(let message) = previewState else { return false }
        let lowered = message.lowercased()
        return ["fingerprint", "landmark", "assets/evidence/"].contains { lowered.contains($0) }
    }

    static func stageOwnsDetailedEditor(_ stage: Build23SharingStage) -> Bool {
        stage == .review
    }

    static func stageOwnsBatchPreparation(_ stage: Build23SharingStage) -> Bool {
        stage == .select
    }

    static func showsLinklessRightsControl(for transport: Build23RecipientTransport) -> Bool {
        transport == .embeddedText || transport == .recipientSupplied
    }

    static func requiresPayloadRightsAssertion(for transport: Build23RecipientTransport) -> Bool {
        transport == .embeddedText
    }

    static func stageTitle(_ stage: Build23SharingStage) -> String {
        switch stage {
        case .select:
            "Select"
        case .review:
            "Review"
        case .recipientPreview:
            "Recipient Preview"
        case .share:
            "Share"
        }
    }

    static func representationTitle(_ representation: ShareMarginRepresentationChoice) -> String {
        switch representation {
        case .original:
            "Original"
        case .cleaned:
            "Cleaned"
        case .textOnly:
            "Text only"
        }
    }

    static func transportTitle(_ transport: Build23RecipientTransport) -> String {
        switch transport {
        case .reference:
            "Reference"
        case .embeddedText:
            "Embedded text"
        case .recipientSupplied:
            "Recipient-supplied source"
        }
    }

    static func transportConsequence(_ transport: Build23RecipientTransport) -> String {
        switch transport {
        case .reference:
            "The package points back to the source. The recipient may need source access, and no embedding-rights assertion is required."
        case .embeddedText:
            "Reviewed source text travels inside the package. Declining embedding rights still allows Margin export with recipient-supplied transport."
        case .recipientSupplied:
            "Margins still export without embedded source material. The recipient supplies the source before imported Margins are positioned."
        }
    }

    static func tokenTitle(_ token: Build23SharingReviewTokenSnapshot) -> String {
        guard token.kind == .pause else { return token.text }
        let trimmed = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            return trimmed
        }
        return "[\(trimmed.isEmpty ? "pause" : trimmed)]"
    }
}

struct Build23SharingStageProgress: View {
    let currentStage: Build23SharingStage

    var body: some View {
        let stages = Build23SharingStage.allCases
        let currentIndex = stages.firstIndex(of: currentStage) ?? 0

        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                let isComplete = index < currentIndex
                let isCurrent = index == currentIndex
                HStack(spacing: 8) {
                    Image(systemName: isComplete ? "checkmark.circle.fill" : (isCurrent ? "circle.inset.filled" : "circle"))
                        .accessibilityHidden(true)
                    Text(Build23SenderPresentation.stageTitle(stage))
                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(2)
                }
                .foregroundStyle(isCurrent || isComplete ? AppColors.evergreen : AppColors.secondaryText)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Build23SenderPresentation.stageTitle(stage)), \(isComplete ? "complete" : (isCurrent ? "current" : "not started"))")
            }
        }
        .accessibilityIdentifier("build23.sender.stage.progress")
    }
}

/// Marks words that are only a stand-in for a voice Margin that has none (#3027): an icon and a word, not colour alone.
struct Build23PlaceholderTag: View {
    var body: some View {
        Label("Placeholder words", systemImage: "text.badge.plus")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.secondaryText)
            .accessibilityHidden(true)
    }
}

/// The words a word-less voice Margin is sent with (#3027). The box starts empty with the placeholder as its prompt,
/// so typing replaces it whole; clearing the box brings the placeholder back.
struct Build23PlaceholderWordsEditor: View {
    let margin: Build23SharingMarginSnapshot
    let placeholder: String
    let send: (Build23SenderAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Words to send")
                    .font(.headline)
                Spacer()
                if margin.isShowingPlaceholder {
                    Build23PlaceholderTag()
                }
            }
            TextField(
                placeholder,
                text: Binding(
                    get: { margin.isShowingPlaceholder ? "" : margin.reviewedText },
                    set: { send(.setReviewedWords(id: margin.id, text: $0)) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Words to send with this voice Margin")
            .accessibilityValue(margin.isShowingPlaceholder ? "Placeholder words: \(placeholder)" : margin.reviewedText)
            .accessibilityIdentifier("build23.sender.placeholder.words.\(margin.id)")
            Text(margin.isShowingPlaceholder
                 ? "This voice Margin has no transcript, so it goes with these placeholder words. Type to replace them with your own."
                 : "Clear the box to send the placeholder words instead.")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Build23StatusLabel: View {
    let icon: String
    let title: String
    var tint: Color = AppColors.secondaryText

    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Build23TransportConsequenceCard: View {
    let transport: Build23RecipientTransport
    let rightsConfirmed: Bool

    var body: some View {
        ExperienceSurface(tint: transport == .embeddedText && rightsConfirmed ? AppColors.softGreen : nil) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recipient transport")
                    .font(.headline)
                    .foregroundStyle(AppColors.text)

                Build23StatusLabel(
                    icon: "shippingbox",
                    title: Build23SenderPresentation.transportTitle(transport),
                    tint: AppColors.evergreen
                )
                Text(Build23SenderPresentation.transportConsequence(transport))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)

                Divider()

                switch transport {
                case .reference:
                    Build23StatusLabel(
                        icon: "link.circle.fill",
                        title: "Referenced transport does not use an embedding-rights assertion.",
                        tint: AppColors.evergreen
                    )
                case .embeddedText:
                    Build23StatusLabel(
                        icon: rightsConfirmed ? "checkmark.shield.fill" : "arrow.triangle.branch",
                        title: rightsConfirmed
                            ? "Private embedding rights confirmed."
                            : "Without embedding rights, Margin export can use recipient-supplied transport.",
                        tint: rightsConfirmed ? AppColors.evergreen : AppColors.secondaryText
                    )
                case .recipientSupplied:
                    Build23StatusLabel(
                        icon: "person.crop.circle.badge.checkmark",
                        title: "The recipient supplies the source; Margin export remains available.",
                        tint: AppColors.evergreen
                    )
                }
            }
        }
        .accessibilityIdentifier("build23.sender.transport.consequence")
    }
}

struct Build23MarginSelectionRow: View {
    let margin: Build23SharingMarginSnapshot
    let isEnabled: Bool
    let onSetIncluded: (Bool) -> Void

    var body: some View {
        ExperienceSurface(tint: margin.isIncluded ? AppColors.softGreen : nil) {
            AdaptiveStack(alignment: .top, spacing: 12) {
                Button {
                    onSetIncluded(!margin.isIncluded)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if margin.isStarred {
                                Label("Starred", systemImage: "star.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppColors.ochre)
                            } else {
                                Text("Margin")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppColors.secondaryText)
                            }

                            Text(Build23SenderPresentation.representationTitle(margin.representation))
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }

                        Text(margin.reviewedText.isEmpty ? "No reviewed text" : margin.reviewedText)
                            .font(.body)
                            .italic(margin.isShowingPlaceholder)
                            .foregroundStyle(margin.isShowingPlaceholder ? AppColors.secondaryText : AppColors.text)
                            .multilineTextAlignment(.leading)

                        if margin.isShowingPlaceholder {
                            Build23PlaceholderTag()
                        }

                        Text(margin.isLeftOutForMissingText ? "Left out: no transcript yet" : (margin.isIncluded ? "Included" : "Tap to include"))
                            .font(.caption)
                            .foregroundStyle(margin.isIncluded && !margin.isLeftOutForMissingText ? AppColors.evergreen : AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel("\(margin.isStarred ? "Starred " : "")Margin, \(margin.spokenWordsDescription), \(margin.shareStatusDescription)")
                .accessibilityHint("Double tap to \(margin.isIncluded ? "exclude" : "include") this Margin")
                .accessibilityIdentifier("build23.sender.margin.row.\(margin.id)")

                Toggle(
                    margin.isIncluded ? "Included" : "Include",
                    isOn: Binding(
                        get: { margin.isIncluded },
                        set: { newValue in onSetIncluded(newValue) }
                    )
                )
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Include this Margin in the package")
                .accessibilityValue(margin.isLeftOutForMissingText ? "Included, but left out: no transcript yet" : (margin.isIncluded ? "Included" : "Not included"))
                .accessibilityIdentifier("build23.sender.margin.include.\(margin.id)")
                .disabled(!isEnabled)
            }
        }
    }
}

struct Build23ReviewSelectionRow: View {
    let margin: Build23SharingMarginSnapshot
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ExperienceSurface(tint: isSelected ? AppColors.softGreen : nil) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .accessibilityHidden(true)
                        Text(isSelected ? "Editor open" : "Open editor")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(Build23SenderPresentation.representationTitle(margin.representation))
                            .font(.caption)
                    }
                    .foregroundStyle(isSelected ? AppColors.evergreen : AppColors.secondaryText)

                    Text(margin.reviewedText.isEmpty ? "No reviewed text" : margin.reviewedText)
                        .font(.subheadline)
                        .italic(margin.isShowingPlaceholder)
                        .foregroundStyle(margin.isShowingPlaceholder ? AppColors.secondaryText : AppColors.text)
                        .multilineTextAlignment(.leading)

                    if margin.isShowingPlaceholder {
                        Build23PlaceholderTag()
                    }

                    if margin.isLeftOutForMissingText {
                        Label("Left out: no transcript yet", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    } else {
                        Label("Included", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(AppColors.evergreen)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(margin.isLeftOutForMissingText ? "Left out Margin, no transcript yet" : "Included Margin, \(margin.spokenWordsDescription)"), \(isSelected ? "editor open" : "open editor")")
        .accessibilityIdentifier("build23.sender.review.selector.\(margin.id)")
    }
}

@MainActor
struct Build23MarginEditor: View {
    let margin: Build23SharingMarginSnapshot
    let send: (Build23SenderAction) -> Void
    @State private var showsPositionContext = false

    var body: some View {
        ExperienceSurface(tint: AppColors.softGreen) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Review this Margin")
                        .font(.title3.weight(.semibold))
                        .screenTitle()
                        .foregroundStyle(AppColors.text)
                        .accessibilityIdentifier("build23.sender.margin.editor.\(margin.id)")
                    Spacer()
                    Text(margin.isLeftOutForMissingText ? "Left out: no transcript yet" : (margin.isIncluded ? "Included" : "Not included"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(margin.isIncluded && !margin.isLeftOutForMissingText ? AppColors.evergreen : AppColors.secondaryText)
                }

                if margin.isPreparing {
                    Build23StatusLabel(icon: "hourglass", title: "Cleaning this Margin…", tint: AppColors.evergreen)
                } else if margin.canPrepareCleanup {
                    Button("Clean this Margin", systemImage: "wand.and.stars") {
                        send(.prepareCleanup(id: margin.id))
                    }
                    .filledActionButton()
                    .accessibilityHint("Removes proposed filler words and tightens pauses; every change remains reversible")
                    .accessibilityIdentifier("build23.sender.editor.prepare.\(margin.id)")
                } else if margin.automaticCleanupEnabled {
                    Build23StatusLabel(
                        icon: "checkmark.circle.fill",
                        title: "Cleanup applied — tap any changed word or pause below to restore it.",
                        tint: AppColors.evergreen
                    )
                } else if margin.reviewTokens.isEmpty {
                    Build23StatusLabel(
                        icon: "info.circle",
                        title: "Automatic cleanup is unavailable because this Margin has no word-level timing. Text review remains available."
                    )
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Share as")
                        .font(.headline)
                    Text(margin.hasCleanedVoice
                        ? "Choose the version the recipient will receive."
                        : "Cleaned voice becomes available after this Margin is cleaned successfully.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)

                    Picker(
                        "Share as",
                        selection: Binding(
                            get: { margin.representation },
                            set: { send(.setRepresentation(id: margin.id, choice: $0)) }
                        )
                    ) {
                        if margin.hasOriginalVoice {
                            Text("Original").tag(ShareMarginRepresentationChoice.original)
                        }
                        if margin.hasCleanedVoice {
                            Text("Cleaned").tag(ShareMarginRepresentationChoice.cleaned)
                        }
                        Text("Text").tag(ShareMarginRepresentationChoice.textOnly)
                    }
                    .segmentedUnlessLargeText()
                    .accessibilityIdentifier("build23.sender.representation.\(margin.id)")
                }

                Build23AudioPreviewControls(
                    originalURL: margin.originalVoiceURL,
                    cleanedURL: margin.cleanedVoiceURL
                )

                if !margin.reviewTokens.isEmpty {
                    Build23InlineTranscriptEditor(tokens: margin.reviewTokens) { token in
                        switch token.kind {
                        case .word:
                            guard let segmentID = token.segmentID else { return }
                            send(.toggleTranscriptWord(draftID: margin.id, segmentID: segmentID))
                        case .pause:
                            guard let decisionID = token.decisionID else { return }
                            send(.setCleanupDecision(
                                draftID: margin.id,
                                decisionID: decisionID,
                                accepted: !token.isRemoved
                            ))
                        }
                    }
                } else if let placeholder = margin.placeholderText {
                    Build23PlaceholderWordsEditor(margin: margin, placeholder: placeholder, send: send)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Reviewed transcript")
                            .font(.headline)
                        Build23ExpandableTranscript(text: margin.reviewedText)
                    }
                }

                DisclosureGroup("Placement details", isExpanded: $showsPositionContext) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("These excerpts help place the Margin for the recipient. Most people do not need to edit them.")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        TextField(
                            "Words before this Margin",
                            text: Binding(
                                get: { margin.anchorBefore },
                                set: { send(.setAnchorBefore(id: margin.id, text: $0)) }
                            ),
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Words before this Margin")
                        .accessibilityIdentifier("build23.sender.anchor.before.\(margin.id)")

                        TextField(
                            "Words after this Margin",
                            text: Binding(
                                get: { margin.anchorAfter },
                                set: { send(.setAnchorAfter(id: margin.id, text: $0)) }
                            ),
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Words after this Margin")
                        .accessibilityIdentifier("build23.sender.anchor.after.\(margin.id)")
                    }
                    .padding(.top, 8)
                }
                .font(.headline)

                HStack(spacing: 10) {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        send(.undo(id: margin.id))
                    }
                    .disabled(!margin.canUndo)
                    .accessibilityIdentifier("build23.sender.editor.undo.\(margin.id)")

                    Button("Redo", systemImage: "arrow.uturn.forward") {
                        send(.redo(id: margin.id))
                    }
                    .disabled(!margin.canRedo)
                    .accessibilityIdentifier("build23.sender.editor.redo.\(margin.id)")

                    if margin.canUndo || margin.automaticCleanupEnabled || margin.hasCleanedVoice {
                        Spacer()
                        Button("Undo all edits") {
                            send(.restoreOriginal(id: margin.id))
                        }
                        .accessibilityIdentifier("build23.sender.editor.restore.\(margin.id)")
                    }
                }
                .buttonStyle(.bordered)

                if let preparationMessage = margin.preparationMessage, !preparationMessage.isEmpty {
                    Build23StatusLabel(
                        icon: margin.hasCleanedVoice ? "checkmark.circle.fill" : "info.circle.fill",
                        title: preparationMessage,
                        tint: margin.hasCleanedVoice ? AppColors.evergreen : AppColors.secondaryText
                    )
                }

                if let warning = margin.warning, !warning.isEmpty {
                    Build23StatusLabel(icon: "exclamationmark.triangle.fill", title: warning, tint: AppColors.plum)
                }

                if let privateNote = margin.privateNote,
                   !privateNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Build23StatusLabel(
                            icon: "lock.fill",
                            title: "Private note — not exported",
                            tint: AppColors.secondaryText
                        )
                        Text(privateNote)
                            .font(.body)
                            .foregroundStyle(AppColors.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("build23.sender.private-note.\(margin.id)")
                }
            }
        }
    }
}

struct Build23ReviewTokenButton: View {
    let token: Build23SharingReviewTokenSnapshot
    let action: () -> Void

    private var hasCanonicalTarget: Bool {
        switch token.kind {
        case .word:
            token.segmentID != nil
        case .pause:
            token.decisionID != nil
        }
    }

    var body: some View {
        Button(action: action) {
            Text(Build23SenderPresentation.tokenTitle(token))
                .font(.body)
                .italic(token.kind == .pause)
                .strikethrough(token.isRemoved)
                .foregroundStyle(
                    token.isRemoved
                        ? AppColors.secondaryText
                        : (token.kind == .pause ? AppColors.evergreen : AppColors.text)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: true)
        .disabled(!hasCanonicalTarget)
        .accessibilityLabel(
            "\(token.kind == .pause ? "Pause" : "Word") \(Build23SenderPresentation.tokenTitle(token)), \(token.isRemoved ? "removed" : "included")"
        )
        .accessibilityHint(hasCanonicalTarget ? "Double tap to \(token.isRemoved ? "include" : "remove")" : "This token cannot be edited")
        .accessibilityIdentifier("build23.sender.review.token.\(token.id)")
    }
}

struct Build23BatchPreparationCard: View {
    let isPreparing: Bool
    let completed: Int
    let total: Int
    let failures: Int
    let canPrepare: Bool
    let onPrepare: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("Voice preparation")
                    .font(.headline)
                    .accessibilityIdentifier("build23.sender.preparation.batch")
                Text("Prepare cleaned voice for included Margins. A failed Margin retains Original voice when available, or reviewed Text otherwise.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)

                if isPreparing {
                    ProgressView(
                        value: Double(min(completed, max(total, 1))),
                        total: Double(max(total, 1))
                    )
                    .tint(AppColors.evergreen)
                    .accessibilityLabel("Voice preparation progress")
                    .accessibilityValue("\(completed) of \(total) complete")

                    HStack {
                        Build23StatusLabel(
                            icon: "hourglass",
                            title: "\(completed) of \(total) prepared",
                            tint: AppColors.evergreen
                        )
                        Spacer()
                        Button("Cancel preparation", role: .cancel, action: onCancel)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("build23.sender.preparation.cancel")
                    }
                } else {
                    Button("Prepare all included", systemImage: "waveform.badge.plus", action: onPrepare)
                        .buttonStyle(.bordered)
                        .disabled(!canPrepare)
                        .accessibilityIdentifier("build23.sender.preparation.all")
                }

                if failures > 0 {
                    FailureMessageLabel("\(failures) \(failures == 1 ? "Margin" : "Margins") could not be prepared. Each retains Original voice when available, or reviewed Text otherwise.")
                        .font(.subheadline)
                }
            }
        }
    }
}

struct Build23ReviewMarginCard: View {
    let margin: Build23SharingMarginSnapshot

    var body: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(
                        Build23SenderPresentation.representationTitle(margin.representation),
                        systemImage: margin.representation == .textOnly ? "text.alignleft" : "waveform"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.evergreen)
                    Spacer()
                    Text("Included")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.evergreen)
                }
                Text(margin.reviewedText)
                    .font(.body)
                    .foregroundStyle(AppColors.text)
                    .lineLimit(10)
                Text("Between “\(margin.anchorBefore)” and “\(margin.anchorAfter)”")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("build23.sender.review.margin.\(margin.id)")
    }
}

struct Build23VerifiedRecipientPreviewPanel: View {
    let preview: Build23VerifiedRecipientPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ExperienceSurface(tint: AppColors.softGreen) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Verified from the written package", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(AppColors.evergreen)
                    Text(preview.itemTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(AppColors.text)
                    Text("From \(preview.senderLabel)")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                    Build23StatusLabel(
                        icon: "shippingbox.fill",
                        title: Build23SenderPresentation.transportTitle(preview.transport),
                        tint: AppColors.evergreen
                    )
                    Text(Build23SenderPresentation.transportConsequence(preview.transport))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }

            ForEach(preview.margins) { margin in
                ExperienceSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(margin.representation)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppColors.evergreen)
                            Spacer()
                            Label(
                                margin.includesVoice ? "Voice included" : "Text only",
                                systemImage: margin.includesVoice ? "waveform.circle.fill" : "text.alignleft"
                            )
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        }
                        Text(margin.reviewedText)
                            .font(.body)
                            .foregroundStyle(AppColors.text)
                            .lineLimit(10)
                        Text(margin.positionDescription)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                .accessibilityIdentifier("build23.sender.recipient.margin.\(margin.id)")
            }

            ExperienceSurface {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Package contents")
                        .font(.headline)
                    Build23StatusLabel(icon: "waveform", title: "\(preview.voiceAssetCount) voice assets")
                    Build23StatusLabel(icon: "waveform.path.ecg", title: "\(preview.acousticEvidenceCount) acoustic evidence records")
                    Build23StatusLabel(
                        icon: "map",
                        title: preview.listeningMapProposalCount > 0
                            ? "Listening Map included"
                            : "Listening Map still preparing or unavailable; share remains usable"
                    )
                    Build23StatusLabel(
                        icon: "doc.zipper",
                        title: "\(preview.fileURL.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(preview.fileByteCount), countStyle: .file))"
                    )
                }
            }

            if !preview.disclosures.isEmpty {
                ExperienceSurface(tint: AppColors.ochre.opacity(0.12)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recipient disclosures")
                            .font(.headline)
                        ForEach(Array(preview.disclosures.enumerated()), id: \.offset) { _, disclosure in
                            Label(disclosure, systemImage: "info.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("build23.sender.recipient.verified-preview")
    }
}

struct Build23InlineTranscriptEditor: View {
    let tokens: [Build23SharingReviewTokenSnapshot]
    let onToggle: (Build23SharingReviewTokenSnapshot) -> Void

    @ScaledMetric(relativeTo: .body) private var tokenLineHeight: CGFloat = 36
    @State private var isExpanded = false
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var collapsedMaximumHeight: CGFloat {
        tokenLineHeight * 10
    }

    private var needsExpansion: Bool {
        fullHeight > collapsedHeight + 0.5
    }

    private var removedWordCount: Int {
        tokens.filter { $0.kind == .word && $0.isRemoved }.count
    }

    private var tightenedPauseCount: Int {
        tokens.filter { $0.kind == .pause && $0.isRemoved }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transcript")
                .font(.headline)
                .accessibilityIdentifier("build23.sender.inline-transcript-editor")
            Text("Read normally. Tap any word or bracketed pause to remove or restore it.")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)

            if removedWordCount > 0 || tightenedPauseCount > 0 {
                Text(cleanupSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.evergreen)
                    .accessibilityIdentifier("build23.sender.cleanup.summary")
            }

            if isExpanded {
                tokenLayout()
            } else {
                tokenLayout(maximumRows: 10)
                    .frame(maxHeight: collapsedMaximumHeight, alignment: .top)
                    .clipped()
            }

            tokenLayout()
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: Build23TranscriptHeightPreferenceKey.self,
                            value: ["tokens-full": proxy.size.height]
                        )
                    }
                }
                .hidden()
                .accessibilityHidden(true)
                .frame(height: 0)
                .clipped()

            tokenLayout(maximumRows: 10)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: Build23TranscriptHeightPreferenceKey.self,
                            value: ["tokens-collapsed": proxy.size.height]
                        )
                    }
                }
                .hidden()
                .accessibilityHidden(true)
                .frame(height: 0)
                .clipped()

            if needsExpansion {
                Button(isExpanded ? "Collapse words and pauses" : "Show all words and pauses") {
                    isExpanded.toggle()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.evergreen)
                .accessibilityIdentifier("build23.sender.tokens.expansion")
            }
        }
        .onPreferenceChange(Build23TranscriptHeightPreferenceKey.self) { heights in
            collapsedHeight = heights["tokens-collapsed"] ?? collapsedHeight
            fullHeight = heights["tokens-full"] ?? fullHeight
        }
    }

    private func tokenLayout(maximumRows: Int? = nil) -> some View {
        Build23WrappingLayout(spacing: 7, maximumRows: maximumRows) {
            ForEach(tokens) { token in
                Build23ReviewTokenButton(token: token) {
                    onToggle(token)
                }
            }
        }
    }

    private var cleanupSummary: String {
        let words = "\(removedWordCount) \(removedWordCount == 1 ? "word" : "words") removed"
        let pauses = "\(tightenedPauseCount) \(tightenedPauseCount == 1 ? "pause" : "pauses") tightened"
        if removedWordCount == 0 { return pauses }
        if tightenedPauseCount == 0 { return words }
        return "\(words) · \(pauses)"
    }
}

@MainActor
struct Build23AudioPreviewControls: View {
    let originalURL: URL?
    let cleanedURL: URL?

    @StateObject private var player = Build23AudioPreviewPlayer()

    var body: some View {
        if originalURL != nil || cleanedURL != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Voice preview")
                    .font(.headline)
                    .accessibilityIdentifier("build23.sender.voice-preview")
                Text("Preview the exact local voice assets represented in this draft.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)

                Build23WrappingLayout(spacing: 8) {
                    if let originalURL {
                        previewButton(title: "Original", url: originalURL)
                    }
                    if let cleanedURL {
                        previewButton(title: "Cleaned", url: cleanedURL)
                    }
                }

                if let errorMessage = player.errorMessage {
                    FailureMessageLabel(errorMessage)
                        .font(.subheadline)
                }
            }
            .onDisappear { player.stop() }
        }
    }

    private func previewButton(title: String, url: URL) -> some View {
        let isActive = player.activeURL == url && player.isPlaying
        return Button(isActive ? "Stop \(title)" : "Preview \(title)", systemImage: isActive ? "stop.fill" : "play.fill") {
            player.toggle(url: url)
        }
        .buttonStyle(.bordered)
        .tint(isActive ? AppColors.plum : AppColors.evergreen)
        .accessibilityLabel(isActive ? "Stop \(title) voice preview" : "Play \(title) voice preview")
        .accessibilityIdentifier("build23.sender.voice-preview.\(title.lowercased())")
    }
}

@MainActor
private final class Build23AudioPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var activeURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private var audioPlayer: AVAudioPlayer?

    func toggle(url: URL) {
        if activeURL == url, isPlaying {
            stop()
            return
        }

        do {
            audioPlayer?.stop()
            let nextPlayer = try AVAudioPlayer(contentsOf: url)
            nextPlayer.delegate = self
            nextPlayer.prepareToPlay()
            guard nextPlayer.play() else {
                throw Build23AudioPreviewError.playbackDidNotStart
            }
            audioPlayer = nextPlayer
            activeURL = url
            isPlaying = true
            errorMessage = nil
        } catch {
            audioPlayer = nil
            activeURL = nil
            isPlaying = false
            errorMessage = "This voice preview could not be played."
        }
    }

    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        activeURL = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.audioPlayer = nil
            self?.activeURL = nil
            self?.isPlaying = false
        }
    }
}

private enum Build23AudioPreviewError: Error {
    case playbackDidNotStart
}

struct Build23ExpandableTranscript: View {
    let text: String

    @State private var isExpanded = false
    @State private var limitedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var needsExpansion: Bool {
        fullHeight > limitedHeight + 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.body)
                .foregroundStyle(AppColors.text)
                .lineLimit(isExpanded ? nil : 10)
                .fixedSize(horizontal: false, vertical: true)

            measurementText(lineLimit: 10, key: "limited")
            measurementText(lineLimit: nil, key: "full")

            if needsExpansion {
                Button(isExpanded ? "Show less" : "Show full transcript") {
                    isExpanded.toggle()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.evergreen)
                .accessibilityIdentifier("build23.sender.transcript.expansion")
            }
        }
        .onPreferenceChange(Build23TranscriptHeightPreferenceKey.self) { heights in
            limitedHeight = heights["limited"] ?? limitedHeight
            fullHeight = heights["full"] ?? fullHeight
        }
    }

    private func measurementText(lineLimit: Int?, key: String) -> some View {
        Text(text)
            .font(.body)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: Build23TranscriptHeightPreferenceKey.self,
                        value: [key: proxy.size.height]
                    )
                }
            }
            .hidden()
            .accessibilityHidden(true)
            .frame(height: 0)
    }
}

private struct Build23TranscriptHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct Build23WrappingLayout: Layout {
    var spacing: CGFloat = 8
    var maximumRows: Int? = nil

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let idealWidth = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * spacing
        let availableWidth = max(1, proposal.width ?? idealWidth)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        var row = 1

        for size in sizes {
            if x > 0, x + size.width > availableWidth {
                if let maximumRows, row >= maximumRows {
                    break
                }
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
                row += 1
            }
            usedWidth = max(usedWidth, min(availableWidth, x + size.width))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: proposal.width ?? usedWidth, height: y + rowHeight)
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
        var row = 1
        var reachedRowLimit = false

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                if let maximumRows, row >= maximumRows {
                    reachedRowLimit = true
                } else {
                    x = bounds.minX
                    y += rowHeight + spacing
                    rowHeight = 0
                    row += 1
                }
            }
            if reachedRowLimit {
                subview.place(
                    at: CGPoint(x: bounds.maxX + 1, y: bounds.maxY + 1),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: 0, height: 0)
                )
                continue
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
