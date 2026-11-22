#if !SPOKEN_MARGINS_LEGACY
import AppIntents

/// Makes "Add Margin" a Siri phrase the moment the app is installed (#126). An intent without an
/// `AppShortcutsProvider` only shows up in the Shortcuts app, where the listener has to build a shortcut
/// around it before Siri can run it. With this provider, "Hey Siri, add a Margin in Spoken Margins" works
/// with no setup, whether Spoken Margins or another app is playing. Siri asks "What should the Margin say?"
/// for the text and the intent writes it into the running live session, else on the playing item, else into a quick session in the Library.
///
/// The first two phrases are the ones Help teaches: "in" worked on the owner's phone (#3880), and the name-first form
/// is the fallback. "Add a Margin to/with <app>" is registered because that is how listeners naturally say it (#4814),
/// but Help does not teach it: on 2026-11-09 Siri gave "to" to Reminders even though it was registered (#3893), and
/// "with" has never been tried on a phone. A phrase moves into Help only after a phone check shows Siri asks "What
/// should the Margin say?" for it.
///
/// Every phrase must contain the application name, and a phrase can't hold a free-text parameter, so the
/// text is always asked for afterwards.
struct SpokenMarginsAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddMarginToSpokenMarginsIntent(),
            phrases: [
                "Add a Margin in \(.applicationName)",
                "\(.applicationName) add a Margin",
                "Write a Margin in \(.applicationName)",
                "Make a Margin in \(.applicationName)",
                "Margin in \(.applicationName)",
                "Add a Margin to \(.applicationName)",
                "Add a Margin with \(.applicationName)",
            ],
            shortTitle: "Add Margin",
            systemImageName: "text.bubble"
        )
        // The other route (#4923): opens the app and records, for when the screen is fine. "Add a Margin" stays the
        // dictated-text route for hands-free use (2026-11-09), so no phrase here fits it. Help teaches only the
        // Shortcut until a phone check shows Siri takes these phrases (#4814).
        AppShortcut(
            intent: RecordMarginShortcutIntent(),
            phrases: [
                "Record a Margin in \(.applicationName)",
                "\(.applicationName) record a Margin",
                "Record a voice Margin in \(.applicationName)",
                "Start recording a Margin in \(.applicationName)",
            ],
            shortTitle: "Record a Margin",
            systemImageName: "mic.fill"
        )
    }
}
#endif
