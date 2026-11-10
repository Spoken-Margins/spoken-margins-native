import SwiftUI

/// What the record button is called, to the eye and to Voice Control (#3849). VoiceOver reads `spoken`. Voice Control
/// matches what a listener says against the button's input labels, and "Tap Add a Margin" has to find it, so the
/// words drawn on the button, at either text size, are among them.
enum MarginRecordNames {
    static let spoken = "Record a Margin"

    static func visible(accessibilitySize: Bool) -> String { accessibilitySize ? "Record" : "Add a Margin" }

    /// The first label is the one Voice Control shows when it numbers or names controls.
    static let inputLabels = [visible(accessibilitySize: false), spoken, visible(accessibilitySize: true)]
}

/// Add a Margin (spoken) with the pencil (written) beside it. The playback screen and the live session draw
/// the same row; each passes its own actions and identifiers.
struct MarginAddButtons: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let record: () -> Void
    let write: () -> Void
    let recordIdentifier: String
    let writeIdentifier: String
    var isDisabled = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: record) {
                Label(MarginRecordNames.visible(accessibilitySize: dynamicTypeSize.isAccessibilitySize), systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(InterjectButtonStyle())
            .accessibilityLabel(MarginRecordNames.spoken)
            .accessibilityInputLabels(MarginRecordNames.inputLabels)
            .accessibilityIdentifier(recordIdentifier)
            Button(action: write) {
                Image(systemName: "square.and.pencil")
                    .resizable()
                    .scaledToFit()
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 32 : 24, height: dynamicTypeSize.isAccessibilitySize ? 32 : 24)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(InterjectButtonStyle())
            .accessibilityLabel("Write a Margin")
            .accessibilityIdentifier(writeIdentifier)
        }
        .disabled(isDisabled)
    }
}

struct InterjectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(minHeight: 52)
            .foregroundStyle(AppColors.interjectText)
            .background(AppColors.captureBackground.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
