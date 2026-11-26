import SwiftUI
import SessionKit

/// The page behind Settings' Speech Voice row (#4020): "System voice", then the iPhone's voices grouped by language, each
/// with its name above its quality. The naming and ordering rule is `SpeechVoiceMenu`, host-tested in SessionKit.
///
/// `SettingsScreen` is drawn from its inputs feed and doesn't observe the model, so this page keeps the chosen identifier
/// in its own state (the checkmark moves at once) and hands each pick to `select`.
struct SpeechVoiceListScreen: View {
    let voices: [SpeechVoiceChoice]
    let preferredLanguage: String?
    let select: (String) -> Void
    @State private var chosenIdentifier: String

    init(
        voices: [SpeechVoiceChoice],
        chosenIdentifier: String,
        preferredLanguage: String? = Locale.preferredLanguages.first,
        select: @escaping (String) -> Void
    ) {
        self.voices = voices
        self.preferredLanguage = preferredLanguage
        self.select = select
        _chosenIdentifier = State(initialValue: chosenIdentifier)
    }

    /// The Settings row builds its value text from the same rule.
    static func menu(voices: [SpeechVoiceChoice], chosenIdentifier: String, preferredLanguage: String? = Locale.preferredLanguages.first) -> SpeechVoiceMenu {
        SpeechVoiceMenu(
            voices: voices.map { SpeechVoiceMenu.Voice(id: $0.id, name: $0.name, language: $0.language, quality: $0.quality) },
            chosenIdentifier: chosenIdentifier,
            preferredLanguage: preferredLanguage)
    }

    var body: some View {
        let menu = Self.menu(voices: voices, chosenIdentifier: chosenIdentifier, preferredLanguage: preferredLanguage)
        List {
            Section {
                Button { choose("") } label: {
                    HStack {
                        Text(SpeechVoiceMenu.systemVoiceName)
                        Spacer()
                        if menu.systemVoiceIsChosen { Checkmark() }
                    }
                    .fullRow()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(menu.systemVoiceIsChosen ? .isSelected : [])
                .accessibilityIdentifier("settings.speechVoice.option.system")
            } footer: {
                // Only what was traced: "" passes no voice to the speech engine, so iOS uses its default for the language.
                Text((menu.isMissing ? "The voice you chose isn't on this iPhone any more. Pick another, or use System voice.\n" : "")
                    + "Uses the voice your iPhone picks for your language. You can change it in iOS Settings › Accessibility › Spoken Content › Voices.")
            }
            ForEach(menu.sections) { section in
                Section(section.header) {
                    ForEach(section.rows) { row in
                        Button { choose(row.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).font(.body)
                                    Text(row.quality).font(.subheadline).foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer()
                                if row.isChosen { Checkmark() }
                            }
                            .fullRow()
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(row.name), \(row.quality), \(section.header)")
                        .accessibilityAddTraits(row.isChosen ? [.isButton, .isSelected] : [.isButton])
                        .accessibilityIdentifier("settings.speechVoice.option.\(row.id)")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.bone)
        .tint(AppColors.evergreen)
        .navigationTitle("Speech Voice")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.speechVoice.screen")
    }

    private func choose(_ identifier: String) {
        guard identifier != chosenIdentifier else { return }
        chosenIdentifier = identifier
        select(identifier)
    }

    private struct Checkmark: View {
        var body: some View {
            Image(systemName: "checkmark")
                .foregroundStyle(AppColors.evergreen)
                .accessibilityHidden(true)
        }
    }
}

private extension View {
    /// A plain button in a list row takes taps on its words only; fill the row (#1436).
    func fullRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
