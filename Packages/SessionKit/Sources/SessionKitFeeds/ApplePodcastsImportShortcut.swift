import Foundation

/// "Import from Apple Podcasts" (#4290). Apple Podcasts on iPhone has no export, so its listeners bring their shows
/// in with a shared Shortcut that ends in the app's "Follow Podcasts in Spoken Margins" action (#4284). This holds the
/// link to that Shortcut and every word the guide screen says, so the app's two entry points (the first-run drawer and
/// Following's Follow sheet) and any later one say the same thing, and the words are host-tested.
public enum ApplePodcastsImportShortcut {
    /// The owner's shared Shortcut, recorded on #4290 on 2026-11-21 "after the space fix". A build-time constant: it is
    /// never read from the network or the device, so a changed link reaches listeners only in a new build. The manual
    /// steps below are the way out if this link ever stops working.
    public static let link = URL(string: "https://www.icloud.com/shortcuts/ccb7e3db856a48a2b90799a05331a9cc")!

    /// The first shared link held the version that passed bare feed links; it must never come back.
    static let retiredShortcutIDs: Set<String> = ["4c0ec26e54da4e0180b34b4c89f2b0e8"]

    public static let title = "Import from Apple Podcasts"
    public static let lead = "Apple Podcasts can't export a list of your shows. A Shortcut can pass them to Spoken Margins."
    public static let steps = [
        "Tap Get the Shortcut, then Add Shortcut.",
        "In Shortcuts, run Import from Apple Podcasts. Spoken Margins opens on your list. Nothing is followed until you tap Follow.",
    ]
    public static let getButton = "Get the Shortcut"
    public static let footnote = "iOS may ask if Shortcuts can read your podcasts. Tap Allow. Shows that exist only in Apple Podcasts, with no public feed, can't be followed here."
    public static let linkFailed = "That link didn't open. You can make the Shortcut yourself instead."

    public static let manualTitle = "Make it yourself"
    public static let manualLead = "In the Shortcuts app, make a new Shortcut with these three actions."
    public static let manualSteps = [
        "Get Podcasts from Library.",
        "Repeat with Each. Inside it, add a Text action: the podcast's Name, then one space, then the podcast's Feed URL.",
        "After the loop, Follow Podcasts in Spoken Margins, with the Repeat Results as the links.",
    ]
    public static let manualClosing = "The space between the name and the link matters."

    /// What Shortcuts shows when the action got no links: written for both a listener who built the Shortcut and one
    /// who added ours, whose Apple Podcasts library may hold nothing with a public feed.
    public static let noLinksMessage = "No podcast links came through. If you made this Shortcut yourself, pass each show's Feed URL from Get Podcasts from Library. If you added ours, your Apple Podcasts library may have no shows with a public feed."

    /// The guide's whole text in reading order, as VoiceOver and a listener reading aloud meet it.
    public static var readingOrder: [String] {
        [title, lead] + steps + [getButton, footnote, manualTitle, manualLead] + manualSteps + [manualClosing]
    }
}

/// The guide's button and its failed-link line (#4290). One link opens per tap, however fast the taps come; a link the
/// system wouldn't open shows the failed line and opens "Make it yourself". The listener can close and reopen the
/// manual steps at any time. Coming back from Shortcuts changes nothing.
public struct ApplePodcastsImportGuideState: Equatable, Sendable {
    public private(set) var isOpening = false
    public private(set) var linkFailed = false
    public var showsManualSteps = false

    public init() {}

    /// The button was tapped. False when a link is already on its way, so a second tap opens nothing.
    public mutating func beginOpening() -> Bool {
        guard !isOpening else { return false }
        isOpening = true
        return true
    }

    /// The system answered whether it opened the link.
    public mutating func finishedOpening(accepted: Bool) {
        isOpening = false
        linkFailed = !accepted
        if !accepted { showsManualSteps = true }
    }
}
