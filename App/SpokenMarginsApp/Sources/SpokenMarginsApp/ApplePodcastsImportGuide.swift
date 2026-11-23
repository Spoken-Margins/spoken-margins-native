#if !SPOKEN_MARGINS_LEGACY
import SessionKitFeeds
import SwiftUI

/// "Import from Apple Podcasts" (#4290): a short guide pushed from the first-run drawer or Following's Follow sheet. It
/// says what the shared Shortcut does and opens its link; the Shortcut's last action opens the app's import preview
/// (#4284). It assumes nothing about its host, so a later entry (#4672's "Bring my shows") can show it unchanged. The
/// words and the link live in `ApplePodcastsImportShortcut`, the button's rules in `ApplePodcastsImportGuideState`.
struct ApplePodcastsImportGuide: View {
    /// Closes a host sheet that must not be up when the Shortcut opens the app again (Following's Follow sheet: the
    /// drawer the preview opens in can't present over it). Called once the system has taken the link, never when the
    /// link failed, so the listener still sees the failed line.
    var closeHostWhenOpened: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var state = ApplePodcastsImportGuideState()

    var body: some View {
        List {
            Section {
                Text(ApplePodcastsImportShortcut.lead)
                    .accessibilityIdentifier("applePodcasts.guide.lead")
                ForEach(Array(ApplePodcastsImportShortcut.steps.enumerated()), id: \.offset) { index, step in
                    numbered(index + 1, step)
                }
            }
            Section {
                Button(action: getShortcut) {
                    Text(ApplePodcastsImportShortcut.getButton)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .filledActionButton()
                .disabled(state.isOpening)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityHint("Opens the Shortcut in the Shortcuts app.")
                .accessibilityIdentifier("applePodcasts.guide.get")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if state.linkFailed {
                        Text(ApplePodcastsImportShortcut.linkFailed)
                            .foregroundStyle(AppColors.text)
                            .accessibilityIdentifier("applePodcasts.guide.linkFailed")
                    }
                    Text(ApplePodcastsImportShortcut.footnote)
                }
            }
            Section {
                DisclosureGroup(isExpanded: $state.showsManualSteps) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(ApplePodcastsImportShortcut.manualLead)
                        ForEach(Array(ApplePodcastsImportShortcut.manualSteps.enumerated()), id: \.offset) { index, step in
                            numbered(index + 1, step)
                        }
                        Text(ApplePodcastsImportShortcut.manualClosing).fontWeight(.semibold)
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("applePodcasts.guide.manualSteps")
                } label: {
                    Text(ApplePodcastsImportShortcut.manualTitle)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("applePodcasts.guide.manual")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColors.bone)
        .navigationTitle(ApplePodcastsImportShortcut.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("applePodcasts.guide")
    }

    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).").monospacedDigit().foregroundStyle(AppColors.secondaryText)
            Text(text)
        }
        .accessibilityElement(children: .combine)
    }

    private func getShortcut() {
        guard state.beginOpening() else { return }
        // Captured here: the host sheet may close once the link is taken, and this view with it.
        let closeHost = closeHostWhenOpened
        openURL(ApplePodcastsImportShortcut.link) { accepted in
            state.finishedOpening(accepted: accepted)
            if accepted { closeHost?() }
        }
    }
}

/// The row that opens the guide, in the drawer and in Following's Follow sheet, above "Import from another app".
struct ApplePodcastsImportRow: View {
    var closeHostWhenOpened: (() -> Void)?

    var body: some View {
        NavigationLink {
            ApplePodcastsImportGuide(closeHostWhenOpened: closeHostWhenOpened)
        } label: {
            Label(ApplePodcastsImportShortcut.title, systemImage: "antenna.radiowaves.left.and.right")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }
}
#endif
