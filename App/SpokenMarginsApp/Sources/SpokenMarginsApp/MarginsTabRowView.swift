import SessionKit
import SwiftUI

/// One Margin on the Margins tab or the arrival preview (owner's prototype v3, part of #3216): the sender, the time, a
/// one-line lead-in, two lines of the words with "See more" only when they're cut, and the start control. A friend's
/// unheard Margin has a blue bar and dot, never bold or bigger; a heard one is greyed and a little smaller; your own is
/// neither and carries the star. Blue and the words "Unheard" and "Heard" carry the state, never red or green.
struct MarginsTabRowView: View {
    enum Mode { case arrival, playback }

    let entry: MarginsTabList.Entry
    let mode: Mode
    let isPlaying: Bool
    let canJump: Bool
    /// Where the jump goes from the playhead; ignored on arrival, where the icon is play.
    let direction: MarginsTabList.JumpDirection
    let identifier: String
    let showDetails: () -> Void
    /// The sharing star on your own Margin (#4173), or nil for a friend's Margin or one Share can't send.
    let star: PlaybackMarginRowView.Star?
    /// The start control goes to the Margin's place with nothing read aloud (Silent Margins, #4934).
    var goesTo = false
    var sourceNoun: SourceNoun = .episode
    let jump: () -> Void

    @State private var isExpanded = false
    @State private var isTruncated = false

    /// Okabe-Ito sky blue, as in the prototype: unheard, always with the dot, the bar and the spoken "Unheard".
    static let unheardBlue = AppColors.unheard

    private var row: MarginsControlCenter.Row { entry.row }
    private var isHeard: Bool { row.hearing == .heard && !isPlaying }
    private var isUnheard: Bool { row.hearing == .unheard && !isPlaying }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: showDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    if !entry.isReply, let leadIn = row.leadIn { leadInLine(leadIn) }
                    words
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, star != nil ? 34 : 0) // room for the star
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Opens this Margin")
            .accessibilityIdentifier(identifier)
            .overlay(alignment: .topTrailing) {
                if let star {
                    MarginShareStarButton(
                        isStarred: star.isStarred, title: spokenWords, identifier: "\(identifier).star", action: star.action)
                        .offset(x: 10, y: -12)
                }
            }
            actions
        }
        .padding(.leading, 14)
        .padding(.vertical, 8)
        .padding(.trailing, isPlaying ? 8 : 0)
        .background(alignment: .leading) {
            if isUnheard || isPlaying {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isPlaying ? AppColors.listeningAccent : Self.unheardBlue)
                    .frame(width: 3)
                    .padding(.vertical, 10)
                    .accessibilityHidden(true)
            }
        }
        .background {
            if isPlaying {
                RoundedRectangle(cornerRadius: 10)
                    .fill(AppColors.listeningAccent.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppColors.listeningAccent))
            }
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if isUnheard {
                Circle().fill(Self.unheardBlue).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(row.shownName)
                .font(isHeard ? .subheadline.weight(.semibold) : .body.weight(.semibold))
                .foregroundStyle(isHeard ? AppColors.watchSecondary : .white)
            if let replyTo = entry.replyTo { Text("to \(replyTo)") }
            if let ms = row.timeMs { Text(MarginReplyWords.clock(milliseconds: ms)) }
            if goesTo { Text(SilentMarginWords.notReadAloudSuffix.trimmingCharacters(in: CharacterSet(charactersIn: " ·"))) }
            if isPlaying {
                Label("Playing", systemImage: "waveform").foregroundStyle(AppColors.listeningAccent).fontWeight(.semibold)
            } else if isHeard {
                Label("Heard", systemImage: "checkmark")
            }
        }
        .font(.footnote)
        .foregroundStyle(AppColors.watchSecondary)
        .lineLimit(1)
        .labelStyle(.titleAndIcon)
    }

    private func leadInLine(_ leadIn: String) -> some View {
        Text("After \(Text("“\(leadIn)”").italic())")
            .font(.footnote)
            .foregroundStyle(AppColors.watchSecondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var words: some View {
        switch row.words {
        case .text(let text):
            Text(text)
                .font(.system(isHeard ? .subheadline : .body, design: .serif))
                .foregroundStyle(isHeard ? AppColors.watchSecondary : .white)
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    // The same words with no limit, measured unseen: "See more" only when the two lines cut them.
                    Text(text)
                        .font(.system(isHeard ? .subheadline : .body, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .overlay {
                            GeometryReader { full in
                                Color.clear.preference(key: FullHeightKey.self, value: full.size.height)
                            }
                        }
                }
                .overlay {
                    GeometryReader { shown in
                        Color.clear.preference(key: ShownHeightKey.self, value: shown.size.height)
                    }
                }
                .onPreferenceChange(FullHeightKey.self) { fullHeight = $0 }
                .onPreferenceChange(ShownHeightKey.self) { shownHeight = $0 }
                .onChange(of: fullHeight) { updateTruncation() }
                .onChange(of: shownHeight) { updateTruncation() }
        case .coming:
            // Honest about words that aren't here: never the placeholder as if the friend had said it (#3025).
            Text("No transcript yet.")
                .font(.subheadline)
                .foregroundStyle(AppColors.watchSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppColors.watchSecondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .padding(.top, 2)
                .accessibilityIdentifier("\(identifier).noTranscript")
        }
    }

    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0
    private func updateTruncation() {
        guard !isExpanded else { return }
        isTruncated = fullHeight > shownHeight + 1
    }

    /// The words VoiceOver reads after "Star for sharing:".
    private var spokenWords: String {
        if case .text(let text) = row.words { return text }
        return row.shownName
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if case .text = row.words, isTruncated || isExpanded {
                Button(isExpanded ? "See less" : "See more") { isExpanded.toggle() }
                    .foregroundStyle(AppColors.watchSecondary)
                    .frame(minHeight: 40)
                    .accessibilityIdentifier("\(identifier).more")
            }
            Spacer(minLength: 0)
            if !isPlaying {
                Button(action: jump) {
                    Label(startLabel, systemImage: startSymbol).frame(minHeight: 40).contentShape(Rectangle())
                }
                .foregroundStyle(AppColors.listeningAccent)
                .disabled(!canJump)
                .accessibilityHint(
                    !canJump ? "This Margin has no place in the \(sourceNoun.inSentence) to go to"
                        : goesTo ? SilentMarginWords.hint(noun: sourceNoun) : "Plays the lead-in, then this Margin")
                .accessibilityIdentifier("\(identifier).play")
            }
        }
        .font(.subheadline)
        .buttonStyle(.plain)
    }

    private var startLabel: String {
        (mode == .arrival ? MarginsControlCenter.RowStartContext.arrival : .playback).label
    }

    private var startSymbol: String {
        if goesTo { return "arrow.turn.down.right" } // never looks like Play when nothing is read (#4934)
        if mode == .arrival { return "play.fill" }
        return direction == .forward ? "forward.fill" : "backward.fill"
    }

    private var accessibilityLabel: String {
        var parts = ["\(row.shownName)'s Margin"]
        if let replyTo = entry.replyTo { parts.append("to \(replyTo)") }
        if let ms = row.timeMs { parts.append("at \(MarginReplyWords.clock(milliseconds: ms))") }
        switch row.hearing {
        case .unheard: parts.append("Unheard")
        case .heard: parts.append("Heard")
        case .yours: if row.isStarred { parts.append("Starred") }
        }
        if goesTo { parts.append("Not read aloud") }
        if isPlaying { parts.append("Playing") }
        switch row.words {
        case .text(let text): parts.append(text)
        case .coming: parts.append("No transcript yet")
        }
        return parts.joined(separator: ", ")
    }
}

private struct FullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ShownHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension AppColors {
    /// The unheard bar and dot (#3216), an audited token (`AppSemanticColorRGB.unheard`).
    static let unheard = dynamicColor(AppSemanticColorRGB.unheard)
}
