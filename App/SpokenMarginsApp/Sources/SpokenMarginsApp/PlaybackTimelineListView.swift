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
    /// Saved live-session photos on the listener's own Margin cards (#4180). Named `photoIndex` because `index` is the
    /// row's position below.
    @ObservedObject private var photoIndex = SavedMarginPhotoIndex.shared

    var body: some View {
        let rows = entries.map(\.foldingRow)
        let foldable = Set(TimelineChapterFolding.members(in: rows).keys)
        let visibleIDs = Set(folding.visibleRows(in: rows).map(\.id))
        let visible = entries.filter { visibleIDs.contains($0.id) }
        LazyVStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                let summary = folding.summary(forChapter: entry.id, in: rows, currentIDs: currentIDs)
                let canFold = foldable.contains(entry.id)
                // 8 pt between a chapter card and its fold control, so a near miss on the control doesn't jump playback (#4778).
                HStack(alignment: .top, spacing: 8) {
                    TimelineRailRow(entry: entry, isCurrent: currentIDs.contains(entry.id),
                                    isFirst: index == 0, isLast: index == visible.count - 1,
                                    hidden: summary,
                                    clip: TimelineRowClip(entry: entry, in: clips),
                                    photo: ownMarginPhoto(entry),
                                    // Only the current card carries the position, so a playback tick redraws one row.
                                    currentLine: currentIDs.contains(entry.id) ? currentPosition?.line(for: entry.currentLabel) : nil,
                                    action: { perform(entry.action) },
                                    openClip: {
                                        if case .sourceText(let source) = entry.action { openClip(source) }
                                    })
                        .equatable()
                        .contextMenu { details(entry.action) }
                        // The same actions for VoiceOver and Switch Control, which can't long-press (#1917), and on a chapter
                        // that can fold, folding it without finding the control (#4778). One modifier, the chain the long-press
                        // menu had when it last dismissed normally (#4778).
                        .accessibilityActions {
                            details(entry.action)
                            if canFold {
                                Button(TimelineRowLines.rowFoldActionName(isFolded: summary != nil)) { toggleChapter(entry.id) }
                            }
                        }
                        .accessibilityIdentifier(entry.accessibilityIdentifier)
                    if canFold {
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

/// The control that folds a chapter (#4778): a down chevron when open, and the hidden count with a right chevron when
/// folded ("3 ›"), so the count needs no line of its own in the card. The chapter row itself still jumps there when tapped.
private struct ChapterFoldButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    /// Non-nil when the chapter is folded.
    let summary: TimelineChapterFolding.HiddenSummary?
    let action: () -> Void

    var body: some View {
        let isFolded = summary != nil
        Button(action: action) {
            (dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 2))
                : AnyLayout(HStackLayout(spacing: 4))) {
                if let summary {
                    Text(summary.countText)
                }
                Image(systemName: isFolded ? "chevron.right" : "chevron.down")
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .foregroundStyle(AppColors.secondaryText)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Short, so the chapter's title isn't read twice in a row; the count is read once, here (#4778).
        .accessibilityLabel(TimelineRowLines.foldLabel(isFolded: isFolded))
        .accessibilityValue(TimelineRowLines.foldValue(summary: summary))
        .accessibilityInputLabels(TimelineRowLines.foldInputLabels(isFolded: isFolded, title: title).map { Text($0) })
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

extension PlaybackTimelineListView {
    /// The photo of the listener's own Margin card (`.margin`); a friend's (`.sharedMargin`) and every other card get none.
    fileprivate func ownMarginPhoto(_ entry: TimelineRailEntry) -> LiveSessionPhoto? {
        guard case .margin(let row) = entry.action else { return nil }
        return photoIndex.photo(forMarginId: row.interjection.id)?.photo
    }
}

struct TimelineRailRow: View, Equatable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: TimelineRailEntry
    let isCurrent: Bool
    let isFirst: Bool
    let isLast: Bool
    /// Set when this chapter is folded: what its hidden rows hold (#3895).
    var hidden: TimelineChapterFolding.HiddenSummary? = nil
    /// Set when this table or figure has a picture saved (#3895).
    var clip: TimelineRowClip? = nil
    /// Set on the listener's own Margin card when it came from a live session with a photo (#4180). A Margin has no clip,
    /// so the two never show together.
    var photo: LiveSessionPhoto? = nil
    /// The current card's line with the listener's position (#3862); nil on other cards, and the label alone when unknown.
    var currentLine: String? = nil
    let action: () -> Void
    var openClip: () -> Void = {}

    /// Spelled out because the private environment property keeps the memberwise init private; the size test builds rows.
    init(entry: TimelineRailEntry, isCurrent: Bool, isFirst: Bool, isLast: Bool,
         hidden: TimelineChapterFolding.HiddenSummary? = nil, clip: TimelineRowClip? = nil, photo: LiveSessionPhoto? = nil,
         currentLine: String? = nil, action: @escaping () -> Void, openClip: @escaping () -> Void = {}) {
        self.entry = entry
        self.isCurrent = isCurrent
        self.isFirst = isFirst
        self.isLast = isLast
        self.hidden = hidden
        self.clip = clip
        self.photo = photo
        self.currentLine = currentLine
        self.action = action
        self.openClip = openClip
    }

    private var role: TimelineRowRole { entry.rowRole }
    private var lines: TimelineRowLines { TimelineRowLines(role: role) }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.isCurrent == rhs.isCurrent && lhs.isFirst == rhs.isFirst && lhs.isLast == rhs.isLast
            && lhs.hidden == rhs.hidden && lhs.clip == rhs.clip && lhs.photo == rhs.photo && lhs.currentLine == rhs.currentLine
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
                        // On a compact card the dot lines up with its first line (#4778).
                        .padding(.top, lines.isCompact ? 14 : 20)
                }
                .frame(width: 30)
            }

            if lines.isCompact {
                Button(action: action) {
                    compactCard
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .cardChrome(fill: surfaceColor, stroke: stroke, cornerRadius: 14)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 6)
            } else {
                Button(action: action) {
                    fullCard
                        .padding(15)
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                        .cardChrome(fill: surfaceColor, stroke: stroke, cornerRadius: 17)
                }
                .buttonStyle(.plain)
                .padding(.leading, CGFloat(min(entry.depth, 3)) * 20)
                .padding(.bottom, 12)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        // A chapter is a heading too, so the headings rotor jumps between chapters (#4778).
        .accessibilityAddTraits(lines.isHeader ? AccessibilityTraits([.isButton, .isHeader]) : AccessibilityTraits.isButton)
        .accessibilityAction { action() }
    }

    /// Today's card, for every row that carries content: passages, footnotes, scenes, Margins, replies and turns.
    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            (dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline))) {
                Label(entry.provenanceLabel, systemImage: entry.provenanceSystemImage)
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
                currentLineLabel(currentLine ?? entry.currentLabel)
            }
            Text(entry.title)
                .font(.headline)
                .foregroundStyle(AppColors.text)
                .multilineTextAlignment(.leading)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
            if let clip {
                TimelineClipPicture(clip: clip, open: openClip)
            }
            if let photo {
                LiveSessionPhotoThumbnail(source: .kept(photo), surface: .page)
            }
            // An empty detail draws nothing, rather than a blank gap (#4778).
            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 4)
            }
        }
    }

    /// A chapter or the Beginning as a header, or a page's link, picture, embed or table as a child (#4778). The type and
    /// the place each show once, and titles keep their size: the height saved comes from removed lines and padding.
    @ViewBuilder
    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch role {
            case .chapter, .beginning:
                headerLine
                if isCurrent {
                    currentLineLabel(currentLine ?? entry.currentLabel)
                } else if hidden?.containsCurrent == true {
                    // The playing row is folded away under this chapter: say so, so the listener isn't lost.
                    currentLineLabel("Playing in this chapter")
                }
                if role == .beginning, !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                }
            case .sourceElement:
                kindLine
                if isCurrent {
                    currentLineLabel(currentLine ?? entry.currentLabel)
                }
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                    .multilineTextAlignment(.leading)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                if case .sourceElement(let element) = entry.action {
                    TimelineSourceElementPreview(element: element)
                }
            case .full:
                EmptyView()
            }
        }
    }

    /// A header's first line: its icon, its title and its place. At accessibility sizes the place drops under the title,
    /// which is never cut short.
    @ViewBuilder
    private var headerLine: some View {
        let title = Text(TimelineRowLines.displayTitle(role: role, title: entry.title))
            .font(.headline)
            .foregroundStyle(AppColors.text)
            .multilineTextAlignment(.leading)
        let icon = Image(systemName: lines.leadingSystemImage ?? "list.bullet")
            .font(.caption.weight(.semibold))
            .foregroundStyle(provenanceColor)
            .accessibilityHidden(true)
        let corner = Text(entry.cornerLabel)
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppColors.secondaryText)
            .fixedSize()
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon
                    title.fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if hidden?.hasNew == true { NewMarginBadge() }
                    corner
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon
                title
                    .lineLimit(3)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if hidden?.hasNew == true { NewMarginBadge() }
                corner
            }
        }
    }

    /// A child's first line: its kind ("Link · x.com") and its place.
    private var kindLine: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            Label(lines.kindLine ?? entry.provenanceLabel, systemImage: lines.kindSystemImage ?? entry.provenanceSystemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(provenanceColor)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Text(entry.cornerLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppColors.secondaryText)
        }
    }

    private func currentLineLabel(_ text: String) -> some View {
        Label(text, systemImage: "speaker.wave.2.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.dynamicColor(TimelineRowPalette.currentLabelColor))
    }

    /// What VoiceOver reads for the row: the compact roles' words from `TimelineRowLines`, today's words on a full card.
    private var accessibilityText: String {
        if let compact = TimelineRowLines.spokenLabel(
            role: role, title: entry.title, spokenPosition: entry.spokenPosition,
            currentSpoken: isCurrent ? currentSpoken : nil,
            containsCurrent: hidden?.containsCurrent == true, detail: entry.detail) {
            return compact
        }
        let detail = entry.detail.isEmpty ? "" : " \(entry.detail)"
        return "\(isCurrent ? "\(currentSpoken). " : "")\(entry.isNew ? "New to you. " : "")\(entry.provenanceLabel), \(entry.spokenPosition). \(entry.title).\(detail)\(clipSpoken)\(photoSpoken)"
    }

    /// What VoiceOver adds when the row has a picture: its label, so it is known before the "View" action is chosen.
    private var clipSpoken: String {
        clip.map { ". \($0.spokenLabel)" } ?? ""
    }

    /// What VoiceOver adds when the Margin has a live-session photo (#4180).
    private var photoSpoken: String {
        photo == nil ? "" : ". \(LiveSessionPhotoMargin.rowAccessibilityValue)"
    }

    /// The current line as VoiceOver reads it: the separators become pauses.
    private var currentSpoken: String {
        (currentLine ?? entry.currentLabel).replacingOccurrences(of: " · ", with: ", ")
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

extension View {
    /// A Timeline card's fill, outline and corners, shared by the full and compact cards.
    fileprivate func cardChrome(fill: Color, stroke: TimelineRowPalette.Stroke, cornerRadius: CGFloat) -> some View {
        background(fill)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColors.dynamicColor(stroke.color).opacity(stroke.alpha),
                            style: StrokeStyle(lineWidth: CGFloat(stroke.width), dash: stroke.dashed ? [5, 4] : []))
            }
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
