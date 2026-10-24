#if !SPOKEN_MARGINS_LEGACY
import AppIntents

/// Makes "Add Margin" a Siri phrase the moment the app is installed (#126). An intent without an
/// `AppShortcutsProvider` only shows up in the Shortcuts app, where the listener has to build a shortcut
/// around it before Siri can run it. With this provider, "Hey Siri, add a Margin in Spoken Margins" works
/// with no setup, whether Spoken Margins or another app is playing. Siri asks "What should the Margin say?"
/// for the text and the intent writes it on the playing item (it says so if nothing is playing).
///
/// Every phrase must contain the application name, and a phrase can't hold a free-text parameter, so the
/// text is always asked for afterwards.
struct SpokenMarginsAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddMarginToSpokenMarginsIntent(),
            phrases: [
                "Add a Margin in \(.applicationName)",
                "Add a Margin to \(.applicationName)",
                "Add a Margin with \(.applicationName)",
                "Write a Margin in \(.applicationName)",
                "Make a Margin in \(.applicationName)",
                "Margin in \(.applicationName)",
                "\(.applicationName) add a Margin",
            ],
            shortTitle: "Add Margin",
            systemImageName: "text.bubble"
        )
    }
}
#endif
