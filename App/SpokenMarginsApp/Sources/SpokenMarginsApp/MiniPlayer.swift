import SwiftUI
import SessionKit

/// Puts the mini player under the content instead of over it (#1716). A `.safeAreaInset` outside a
/// NavigationStack reaches only the stack's root, so pushed screens (Manage Feeds → Import, Settings
/// pages) and their own bottom bars ran under the pill. Stacking gives every screen in the stack a
/// frame that ends above the pill, so scroll content and bottom controls stay reachable.
struct MiniPlayerDock<Content: View>: View {
    let showsMiniPlayer: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 8) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsMiniPlayer {
                MiniPlayerBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }
}

struct MiniPlayerBar: View {
    @EnvironmentObject private var model: Gate1AppModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    var body: some View {
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

            HStack(spacing: 4) {
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
                .accessibilityLabel("Record an interjection")
                .accessibilityIdentifier("miniPlayer.interject.button")

                Button {
                    if model.snapshot.phase == .finished {
                        model.startNewSession(id: model.snapshot.itemId ?? model.selectedItem.id)
                    } else {
                        model.playPause()
                    }
                } label: {
                    Group {
                        if model.snapshot.status == .starting {
                            ProgressView().tint(AppColors.onEvergreen)
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
                .accessibilityLabel(model.snapshot.status == .starting ? PlaybackStartWatch.waitingText(isMedia: model.isMediaPlaybackSnapshot) : model.activePlaybackIsPlaying ? "Pause" : "Play")
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
    }
}
