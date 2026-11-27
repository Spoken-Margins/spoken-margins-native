import Foundation
import SessionKit
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
        // The reply review is a receipt: no editor until a row is tapped, instead of the first Margin's (#3792).
        if snapshot.isReplyBack { return [] }
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

    /// The identifier of the top "Back to selection" button for this step, or nil when none is drawn there (#3896).
    /// On the preview step it is drawn only once the preview is ready and verified, as the old button inside
    /// `Build23VerifiedShareActions` was. While the preview builds, "back" would leave the build task running and a
    /// failed build would then pull the listener off the selection screen; the other preview states already carry
    /// their own "Back to selection" in the unavailable-preview notice.
    /// On the Share Margins list (#4647) the review step is the list itself, so it has no back.
    static func topBackToSelectionIdentifier(
        stage: Build23SharingStage, previewState: Build23SharingPreviewState, hasVerifiedPreview: Bool,
        showsList: Bool = false
    ) -> String? {
        switch stage {
        case .review:
            showsList ? nil : "build23.sender.review.back"
        case .recipientPreview:
            previewState == .ready && hasVerifiedPreview ? "build23.sender.preview.edit" : nil
        case .select, .share:
            nil
        }
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

    static func representationTitle(_ representation: ShareMarginRepresentationChoice) -> String {
        switch representation {
        case .original:
            ShareCleanupWords.asRecorded
        case .cleaned:
            ShareCleanupWords.withoutUms
        case .textOnly:
            ShareCleanupWords.wordsOnly
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
            "The file points back to the source. The recipient may need source access, and no embedding-rights assertion is required."
        case .embeddedText:
            "Reviewed source text travels inside the file. Declining embedding rights still allows Margin export with recipient-supplied transport."
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
            AppTextField(
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

/// The recipient preview's share action for a build without share links: "Share your Margins" alone on its line.
/// With links on, the pinned bar holds "Share link" and "Send as a file" instead (#3896), so this draws nothing.
/// One view, so a test can render the real button in each state.
struct Build23VerifiedShareActions: View {
    let isFileShareEnabled: Bool
    var fileIsSecondChoice = false
    let onShareFile: () -> Void

    var body: some View {
        if !fileIsSecondChoice {
            Button("Share your Margins", systemImage: "square.and.arrow.up", action: onShareFile)
                .filledActionButton()
                .disabled(!isFileShareEnabled)
                .accessibilityHint("Opens the system share sheet with your Margins")
                .accessibilityIdentifier("build23.sender.share.present")
        }
    }
}

/// "Back to selection" on the review and preview steps (#3896): a plain text button with a leading chevron, on its
/// own line under the header. The identifier is the caller's, so each step keeps its own.
struct Build23BackToSelectionButton: View {
    let identifier: String
    /// "Back to your Margins" on the preview of a sheet that isn't a reply, whose back returns to the list (#4647).
    var title = "Back to selection"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // At the accessibility sizes the title takes two lines. A `minHeight` frame takes whatever height it is
            // offered, so in a squeezed sheet it offered one line and the label read "Back to" (#5334); the frame
            // itself keeps its ideal height.
            Label(title, systemImage: "chevron.left")
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .frame(minHeight: 44, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(AppColors.evergreen)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }
}

/// "Send as a file" in the pinned bar, under the filled "Share link" (#3896): a plain full-width text button, so the
/// bar still holds one main action.
struct Build23SendFileButton: View {
    let isEnabled: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Send as a file", systemImage: "doc")
                .lineLimit(nil)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(AppColors.evergreen)
        .disabled(!isEnabled)
        .accessibilityHint("Opens the share sheet with your Margins as a file")
        .accessibilityIdentifier(identifier)
    }
}

/// The caption under the button that sends the file (#3800): a friend needs the app to open a file. One view, so a
/// test can render the real line for each build.
struct Build23FileNeedsAppCaption: View {
    let linksOffered: Bool

    var body: some View {
        Text(ShareFileMessage.caption(linksOffered: linksOffered, repliesOffered: LinkReplies.offered))
            .font(.footnote)
            .foregroundStyle(AppColors.secondaryText)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("build23.sender.file-caption")
    }
}

/// "Preview what your friend gets": one full-width bordered row at the end of the review step's content (#3896),
/// the last thing before the pinned send buttons. On a wide iPad it stops at a readable width.
struct Build23PreviewRow: View {
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                Text("Preview what your friend gets")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 4)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(AppColors.border, lineWidth: 1)
                    .opacity(isEnabled ? 1 : 0.4)
            )
        }
        .buttonStyle(.borderless)
        .tint(AppColors.evergreen)
        .frame(maxWidth: 480, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHint("Optionally shows what your friend will get")
        .accessibilityIdentifier("build23.sender.preview.build")
    }
}

/// The pinned bar while a tapped share waits for voices (#4647): the tapped button becomes a disabled row that counts
/// down, and "Stop sharing" under it ends the wait. The cleanup keeps running.
struct Build23SendWaitRow: View {
    let count: Int
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                Text(ShareReviewCardWords.waiting(count: count))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
            .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("build23.sender.sendWait.row")

            Button(role: .cancel, action: onStop) {
                Text(ShareReviewCardWords.stopSharing)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .tint(AppColors.evergreen)
            .accessibilityIdentifier("build23.sender.sendWait.stop")
        }
    }
}

struct Build23MarginSelectionRow: View {
    let margin: Build23SharingMarginSnapshot
    let isEnabled: Bool
    let onSetIncluded: (Bool) -> Void

    var body: some View {
        ExperienceSurface(tint: margin.isIncluded ? AppColors.softGreen : nil) {
            AdaptiveStack(alignment: .top, spacing: 12, wrapsText: true) {
                Button {
                    onSetIncluded(!margin.isIncluded)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if margin.isStarred {
                                Label("Starred", systemImage: "star.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppColors.ochreText)
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

                        Text(!margin.hasPlace ? ShareableMargins.noPlaceLine
                            : (margin.isLeftOutForMissingText ? "Left out: no transcript yet" : (margin.isIncluded ? "Included" : "Tap to include")))
                            .font(.caption)
                            .foregroundStyle(margin.isIncluded && !margin.isLeftOutForMissingText ? AppColors.evergreen : AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled || !margin.hasPlace)
                .accessibilityLabel("\(margin.isStarred ? "Starred " : "")Margin, \(margin.spokenWordsDescription), \(margin.shareStatusDescription)")
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
                // The row's own button above already says "included" or "not included" and toggles on a double tap, so
                // the switch beside it would be a second, identical control to swipe past (#3730).
                .accessibilityHidden(true)
                .accessibilityIdentifier("build23.sender.margin.include.\(margin.id)")
                .disabled(!isEnabled || !margin.hasPlace)
            }
            // Dimmed, and the line above says why: the words carry the meaning, not the dimming (#4233).
            .opacity(margin.hasPlace ? 1 : 0.6)
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
                    // The words carry the open or closed state, not an icon: the row's one checkmark means "Included" and
                    // nothing else (#3792).
                    HStack(spacing: 6) {
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

/// A wait the sender may act on: a clock or a speech bubble and one plain sentence, in the ordinary label colour so
/// colour carries no meaning (#3839).
struct Build23ReviewStepRow: View {
    let step: ShareReviewSteps.Step
    var identifier: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(step.icon))
                .foregroundStyle(AppColors.text)
                .accessibilityHidden(true)
            Text(step.text)
                .font(.subheadline)
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    static func symbol(_ icon: ShareReviewSteps.Icon) -> String {
        switch icon {
        case .clock: "clock"
        case .words: "text.bubble"
        }
    }
}

/// The step above "Share link" in the pinned bar. From the first accessibility size it is limited to two lines with a
/// "More" button that opens the full text, so the bar never covers more than half the screen (#3839); the full step also
/// stays on the Margin's card.
struct Build23PinnedStepLine: View {
    let step: ShareReviewSteps.Step
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showsFullText = false

    private var isLimited: Bool { typeSize >= .accessibility1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Build23ReviewStepRow.symbol(step.icon))
                    .foregroundStyle(AppColors.text)
                    .accessibilityHidden(true)
                Text(step.text)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.text)
                    .lineLimit(isLimited ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("build23.sender.review.placementStep")

            if isLimited {
                Button(ShareReviewCardWords.more) { showsFullText = true }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHint("Shows the whole message")
                    .accessibilityIdentifier("build23.sender.review.placementStep.more")
            }
        }
        .trackedSheet(isPresented: $showsFullText) {
            VStack(alignment: .leading, spacing: 16) {
                Text(ShareReviewCardWords.pinnedStepSheetTitle)
                    .font(.headline)
                Text(step.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Done") { showsFullText = false }
                    .filledActionButton()
                Spacer(minLength: 0)
            }
            .padding(24)
            .presentationDetents([.medium, .large])
        }
    }
}

@MainActor
struct Build23MarginEditor: View {
    let margin: Build23SharingMarginSnapshot
    let send: (Build23SenderAction) -> Void
    @State private var showsPositionContext = false

    /// The one badge a card can wear: it explains why the Margin is waiting or won't go. Every Margin on this step is otherwise included.
    private var badge: String? {
        if let waiting = margin.waitingBadge { return waiting }
        if margin.isLeftOutForMissingText { return "Left out: no transcript yet" }
        return margin.isIncluded ? nil : "Not included"
    }

    var body: some View {
        ExperienceSurface(tint: AppColors.softGreen) {
            VStack(alignment: .leading, spacing: 18) {
                // No card title and no "Included" badge: the page heading and the navigator say which Margin this is,
                // and every Margin on this step is included (#3839).
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("build23.sender.margin.badge.\(margin.id)")
                }

                ForEach(Array(margin.steps.enumerated()), id: \.offset) { index, step in
                    Build23ReviewStepRow(step: step, identifier: "build23.sender.margin.step.\(margin.id).\(index)")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(ShareReviewCardWords.friendGets)
                        .font(.headline)

                    Picker(
                        ShareReviewCardWords.friendGets,
                        selection: Binding(
                            get: { margin.representation },
                            set: { send(.setRepresentation(id: margin.id, choice: $0)) }
                        )
                    ) {
                        if margin.hasOriginalVoice {
                            Text(ShareCleanupWords.asRecorded).tag(ShareMarginRepresentationChoice.original)
                        }
                        if margin.hasCleanedVoice {
                            Text(ShareCleanupWords.withoutUms).tag(ShareMarginRepresentationChoice.cleaned)
                        }
                        Text(ShareCleanupWords.wordsOnly).tag(ShareMarginRepresentationChoice.textOnly)
                    }
                    .segmentedUnlessLargeText()
                    .accessibilityIdentifier("build23.sender.representation.\(margin.id)")

                    Build23VersionCaption(representation: margin.representation, marginID: margin.id)

                    if margin.representation == .textOnly {
                        Build23ReadAloudControl(margin: margin, send: send)
                    }
                }

                Build23AudioPreviewControls(
                    representation: margin.representation,
                    originalURL: margin.originalVoiceURL,
                    cleanedURL: margin.cleanedVoiceURL
                )

                // Directly under the Listen control, only for a placed Margin on an episode or audio file (#4171).
                if let leadIn = margin.leadIn {
                    Build23LeadInRow(marginID: margin.id, leadIn: leadIn, send: send)
                }

                if margin.isPreparing {
                    Build23StatusLabel(icon: "hourglass", title: ShareCleanupWords.cleaning, tint: AppColors.evergreen)
                } else if margin.canPrepareCleanup {
                    Button(ShareCleanupWords.cleanButton, systemImage: "wand.and.stars") {
                        send(.prepareCleanup(id: margin.id))
                    }
                    .filledActionButton()
                    .accessibilityHint(ShareCleanupWords.cleanButtonHint)
                    .accessibilityIdentifier("build23.sender.editor.prepare.\(margin.id)")
                } else if margin.automaticCleanupEnabled {
                    Build23StatusLabel(
                        icon: "checkmark.circle.fill",
                        title: ShareCleanupWords.cleaned,
                        tint: AppColors.evergreen
                    )
                }
                // A Margin with no word-level timing shows nothing here: the sender can do nothing about it (#3853, #3839).

                if !margin.reviewTokens.isEmpty {
                    Build23InlineTranscriptEditor(tokens: margin.reviewTokens) { token in
                        if let action = Build23TokenToggle.action(for: token, marginID: margin.id) { send(action) }
                    }
                } else if let placeholder = margin.placeholderText {
                    Build23PlaceholderWordsEditor(margin: margin, placeholder: placeholder, send: send)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(ShareReviewCardWords.yourWords)
                            .font(.headline)
                        Build23ExpandableTranscript(text: margin.reviewedText)
                    }
                }

                DisclosureGroup(ShareReviewCardWords.whereItLands, isExpanded: $showsPositionContext) {
                    Build23WhereItLandsFields(margin: margin, send: send)
                        .padding(.top, 8)
                }
                .font(.headline)

                Build23EditHistoryButtons(margin: margin, send: send)

                Build23PlacementNote(margin: margin)

                Build23PrivateNoteView(margin: margin)

                Build23MarginFailureLines(margin: margin)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("build23.sender.margin.editor.\(margin.id)")
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

struct Build23VerifiedRecipientPreviewPanel: View {
    let preview: Build23VerifiedRecipientPreview
    /// Scenes whose model-written title and summary the packet left out (#4635); the map line says so when above zero.
    var withheldMapSceneCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ExperienceSurface(tint: AppColors.softGreen) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("This is what your friend gets", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(AppColors.evergreen)
                    Text(preview.itemTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(AppColors.text)
                    Text(FriendArrivalWords.fromLine(senderLabel: preview.senderLabel))
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
                    Text("What is included")
                        .font(.headline)
                    Build23StatusLabel(icon: "waveform", title: "\(preview.voiceAssetCount) voice recordings")
                    Build23StatusLabel(icon: "waveform.path.ecg", title: "\(preview.acousticEvidenceCount) podcast matching signatures")
                    Build23StatusLabel(
                        icon: "map",
                        title: preview.listeningMapProposalCount > 0
                            ? MapTextDisclosure.withheldMapLine(sceneCount: withheldMapSceneCount) ?? "Listening Map included"
                            : "Listening Map still preparing or unavailable; share remains usable"
                    )
                    Build23StatusLabel(
                        icon: "doc.zipper",
                        title: "\(preview.fileURL.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(preview.fileByteCount), countStyle: .file))"
                    )                    .accessibilityIdentifier("build23.sender.preview.packetSize")
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
    /// The list card's editor shows every token, with no collapse (#4647); the reply sheet's keeps the collapse.
    var showsAllTokens = false
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

    private var shortenedPauseCount: Int {
        tokens.filter { $0.kind == .pause && $0.isRemoved }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ShareReviewCardWords.yourWords)
                .font(.headline)
                .accessibilityIdentifier("build23.sender.inline-transcript-editor")
            Text(ShareReviewCardWords.wordsEditorCaption)
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)

            if removedWordCount > 0 || shortenedPauseCount > 0 {
                Text(cleanupSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.evergreen)
                    .accessibilityIdentifier("build23.sender.cleanup.summary")
            }

            if isExpanded || showsAllTokens {
                tokenLayout()
            } else {
                tokenLayout(maximumRows: 10)
                    .frame(maxHeight: collapsedMaximumHeight, alignment: .top)
                    .clipped()
            }

            if !showsAllTokens {
                measuringLayouts
            }

            if needsExpansion, !showsAllTokens {
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

    /// Two hidden copies that measure the full and the collapsed height, so the collapse shows only when it hides words.
    @ViewBuilder
    private var measuringLayouts: some View {
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
        ShareCleanupWords.changeSummary(wordsRemoved: removedWordCount, pausesShortened: shortenedPauseCount) ?? ""
    }
}

/// "Before your Margin" (#4171, PR 4b of the Design): how much of the episode the friend hears first, and a preview
/// that plays it the way the friend will. The words and the rules are `SenderLeadInPreview`'s.
@MainActor
struct Build23LeadInRow: View {
    let marginID: String
    let leadIn: Build23LeadInSnapshot
    let send: (Build23SenderAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SenderLeadInPreview.rowLabel)
                .font(.headline)

            Picker(
                SenderLeadInPreview.rowLabel,
                selection: Binding(
                    get: { leadIn.ms },
                    set: { send(.setLeadIn(id: marginID, ms: $0)) }
                )
            ) {
                ForEach(leadIn.choicesMs, id: \.self) { ms in
                    Text(SenderLeadInPreview.choiceLabel(ms)).tag(ms)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("build23.sender.leadIn.\(marginID)")

            Text(SenderLeadInPreview.caption)
                .font(.footnote)
                .foregroundStyle(AppColors.secondaryText)

            Button(
                leadIn.isPlaying ? SenderLeadInPreview.stopButton : SenderLeadInPreview.previewButton,
                systemImage: leadIn.isPlaying ? "stop.fill" : "play.circle"
            ) {
                send(.toggleLeadInPreview(id: marginID))
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .disabled(!leadIn.previewIsAvailable && !leadIn.isPlaying)
            .accessibilityIdentifier("build23.sender.leadIn.preview.\(marginID)")

            if !leadIn.previewIsAvailable {
                Text(SenderLeadInPreview.momentPendingCaption)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            } else if leadIn.previewFailed {
                FailureMessageLabel(SenderLeadInPreview.failureCaption)
                    .font(.subheadline)
            } else if let after = leadIn.afterRunUpCaption {
                Text(after)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .onDisappear { send(.stopLeadInPreview(id: marginID)) }
    }
}

/// One button that plays the version the sender has selected (#3839). Switching the picker is how they compare; there
/// is no button with Words only.
@MainActor
struct Build23AudioPreviewControls: View {
    let representation: ShareMarginRepresentationChoice
    let originalURL: URL?
    let cleanedURL: URL?
    /// The version without ums is shown while its voice is still being made (#4647): its Listen waits, with a line that
    /// says so. It is one of only two controls on the list that wait for a voice.
    var isVoicePending = false

    @StateObject private var player = Build23AudioPreviewPlayer()

    private var playable: (title: String, url: URL, id: String)? {
        switch representation {
        case .original:
            originalURL.map { (title: ShareReviewCardWords.listenAsRecorded, url: $0, id: "original") }
        case .cleaned:
            cleanedURL.map { (title: ShareReviewCardWords.listenWithoutUms, url: $0, id: "cleaned") }
        case .textOnly:
            nil
        }
    }

    var body: some View {
        if isVoicePending, representation == .cleaned {
            VStack(alignment: .leading, spacing: 8) {
                Button(ShareReviewCardWords.listenWithoutUms, systemImage: "play.fill") {}
                    .buttonStyle(.bordered)
                    .tint(AppColors.evergreen)
                    .disabled(true)
                    .accessibilityIdentifier("build23.sender.voice-preview.cleaned")
                Text(ShareReviewCardWords.voicePending)
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("build23.sender.voice-preview.pending")
            }
            .onAppear { player.stop() }
        } else if let playable {
            VStack(alignment: .leading, spacing: 10) {
                let isActive = player.activeURL == playable.url && player.isPlaying
                Button(isActive ? ShareReviewCardWords.stopListening : playable.title, systemImage: isActive ? "stop.fill" : "play.fill") {
                    player.toggle(url: playable.url)
                }
                .buttonStyle(.bordered)
                .tint(AppColors.evergreen)
                .accessibilityLabel(isActive ? ShareReviewCardWords.stopListening : playable.title)
                .accessibilityIdentifier("build23.sender.voice-preview.\(playable.id)")

                if let errorMessage = player.errorMessage {
                    FailureMessageLabel(errorMessage)
                        .font(.subheadline)
                }
            }
            // Switching version stops whatever was playing, so "Stop" never sits on a button for the other version.
            .onCompatibleChange(of: representation) { _ in player.stop() }
            .onDisappear { player.stop() }
        }
    }
}

@MainActor
private final class Build23AudioPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var activeURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private var audioPlayer: AVAudioPlayer?
    nonisolated(unsafe) private var previewToken: NSObjectProtocol?

    override init() {
        super.init()
        // "Hear it as your friend will" starting stops this, and the reverse (#4171).
        previewToken = NotificationCenter.default.addObserver(
            forName: .shareReviewPreviewDidStart, object: nil, queue: .main
        ) { [weak self] note in
            let starter = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated {
                guard let self, starter != ObjectIdentifier(self) else { return }
                self.stop()
            }
        }
    }

    deinit {
        if let previewToken { NotificationCenter.default.removeObserver(previewToken) }
    }

    func toggle(url: URL) {
        if activeURL == url, isPlaying {
            stop()
            return
        }

        do {
            audioPlayer?.stop()
            // The same session setup as "Hear it as your friend will": a cold launch would otherwise play this muted
            // on Silent (audit on #5108).
            try LeadInPreviewPlayer.activatePlaybackSession()
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
            NotificationCenter.default.post(name: .shareReviewPreviewDidStart, object: self)
        } catch {
            audioPlayer = nil
            activeURL = nil
            isPlaying = false
            errorMessage = ShareReviewCardWords.listenError
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
    /// How many lines show before "Show all your words": 10 in the editor, 3 on a left-out list card (#4647).
    var collapsedLines = 10
    var identifier = "build23.sender.transcript.expansion"

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
                .lineLimit(isExpanded ? nil : collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            measurementText(lineLimit: collapsedLines, key: "limited")
            measurementText(lineLimit: nil, key: "full")

            if needsExpansion {
                Button(isExpanded ? ShareReviewCardWords.showLess : ShareReviewCardWords.showAllWords) {
                    isExpanded.toggle()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.evergreen)
                .accessibilityIdentifier(identifier)
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
