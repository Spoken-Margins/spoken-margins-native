import SwiftUI
import SessionKit

/// Where the listener is now, for the current card's line (#3862): the clock and percent on media, the percent on text.
/// Built from the playback snapshot only while the Timeline's item is the one playing.
struct TimelineCurrentPosition: Equatable {
    var isMedia: Bool
    var ms: Int?
    var percent: Int?

    func line(for currentLabel: String) -> String {
        TimelinePositionLabel.currentLine(currentLabel: currentLabel, currentMs: ms, percent: percent, isMedia: isMedia)
    }
}

/// The canonical row list for standalone Timeline and its playback window (#448).
/// A chapter row folds and unfolds the rows under it (#3895); `folding` says which are folded.
struct PlaybackTimelineListView<Details: View>: View {
    let entries: [TimelineRailEntry]
    let currentIDs: Set<String>
    var folding = TimelineChapterFolding()
    var toggleChapter: (String) -> Void = { _ in }
    /// Added to the current card's line, so the listener can compare their place with the cards' (#3862).
    var currentPosition: TimelineCurrentPosition? = nil
    let perform: (TimelineRailEntry.Action) -> Void
    /// Opens the picture of a table or figure row at full screen (#3895).
    var openClip: (TimelineSourceContent.Entry) -> Void = { _ in }
    @ViewBuilder var details: (TimelineRailEntry.Action) -> Details
    @Environment(\.timelineClips) private var clips

    var body: some View {
        let rows = entries.map(\.foldingRow)
        let foldable = Set(TimelineChapterFolding.members(in: rows).keys)
        let visibleIDs = Set(folding.visibleRows(in: rows).map(\.id))
        let visible = entries.filter { visibleIDs.contains($0.id) }
        LazyVStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                let summary = folding.summary(forChapter: entry.id, in: rows, currentIDs: currentIDs)
                HStack(alignment: .top, spacing: 0) {
                    TimelineRailRow(entry: entry, isCurrent: currentIDs.contains(entry.id),
                                    isFirst: index == 0, isLast: index == visible.count - 1,
                                    hidden: summary,
                                    clip: TimelineRowClip(entry: entry, in: clips),
                                    // Only the current card carries the position, so a playback tick redraws one row.
                                    currentLine: currentIDs.contains(entry.id) ? currentPosition?.line(for: entry.currentLabel) : nil,
                                    action: { perform(entry.action) },
                                    openClip: {
                                        if case .sourceText(let source) = entry.action { openClip(source) }
                                    })
                        .equatable()
                        .contextMenu { details(entry.action) }
                        // The same actions for VoiceOver and Switch Control, which can't long-press (#1917).
                        .accessibilityActions { details(entry.action) }
                        .accessibilityIdentifier(entry.accessibilityIdentifier)
                    if foldable.contains(entry.id) {
                        ChapterFoldButton(title: entry.title, summary: summary) { toggleChapter(entry.id) }
                            .accessibilityIdentifier("timeline.chapter.fold.\(entry.id)")
                    }
                }
                .id(entry.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.rail")
    }
}

/// The chevron that folds a chapter. The chapter row itself still jumps there when tapped.
private struct ChapterFoldButton: View {
    let title: String
    /// Non-nil when the chapter is folded.
    let summary: TimelineChapterFolding.HiddenSummary?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: summary == nil ? "chevron.down" : "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(AppColors.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 24)
        .accessibilityLabel(summary == nil ? "Collapse chapter \(title)" : "Expand chapter \(title)")
        .accessibilityValue(summary?.text ?? "Expanded")
    }
}

extension TimelineRailEntry {
    /// What chapter folding needs to know about this row. Chapters, from the source or from a podcast's own
    /// chapter list, open a section; scenes, Margins, figures and the rest sit inside the chapter they fall in.
    var foldingRow: TimelineChapterFolding.Row {
        let isChapter: Bool
        switch action {
        case .chapter, .mediaChapter: isChapter = true
        default: isChapter = false
        }
        return .init(id: id, isChapter: isChapter, isNew: isNew)
    }
}

private struct TimelineRailRow: View, Equatable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: TimelineRailEntry
    let isCurrent: Bool
    let isFirst: Bool
    let isLast: Bool
    /// Set when this chapter is folded: what its hidden rows hold (#3895).
    var hidden: TimelineChapterFolding.HiddenSummary? = nil
    /// Set when this table or figure has a picture saved (#3895).
    var clip: TimelineRowClip? = nil
    /// The current card's line with the listener's position (#3862); nil on other cards, and the label alone when unknown.
    var currentLine: String? = nil
    let action: () -> Void
    var openClip: () -> Void = {}

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.isCurrent == rhs.isCurrent && lhs.isFirst == rhs.isFirst && lhs.isLast == rhs.isLast
            && lhs.hidden == rhs.hidden && lhs.clip == rhs.clip && lhs.currentLine == rhs.currentLine
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(AppColors.border)
                        .frame(width: 2)
                        .padding(.top, isFirst ? 22 : 0)
                        .padding(.bottom, isLast ? 44 : 0)
                    provenanceMarker
                        .padding(.top, 20)
                }
                .frame(width: 30)
            }

            Button(action: action) {
                VStack(alignment: .leading, spacing: 7) {
                    (dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline))) {
                        Label(entry.provenanceLabel, systemImage: entry.provenance.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(provenanceColor)
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.isNew { NewMarginBadge() }
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Text(entry.cornerLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    if isCurrent {
                        Label(currentLine ?? entry.currentLabel, systemImage: "speaker.wave.2.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.dynamicColor(TimelineRowPalette.currentLabelColor))
                    } else if hidden?.containsCurrent == true {
                        // The playing row is folded away under this chapter: say so, so the listener isn't lost.
                        Label("Playing in this chapter", systemImage: "speaker.wave.2.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.dynamicColor(TimelineRowPalette.currentLabelColor))
                    }
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    if let clip {
                        TimelineClipPicture(clip: clip, open: openClip)
                    }
                    Text(entry.detail)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 4)
                    if case .sourceElement(let element) = entry.action {
                        TimelineSourceElementPreview(element: element)
                    }
                    if let hidden {
                        Text(hidden.text)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                .padding(15)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                .background(surfaceColor)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(AppColors.dynamicColor(stroke.color).opacity(stroke.alpha),
                                style: StrokeStyle(lineWidth: CGFloat(stroke.width), dash: stroke.dashed ? [5, 4] : []))
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(min(entry.depth, 3)) * 20)
            .padding(.bottom, 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isCurrent ? "\(currentSpoken). " : "")\(entry.isNew ? "New to you. " : "")\(entry.provenanceLabel), \(entry.spokenPosition). \(entry.title). \(entry.detail)\(clipSpoken)\(hiddenSpoken)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }

    /// What VoiceOver adds when the row has a picture: its label, so it is known before the "View" action is chosen.
    private var clipSpoken: String {
        clip.map { ". \($0.spokenLabel)" } ?? ""
    }

    /// The current line as VoiceOver reads it: the separators become pauses.
    private var currentSpoken: String {
        (currentLine ?? entry.currentLabel).replacingOccurrences(of: " · ", with: ", ")
    }

    /// What VoiceOver adds after a folded chapter's own words: what is hidden, and whether the playhead is in it.
    private var hiddenSpoken: String {
        guard let hidden else { return "" }
        return ". \(hidden.text)" + (hidden.containsCurrent && !isCurrent ? ", playing here" : "")
    }

    @ViewBuilder
    private var provenanceMarker: some View {
        switch entry.provenance {
        case .source:
            Circle().fill(provenanceColor).frame(width: 13, height: 13)
        case .listeningMap:
            Image(systemName: "map").font(.caption.bold()).foregroundStyle(provenanceColor)
        case .myMargin:
            RoundedRectangle(cornerRadius: 2).fill(provenanceColor).frame(width: 13, height: 13).rotationEffect(.degrees(45))
        case .userResponse:
            Circle().stroke(provenanceColor, lineWidth: 3).frame(width: 14, height: 14)
        case .sharedMargin:
            Image(systemName: "person.2.fill").font(.caption.bold()).foregroundStyle(provenanceColor)
        case .assistantResponse:
            Image(systemName: "sparkle").font(.caption.bold()).foregroundStyle(provenanceColor)
        }
    }

    private var rowKind: TimelineRowKind { entry.provenance.rowKind }

    private var stroke: TimelineRowPalette.Stroke {
        TimelineRowPalette.stroke(kind: rowKind, isCurrent: isCurrent)
    }

    private var provenanceColor: Color {
        AppColors.dynamicColor(TimelineRowPalette.labelColor(kind: rowKind))
    }

    private var surfaceColor: Color {
        let fill = TimelineRowPalette.fill(kind: rowKind, isCurrent: isCurrent)
        return AppColors.dynamicColor(fill.color).opacity(fill.alpha)
    }
}

extension TimelineProvenance {
    /// The palette kind of this row. Exhaustive on purpose: a new provenance has no colours until it is mapped here.
    var rowKind: TimelineRowKind {
        switch self {
        case .source: .source
        case .listeningMap: .listeningMap
        case .myMargin: .myMargin
        case .userResponse: .userResponse
        case .sharedMargin: .sharedMargin
        case .assistantResponse: .assistantResponse
        }
    }
}

/// What a picture, embed or table row shows under its words: the page's own picture (a GIF plays), a video's still,
/// or the first rows of the table (owner, 2026-11-14). A picture loads when its row is drawn (owner, 2026-11-17), so
/// the import itself still fetches nothing but the page (#2032). A link row has no preview; tapping it opens the link.
private struct TimelineSourceElementPreview: View {
    let element: SourceElement

    var body: some View {
        if let url = element.previewImageURL {
            SourcePictureView(url: url, accessibilityText: element.altText ?? element.label, maxPixelSize: 900)
                .frame(maxHeight: 260)
                .padding(.top, 4)
        } else if element.kind == .table, let rows = element.rows {
            SourceTableView(rows: rows, bodyRowLimit: 4)
                .padding(.top, 4)
        }
    }
}
