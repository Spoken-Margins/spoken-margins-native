import SwiftUI

/// #2852: the one prompt a new listener sees once audio is on. Tapping it is Add a Margin; the microphone
/// explanation and the written fallback belong to that flow. It never comes back after a tap, a dismiss, or a first Margin.
struct FirstMarginPromptCard: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        HStack(spacing: 4) {
            Button(action: model.addFirstMargin) {
                HStack(spacing: 12) {
                    Image(systemName: "mic.fill")
                        .font(.title3)
                        .foregroundStyle(AppColors.listeningAccent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tap to add a Margin").font(.headline)
                        Text("Say what you're thinking. It stays with the passage you're hearing.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("playback.firstMargin.prompt")
            Button(action: model.dismissFirstMarginPrompt) {
                TapTargetIcon(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("playback.firstMargin.dismiss")
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
