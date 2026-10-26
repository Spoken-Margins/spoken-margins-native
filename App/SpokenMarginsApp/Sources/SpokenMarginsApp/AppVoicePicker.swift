import SessionKit
import SwiftUI

/// Settings' App Voice picker (#2226, #2700). It lists a downloaded voice (Phonon, Kokoro) only once it has a player
/// in this build, is installed and may run on this chip, so nobody picks a voice that can't read to them. The rows
/// come from Settings › Voices' model, read off the main thread by its coordinator, and follow a download or Remove.
struct AppVoicePicker: View {
    @Binding var selection: AppTTSVoiceSelection
    @ObservedObject var voices: VoiceDownloadsModel

    var body: some View {
        Picker("App Voice", selection: $selection) {
            ForEach(AppTTSVoiceSelection.pickerChoices(current: selection, rows: voices.rows)) { voice in
                Text(voice.displayName).tag(voice)
            }
        }
        .accessibilityIdentifier("settings.ttsVoice.picker")
        .task { await voices.reload() }
    }
}
