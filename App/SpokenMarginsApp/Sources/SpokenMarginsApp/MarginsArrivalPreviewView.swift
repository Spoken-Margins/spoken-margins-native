import SessionKit
import SwiftUI

/// The arrival preview (owner's prototype v3, part of #3216): its own screen before listening starts. A welcome line,
/// then the same Margin list as the Margins tab with "Start with this Margin" on each row, and the two start choices
/// pinned at the bottom while the list scrolls above them. Nothing plays until the listener picks one.
struct MarginsArrivalPreviewView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var filter: PlaybackMarginsList.Filter = .all

    var body: some View {
        let source = MarginsTabSource(model: model)
        let threads = MarginsTabList.filter(MarginsTabList.threads(source.rows), filter)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MarginsArrivalPreview.welcomeLine(source.rows))
                            .font(.system(.title3, design: .serif).weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("arrival.welcome")
                        Text(MarginsArrivalPreview.explanation)
                            .font(.footnote)
                            .foregroundStyle(AppColors.watchSecondary)
                    }
                    .padding(.bottom, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(AppColors.watchSecondary.opacity(0.24)).frame(height: 1) }
                    .padding(.bottom, 4)
                    controlsLine
                    if threads.isEmpty {
                        Text("No Margins in this filter.").foregroundStyle(AppColors.watchSecondary)
                    }
                    MarginsThreadListView(
                        source: source, threads: threads, mode: .arrival, playheadMs: 0, didStart: { dismiss() })
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white)
            .background(AppColors.listeningBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { startBar(source) }
            .toolbarBackground(AppColors.listeningBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationTitle(model.selectedItem.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").font(.body.weight(.semibold)) }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("arrival.back")
                }
            }
        }
        .accessibilityIdentifier("arrival.screen")
    }

    @ViewBuilder
    private var controlsLine: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            PlaybackMarginsFilterView(selection: $filter)
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
            if model.hasEnabledImportedCommentary {
                Spacer(minLength: 0)
                MarginsAutoplayMenu()
            }
        }
    }

    /// The two start choices, pinned under the list.
    private func startBar(_ source: MarginsTabSource) -> some View {
        let firstUnheard = source.rows.first { $0.hearing == .unheard }
        return VStack(spacing: 6) {
            Button {
                guard let firstUnheard else { return }
                source.jump(to: firstUnheard, model: model)
                dismiss()
            } label: {
                Label(MarginsControlCenter.startWithUnheardLabel, systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(AppColors.interjectText)
                    .background(AppColors.listeningAccent, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(firstUnheard == nil)
            .accessibilityIdentifier("arrival.startUnheard")
            Button {
                // 0:00: the preview only shows before the listener has a place, so starting the item starts there.
                model.startItem(id: model.selectedItem.id)
                dismiss()
            } label: {
                Text(MarginsControlCenter.startFromBeginningLabel)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(.white)
                    .background(AppColors.watchControl, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppColors.watchSecondary.opacity(0.24)))
            }
            .accessibilityIdentifier("arrival.startBeginning")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(AppColors.listeningBackground)
        .overlay(alignment: .top) { Rectangle().fill(AppColors.watchSecondary.opacity(0.24)).frame(height: 1) }
    }
}
