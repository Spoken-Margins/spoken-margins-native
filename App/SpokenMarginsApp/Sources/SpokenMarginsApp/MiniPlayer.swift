import SwiftUI
import SessionKit

/// Floats the mini player over the content, so the screen shows through behind it, and tells every screen below how
/// much room to keep free for it (#1716). The pill is an overlay, not an inset: a safe-area inset placed outside a
/// NavigationStack reaches only the stack's root, so pushed screens (Manage Feeds → Import, the Settings pages) and
/// their own bottom bars ran under the pill. Stacking the pill under the content (#1717) fixed that but left a solid
/// chin. Here the clearance travels in the environment, which does reach pushed screens, and each screen applies it
/// with `miniPlayerKeepOut()`.
struct MiniPlayerDock<Content: View, Pill: View>: View {
    /// Space between the pill and the safe area's bottom edge (the home indicator or the tab bar).
    static var bottomPadding: CGFloat { 4 }
    /// Space between the pill and the last row or pinned bar above it.
    static var gap: CGFloat { 8 }

    let showsMiniPlayer: Bool
    let pill: Pill
    let content: Content
    @State private var pillHeight: CGFloat = 0

    /// `pill` is the mini player bar; tests pass a stand-in of known height.
    init(showsMiniPlayer: Bool, @ViewBuilder pill: () -> Pill, @ViewBuilder content: () -> Content) {
        self.showsMiniPlayer = showsMiniPlayer
        self.pill = pill()
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.miniPlayerClearance, showsMiniPlayer && pillHeight > 0 ? pillHeight + Self.bottomPadding + Self.gap : 0)
            .overlay(alignment: .bottom) {
                if showsMiniPlayer {
                    pill
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pillHeight = $0 }
                        .padding(.horizontal, 12)
                        .padding(.bottom, Self.bottomPadding)
                }
            }
    }
}

extension MiniPlayerDock where Pill == MiniPlayerBar {
    init(showsMiniPlayer: Bool, @ViewBuilder content: () -> Content) {
        self.init(showsMiniPlayer: showsMiniPlayer, pill: { MiniPlayerBar() }, content: content)
    }
}

extension EnvironmentValues {
    /// How far above the safe area's bottom edge a screen's content must end to clear the floating mini player;
    /// zero when the pill isn't showing. Set by `MiniPlayerDock`, read by `miniPlayerKeepOut()`.
    @Entry var miniPlayerClearance: CGFloat = 0
}

extension View {
    /// Keeps this screen's last row and its pinned bottom bars above the floating mini player, while scroll content
    /// still passes behind the pill. Apply it to the root of every NavigationStack and to every pushed destination
    /// that can show under the pill, outside the screen's own `.safeAreaInset(edge: .bottom)` bars.
    /// `scripts/tests/test_mini_player_keep_out.py` checks that none is missed.
    func miniPlayerKeepOut() -> some View {
        modifier(MiniPlayerKeepOut())
    }
}

private struct MiniPlayerKeepOut: ViewModifier {
    @Environment(\.miniPlayerClearance) private var clearance

    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, clearance)
    }
}

struct MiniPlayerBar: View {
    /// Space between the record, play and close buttons. At 4 pt a near-miss on close ended the session and a
    /// near-miss on record started a recording (#151); 12 pt is the gap the issue's default picked.
    static let controlSpacing: CGFloat = 12

    @EnvironmentObject private var model: Gate1AppModel
    @State private var playbackTick = 0 // bumped by each progress tick: the chapter line can follow the playhead (#2074)

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    var body: some View {
        let _ = playbackTick
        layout {
            Button(action: model.openPlayback) {
                HStack(spacing: 11) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.playbackItemHeaderTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppColors.text)
                            .lineLimit(1)
                        if !dynamicTypeSize.isAccessibilitySize {
                            HStack(spacing: 7) {
                                if let chapter = model.playbackChapterHeaderTitle {
                                    Text(chapter).lineLimit(1)
                                }
                                Text(model.snapshot.status == .starting ? PlaybackStartWatch.waitingText(isMedia: model.isMediaPlaybackSnapshot) : "\(model.displayPlaybackProgressPercent)%")
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Now Playing")
            .accessibilityValue("\(model.playbackItemHeaderTitle), \(model.playbackChapterHeaderTitle ?? "Source"), \(model.displayPlaybackProgressPercent) percent")
            .accessibilityIdentifier("miniPlayer.open.button")

            HStack(spacing: Self.controlSpacing) {
                if dynamicTypeSize.isAccessibilitySize {
                    if let chapter = model.playbackChapterHeaderTitle {
                        Text(chapter)
                            .font(.caption2)
                            .foregroundStyle(AppColors.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                            .accessibilityHidden(true)
                    }
                    Text(model.snapshot.status == .starting ? PlaybackStartWatch.waitingText(isMedia: model.isMediaPlaybackSnapshot) : "\(model.displayPlaybackProgressPercent)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize()
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                }
                Button(action: model.beginInterjection) {
                    Image(systemName: "mic.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 26)
                        .foregroundStyle(AppColors.coral)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record a Margin")
                .accessibilityIdentifier("miniPlayer.interject.button")

                Button {
                    if model.snapshot.phase == .finished {
                        model.finishedPlayTapped(id: model.snapshot.itemId ?? model.selectedItem.id)
                    } else {
                        model.playPauseTapped()
                    }
                } label: {
                    Group {
                        if model.playPauseFace == .cancelStart {
                            // A start is pending and a tap cancels it: a stop mark inside the spinner says so (#2098).
                            ZStack {
                                ProgressView().tint(AppColors.onEvergreen)
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        } else {
                            Image(systemName: model.activePlaybackIsPlaying ? "pause.fill" : "play.fill")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 24)
                        }
                    }
                    .foregroundStyle(AppColors.onEvergreen)
                    .frame(width: 46, height: 46)
                    .background(AppColors.evergreen, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.playPauseFace.accessibilityLabel(isMedia: model.isMediaPlaybackSnapshot))
                .accessibilityHint(model.playPauseFace.accessibilityHint ?? "")
                .accessibilityIdentifier("miniPlayer.playPause.button")

                Button(action: model.dismissMiniPlayer) {
                    Image(systemName: "xmark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityLabel("Close and save listening session")
                .accessibilityIdentifier("miniPlayer.close.button")
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, alignment: .trailing)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .foregroundStyle(AppColors.text)
        .background(.ultraThickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppColors.evergreen.opacity(0.25)))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniPlayer.bar")
        .followsPlaybackClock(model.playbackClock, tick: $playbackTick)
    }
}
