#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation
import SessionKit
import SessionKitPersistence

/// The text behind the Today's Margins action (#1991): the day's Margins as Markdown. The read runs off the main
/// actor through `StoreReader` (a time-of-day automation can run it before any screen has loaded), the rules for what
/// counts and how it reads are `TodaysMarginsDigest` in SessionKit. Nothing here writes, and nothing leaves the phone
/// until the listener's own shortcut passes the text on.
enum TodaysMarginsShortcutAction {
    static func text(
        store: SQLiteSessionStore?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current
    ) async throws -> String {
        guard let store else { throw AddMarginShortcutError.libraryUnavailable }
        let entries = try await StoreReader(store).todaysMargins(on: now, calendar: calendar)
        return TodaysMarginsDigest.markdown(entries, day: now, calendar: calendar, locale: locale)
    }
}

/// Returns the Margins the listener made today, so a Shortcuts automation can hand them to their own notes app or
/// chatbot. It reads only; opening the app is not needed.
struct TodaysMarginsIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's Margins"
    static let description = IntentDescription(
        "Returns every Margin you made today, oldest first, as text: the episode, article or PDF it is on, the time you made it, where in it you were, and your words. Spoken Margins sends nothing anywhere; pass the text to any action you like."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // The same weak reference the Add Margin action uses; the app sets it at launch, including when a shortcut
        // launches the app in the background.
        guard let model = ListeningEditionShortcutBridge.model else {
            throw AddMarginShortcutError.libraryUnavailable
        }
        return .result(value: try await TodaysMarginsShortcutAction.text(store: model.store))
    }
}
#endif
