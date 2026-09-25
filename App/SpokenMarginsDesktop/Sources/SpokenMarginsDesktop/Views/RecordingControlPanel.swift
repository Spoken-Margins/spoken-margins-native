import AppKit
import SwiftUI

/// An independent stop control while the microphone is active. A macOS
/// permission prompt can dismiss MenuBarExtra, and crowded menu bars can hide it.
@MainActor
final class RecordingControlPanel {
    private var panel: NSPanel?

    func show(model: DesktopModel) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recording Margin"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: RecordingControlView(model: model))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 20,
                                         y: frame.maxY - panel.frame.height - 20))
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.close()
        panel = nil
    }
}

private struct RecordingControlView: View {
    @Bindable var model: DesktopModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Button("Finish & Save") {
                Task { await model.toggleRecording() }
            }
            .buttonStyle(DesktopPrimaryButtonStyle())
            .accessibilityHint("Stops the microphone and saves this Margin")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
