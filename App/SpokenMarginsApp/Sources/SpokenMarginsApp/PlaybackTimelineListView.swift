import SwiftUI
import SessionKit

/// The canonical row list for standalone Timeline and its playback window (#448).
struct PlaybackTimelineListView<Details: View>: View {
    let entries: [TimelineRailEntry]
    let currentIDs: Set<String>
    let perform: (TimelineRailEntry.Action) -> Void
    @ViewBuilder var details: (TimelineRailEntry.Action) -> Details

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                TimelineRailRow(entry: entry, isCurrent: currentIDs.contains(entry.id),
                                isFirst: index == 0, isLast: index == entries.count - 1,
                                action: { perform(entry.action) })
                    .equatable()
                    .contextMenu { details(entry.action) }
                    // The same actions for VoiceOver and Switch Control, which can't long-press (#1917).
                    .accessibilityActions { details(entry.action) }
                    .id(entry.id)
                    .accessibilityIdentifier(entry.accessibilityIdentifier)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline.rail")
    }
}

private struct TimelineRailRow: View, Equatable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: TimelineRailEntry
    let isCurrent: Bool
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.isCurrent == rhs.isCurrent && lhs.isFirst == rhs.isFirst && lhs.isLast == rhs.isLast
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
                        Text("\(entry.position)%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    if isCurrent {
                        Label(entry.currentLabel, systemImage: "speaker.wave.2.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppColors.evergreen)
                    }
                    Text(entry.title)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                        .multilineTextAlignment(.leading)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    Text(entry.detail)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 4)
                }
                .padding(15)
                .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                .background(isCurrent ? AppColors.evergreen.opacity(0.12) : surfaceColor)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .stroke(provenanceColor.opacity(entry.provenance == .assistantResponse ? 0.55 : 0.24), style: StrokeStyle(lineWidth: 1, dash: entry.provenance == .assistantResponse ? [5, 4] : []))
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(min(entry.depth, 3)) * 20)
            .padding(.bottom, 12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isCurrent ? "\(entry.currentLabel). " : "")\(entry.isNew ? "New to you. " : "")\(entry.provenanceLabel), \(entry.position) percent. \(entry.title). \(entry.detail)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
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

    private var provenanceColor: Color {
        switch entry.provenance {
        case .source, .listeningMap: AppColors.evergreen
        case .myMargin: AppColors.coral
        case .userResponse: AppColors.ochre
        case .sharedMargin, .assistantResponse: AppColors.plum
        }
    }

    private var surfaceColor: Color {
        switch entry.provenance {
        case .source: AppColors.panel
        case .listeningMap: AppColors.evergreen.opacity(0.07)
        case .myMargin: AppColors.coral.opacity(0.08)
        case .userResponse: AppColors.ochre.opacity(0.08)
        case .sharedMargin, .assistantResponse: AppColors.plum.opacity(0.07)
        }
    }
}
