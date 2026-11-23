import Foundation
import SessionKit
import SessionKitSharing
import SwiftUI

/// One Margin on the Share Margins list (#4647). A header row that switches it in or out, then, for an included Margin,
/// the words that go at the card's full width, the controls for them, and "More for this Margin". A left-out Margin shows
/// three lines of its words and nothing else. Every text block spans the card's width; nothing sits beside the words.
@MainActor
struct Build23MarginListCard: View {
    let margin: Build23SharingMarginSnapshot
    /// Its word editor is open in place of its words. One card at a time; the coordinator's `selectedMarginID` says which.
    let isEditing: Bool
    /// A share is waiting for voices: every control is inert until it ends. Disclosures still open and close.
    var isInert = false
    let send: (Build23SenderAction) -> Void
    let onEdit: () -> Void
    let onDone: () -> Void

    @State private var showsMore = false

    private var versionTitle: String {
        Build23SenderPresentation.representationTitle(margin.displayedVersion)
    }

    /// The editor button shows when there is an editor to open: word timing, or placeholder words to replace.
    private var hasEditor: Bool {
        !margin.reviewTokens.isEmpty || margin.placeholderText != nil
    }

    private var badge: String? {
        if let waiting = margin.waitingBadge { return waiting }
        if margin.isLeftOutForMissingText { return "Left out: no transcript yet" }
        return nil
    }

    var body: some View {
        ExperienceSurface(tint: margin.isIncluded ? AppColors.softGreen : nil) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !margin.hasPlace {
                    Text(ShareableMargins.noPlaceLine)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("build23.sender.margin.noPlace.\(margin.id)")
                    collapsedWords
                } else if margin.isIncluded {
                    includedContent
                } else {
                    collapsedWords
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { widthReporter("content") }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("build23.sender.margin.card.\(margin.id)")
    }

    // MARK: Header

    private var header: some View {
        Button {
            send(.setIncluded(id: margin.id, included: !margin.isIncluded))
        } label: {
            AdaptiveStack(alignment: .center, spacing: 12, wrapsText: true) {
                HStack(spacing: 6) {
                    if margin.isStarred {
                        Label("Starred", systemImage: "star.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.ochreText)
                    } else {
                        Text("Margin")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    if margin.isIncluded {
                        Text(versionTitle)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Display only: the row is the control, so a tap toggles once (#4647). VoiceOver hears the row (#3730).
                Toggle(ShareReviewCardWords.included, isOn: .constant(margin.isIncluded))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("build23.sender.margin.include.\(margin.id)")
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isInert || !margin.hasPlace)
        // Dimmed, and the line under it says why: the words carry the meaning, not the dimming (#4233).
        .opacity(margin.hasPlace ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ShareReviewCardWords.headerLabel(
            position: margin.position, shown: margin.shownCount, isStarred: margin.isStarred,
            version: margin.isIncluded ? versionTitle : nil))
        .accessibilityValue(ShareReviewCardWords.headerValue(isIncluded: margin.isIncluded))
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint(ShareReviewCardWords.headerHint)
        .accessibilityIdentifier("build23.sender.margin.row.\(margin.id)")
    }

    // MARK: Left out

    private var collapsedWords: some View {
        Build23ExpandableTranscript(
            text: margin.reviewedText.isEmpty ? "No reviewed text" : margin.reviewedText,
            collapsedLines: 3,
            identifier: "build23.sender.margin.moreWords.\(margin.id)"
        )
    }

    // MARK: Included

    @ViewBuilder
    private var includedContent: some View {
        if let badge {
            Text(badge)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityIdentifier("build23.sender.margin.badge.\(margin.id)")
        }

        ForEach(Array(margin.steps.enumerated()), id: \.offset) { index, step in
            Build23ReviewStepRow(step: step, identifier: "build23.sender.margin.step.\(margin.id).\(index)")
        }

        if isEditing {
            editor
        } else {
            words
        }

        cleanupLine

        friendGets

        Build23AudioPreviewControls(
            representation: margin.displayedVersion,
            originalURL: margin.originalVoiceURL,
            cleanedURL: margin.cleanedVoiceURL,
            isVoicePending: margin.waits
        )
        .disabled(isInert)

        // Directly under Listen, only for a placed Margin on an episode or audio file (#4171, the Design on #4647).
        if let leadIn = margin.leadIn {
            Build23LeadInRow(marginID: margin.id, leadIn: leadIn, send: send)
                .disabled(isInert)
        }

        Build23MarginFailureLines(margin: margin)

        DisclosureGroup(ShareReviewCardWords.moreForThisMargin, isExpanded: $showsMore) {
            VStack(alignment: .leading, spacing: 14) {
                Text(ShareReviewCardWords.whereItLands)
                    .font(.headline)
                Build23WhereItLandsFields(margin: margin, send: send)
                    .disabled(isInert)
                Build23PlacementNote(margin: margin)
                Build23PrivateNoteView(margin: margin)
            }
            .padding(.top, 8)
        }
        .font(.headline)
        .accessibilityIdentifier("build23.sender.more.\(margin.id)")
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(margin.hasChanges ? ShareReviewCardWords.yourWordsChanged : ShareReviewCardWords.yourWords)
                .font(.headline)
                .accessibilityIdentifier("build23.sender.margin.wordsLabel.\(margin.id)")

            Text(margin.reviewedText.isEmpty ? "No reviewed text" : margin.reviewedText)
                .font(.body)
                .italic(margin.isShowingPlaceholder)
                .foregroundStyle(margin.isShowingPlaceholder ? AppColors.secondaryText : AppColors.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .background { widthReporter("words") }
                .accessibilityLabel(margin.spokenWordsDescription)
                .accessibilityIdentifier("build23.sender.margin.words.\(margin.id)")

            if margin.isShowingPlaceholder {
                Build23PlaceholderTag()
            }

            if let summary = ShareCleanupWords.changeSummary(
                wordsRemoved: margin.wordsRemoved, pausesShortened: margin.pausesShortened) {
                Text(summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.evergreen)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("build23.sender.cleanup.summary.\(margin.id)")
            }

            if margin.pausesShortened > 0, margin.displayedVersion == .cleaned {
                Text(ShareReviewCardWords.pauseNote)
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("build23.sender.margin.pauseNote.\(margin.id)")
            }

            if hasEditor {
                Button(margin.hasChanges ? ShareReviewCardWords.showWhatChanged : ShareReviewCardWords.editWords,
                       systemImage: margin.hasChanges ? "text.badge.minus" : "pencil") {
                    onEdit()
                }
                .buttonStyle(.bordered)
                .disabled(isInert)
                .accessibilityIdentifier("build23.sender.editWords.\(margin.id)")
            }
        }
    }

    /// Today's editor in place of the words: every removed word and pause struck out, all of them shown (#4647).
    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !margin.reviewTokens.isEmpty {
                Build23InlineTranscriptEditor(tokens: margin.reviewTokens, showsAllTokens: true) { token in
                    if let action = Build23TokenToggle.action(for: token, marginID: margin.id) { send(action) }
                }
            } else if let placeholder = margin.placeholderText {
                Build23PlaceholderWordsEditor(margin: margin, placeholder: placeholder, send: send)
            }

            Build23EditHistoryButtons(margin: margin, send: send)

            Button(ShareReviewCardWords.done) {
                onDone()
            }
            .filledActionButton()
            .accessibilityIdentifier("build23.sender.editDone.\(margin.id)")
        }
        .disabled(isInert)
    }

    @ViewBuilder
    private var cleanupLine: some View {
        if margin.voiceInProgress {
            Build23StatusLabel(icon: "hourglass", title: ShareCleanupWords.cleaning, tint: AppColors.evergreen)
                .accessibilityIdentifier("build23.sender.margin.cleaning.\(margin.id)")
        } else if margin.canPrepareCleanup {
            Button(ShareCleanupWords.cleanButton, systemImage: "wand.and.stars") {
                send(.prepareCleanup(id: margin.id))
            }
            .buttonStyle(.bordered)
            .disabled(isInert)
            .accessibilityHint(ShareCleanupWords.cleanButtonHint)
            .accessibilityIdentifier("build23.sender.editor.prepare.\(margin.id)")
        }
        // Done shows no line: the header and the summary say it. A Margin that can't be cleaned shows nothing (#3853).
    }

    private var friendGets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ShareReviewCardWords.friendGets)
                .font(.headline)

            Picker(
                ShareReviewCardWords.friendGets,
                selection: Binding(
                    get: { margin.displayedVersion },
                    set: { send(.setRepresentation(id: margin.id, choice: $0)) }
                )
            ) {
                ForEach(margin.menuOptions, id: \.self) { option in
                    Text(Build23SenderPresentation.representationTitle(option)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .disabled(isInert)
            .accessibilityIdentifier("build23.sender.representation.\(margin.id)")

            Build23VersionCaption(representation: margin.displayedVersion, marginID: margin.id)

            if margin.displayedVersion == .textOnly {
                Build23ReadAloudControl(margin: margin, send: send)
                    .disabled(isInert)
            }
        }
    }

    private func widthReporter(_ key: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: MarginListCardWidths.self, value: ["\(key).\(margin.id)": proxy.size.width])
        }
    }
}

/// The widths of each list card's content and words block, keyed "content.<id>" and "words.<id>" (#4647), so a test
/// can check the words span the card at every text size.
struct MarginListCardWidths: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
