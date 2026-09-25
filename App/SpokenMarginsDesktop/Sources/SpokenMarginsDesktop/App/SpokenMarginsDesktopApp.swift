import SwiftUI

@main
struct SpokenMarginsDesktopApp: App {
    @NSApplicationDelegateAdaptor(DesktopApplicationDelegate.self) private var applicationDelegate
    @State private var model = DesktopModel()

    var body: some Scene {
        MenuBarExtra {
            CompanionView(model: model)
                .task { await model.monitorPlayback() }
        } label: {
            Image(systemName: model.isRecording ? "record.circle.fill" :
                    model.isPlaying ? "speaker.wave.2.fill" : "quote.bubble.fill")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 18, height: 18)
                .accessibilityLabel(model.isRecording ? "Spoken Margins, recording" :
                                    model.isPlaying ? "Spoken Margins, playing" : "Spoken Margins")
        }
        .menuBarExtraStyle(.window)

        Settings {
            DesktopSettingsView(model: model)
        }
    }
}
