#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation

enum FollowPodcastsShortcutError: Error, Equatable, LocalizedError {
    case noLinks
    case sheetOpen
    case stillFollowing
    case appNotReady

    var errorDescription: String? {
        switch self {
        case .noLinks:
            return "No podcast links were passed in. In Shortcuts, use Get Podcasts from Library, then pass each podcast's Feed URL detail."
        case .sheetOpen:
            return "Close the sheet that's open in Spoken Margins, then run the Shortcut again."
        case .stillFollowing:
            return "Spoken Margins is still following the podcasts from the last run. Try again when it finishes."
        case .appNotReady:
            return "Spoken Margins could not open its import. Try the Shortcut again."
        }
    }
}

/// #4284: Apple Podcasts on iPhone has no OPML export, so its listeners bring their shows in with a Shortcut:
/// Get Podcasts from Library, Get Details of Podcast (Feed URL), then this action. It opens Spoken Margins on the
/// same preview an OPML file gets (new, already followed, repeated, unusable) and follows nothing on its own.
/// An App Intent rather than a spokenmargins:// link, which could fail to open the app (#136).
struct FollowPodcastsInSpokenMarginsIntent: AppIntent {
    static let title: LocalizedStringResource = "Follow Podcasts in Spoken Margins"
    static let description = IntentDescription(
        "Opens Spoken Margins on a preview of the podcasts passed in, showing which are new, already followed or unusable. Nothing is followed until you tap Follow. Pass each podcast's Feed URL from Get Podcasts from Library; a line may also carry the show's name before its link."
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(
        title: "Podcast Feed Links",
        description: "Feed links, one per podcast. Text with one link per line works too."
    )
    var links: [String]

    static var parameterSummary: some ParameterSummary {
        Summary("Follow \(\.$links) in Spoken Margins")
    }

    @MainActor func perform() async throws -> some IntentResult {
        try await FollowPodcastsShortcutBridge.open(links)
        return .result()
    }
}

@MainActor
enum FollowPodcastsShortcutBridge {
    static weak var catalogDrawer: CatalogDrawerModel?
    /// Loads the Library's follows before the preview reads them. A Shortcut can launch the app and get here
    /// before the root view has, and an unloaded list would show followed shows as new.
    static var prepare: (@MainActor () async -> Void)?
    /// Whether another of the root's sheets is up: the drawer can't present over it.
    static var sheetIsOpen: (@MainActor () -> Bool)?

    /// Hands the links to the drawer's import preview. Throws, so Shortcuts shows why, when nothing was passed
    /// in, another sheet is in the way, the last list is still following, or the app has no drawer to open.
    static func open(_ links: [String], drawer: CatalogDrawerModel? = catalogDrawer) async throws {
        guard links.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw FollowPodcastsShortcutError.noLinks
        }
        if sheetIsOpen?() == true { throw FollowPodcastsShortcutError.sheetOpen }
        if drawer?.shortcutImport?.isFollowing == true { throw FollowPodcastsShortcutError.stillFollowing }
        await prepare?()
        guard let drawer, drawer.openShortcutImport(feedLinks: links) else {
            throw FollowPodcastsShortcutError.appNotReady
        }
    }
}
#endif
