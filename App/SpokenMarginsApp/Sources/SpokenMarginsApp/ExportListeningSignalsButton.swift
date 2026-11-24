import SwiftUI

/// The **Export Listening Signals** button (#4050), in Settings › Privacy & Legal and on the Your AI screen (#4683, Design 2b,
/// section 4). Moved out of `SettingsScreen` unchanged so both places say the same thing: "Export Listening Signals", or
/// "Nothing Recorded Yet" once an export found nothing, and disabled while it exports. Each place writes its own caption.
struct ExportListeningSignalsButton: View {
    /// Builds the export file, or nil when nothing is recorded yet.
    let exportFileURL: @MainActor () async -> URL?
    let accessibilityIdentifier: String
    @State private var isExporting = false
    @State private var hasNoListeningSignals = false

    var body: some View {
        Button {
            isExporting = true
            Task {
                defer { isExporting = false }
                let url = await exportFileURL()
                #if canImport(UIKit)
                if let url { ShareFilePresenter.present(fileURL: url) }
                #endif
                hasNoListeningSignals = url == nil
            }
        } label: {
            Label(
                hasNoListeningSignals ? "Nothing Recorded Yet" : "Export Listening Signals",
                systemImage: "doc.text"
            )
            // A borderless button in a `Form` row only takes taps on its label's own size (#1436).
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(accessibilityIdentifier)
        .disabled(isExporting)
    }
}
