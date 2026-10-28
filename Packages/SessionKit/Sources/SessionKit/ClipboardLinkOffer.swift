import Foundation

/// Whether the Library offers to add a link the listener has copied (#1379).
///
/// The Library may look at the clipboard only through calls that never read it (the change count, and
/// iOS's pattern check for "this looks like a web link"), so the app never appears to read what was
/// copied. This type holds only what those calls return and which copy the listener has already dealt
/// with. A copy is "dealt with" once the listener dismisses the offer, adds the link from it, or opens
/// the Add sheet. The next copy has a new change count and is offered afresh.
///
/// Only links are offered (owner, 2026-10-17, #1379). Other text gets no card; the listener adds it with
/// + then Paste.
public struct ClipboardLinkOffer: Equatable, Sendable {
    /// The change count of the last clipboard check, or nil before the first check.
    public private(set) var changeCount: Int?
    /// Whether the last check found a probable web link.
    public private(set) var holdsProbableLink = false
    /// The change count of the copy the listener last dealt with.
    public private(set) var handledChangeCount: Int?

    /// How long the card stays untouched before it hides itself and settles that copy (#2696).
    public static let autoDismissDelay: TimeInterval = 6
    /// The longer wait with VoiceOver on, so the card stays reachable while it is read and navigated.
    public static let voiceOverAutoDismissDelay: TimeInterval = 15

    public static func autoDismissDelay(voiceOverRunning: Bool) -> TimeInterval {
        voiceOverRunning ? voiceOverAutoDismissDelay : autoDismissDelay
    }

    /// Whether the timer may hide the card. It never does while an import runs or an error shows.
    public static func mayAutoDismiss(isAdding: Bool, isResolvingSourceLink: Bool, showsError: Bool) -> Bool {
        !(isAdding || isResolvingSourceLink || showsError)
    }

    public init(handledChangeCount: Int? = nil) {
        self.handledChangeCount = handledChangeCount
    }

    /// True while an unhandled copy that looks like a web link is on the clipboard.
    public var isOffered: Bool {
        guard holdsProbableLink, let changeCount else { return false }
        return changeCount != handledChangeCount
    }

    /// What iOS's content-free pattern checks report about the clipboard. None of these read the copied
    /// text or raise the "Allow Paste" alert, and none says how long the text is.
    public struct Signals: Equatable, Sendable {
        public var probableWebURL: Bool
        public var hasURLs: Bool
        public var hasStrings: Bool
        public var itemCount: Int
        /// The clipboard carries a URL type (`public.url`), as an address bar or a share sheet's Copy puts there.
        public var hasURLType: Bool
        /// The clipboard carries rich text (HTML, RTF, web archive, Notes types), as a passage selected on a page or in Notes does.
        public var hasRichText: Bool

        public init(probableWebURL: Bool, hasURLs: Bool, hasStrings: Bool, itemCount: Int,
                    hasURLType: Bool = false, hasRichText: Bool = false) {
            self.hasURLType = hasURLType
            self.hasRichText = hasRichText
            self.probableWebURL = probableWebURL
            self.hasURLs = hasURLs
            self.hasStrings = hasStrings
            self.itemCount = itemCount
        }

        /// Pasteboard type identifiers that mean "formatted text", not a link. Reading type names is metadata only.
        public static let richTextTypes: Set<String> = [
            "public.html", "public.rtf", "public.rtfd", "com.apple.flat-rtfd", "com.apple.webarchive",
            "com.apple.notes.richtext", "com.apple.uikit.attributedstring",
        ]

        public init(probableWebURL: Bool, hasURLs: Bool, hasStrings: Bool, itemCount: Int, types: [String]) {
            self.init(probableWebURL: probableWebURL, hasURLs: hasURLs, hasStrings: hasStrings, itemCount: itemCount,
                      hasURLType: types.contains("public.url"),
                      hasRichText: types.contains { Self.richTextTypes.contains($0) })
        }

        /// A likely link is one single clipboard item that iOS matches to a web link and that is a URL or a string.
        /// Several items are never offered. Formatted text with no URL type (a passage selected on a page) is not a
        /// link, however long or short; a URL type always is one, even beside HTML.
        public var looksLikeLink: Bool {
            probableWebURL && itemCount == 1 && (hasURLs || hasStrings) && (hasURLType || !hasRichText)
        }
    }

    /// Records a clipboard check from the content-free signals.
    public mutating func observe(changeCount: Int, signals: Signals) {
        observe(changeCount: changeCount, holdsProbableLink: signals.looksLikeLink)
    }

    /// What a Paste tap on the card got from the clipboard. The card offered a link, so it takes exactly what
    /// the link rules accept and nothing else; other text is never added from here. Every result has
    /// something to show: the link to add, or the message for why nothing was added (#2835).
    public static func pasteResult(for content: String?) -> PasteResult {
        if (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nothingPasted }
        if case .link(let url) = ClipboardIntakeClassifier.classify(content) { return .link(url) }
        return .notALink
    }

    public enum PasteResult: Equatable, Sendable {
        case link(URL)
        /// The Paste control returned no readable text: the copy changed or held something unreadable.
        case nothingPasted
        case notALink

        public var message: String? {
            switch self {
            case .link: nil
            case .nothingPasted: "Couldn't read the copied link. Copy it again, then tap Paste."
            case .notALink: "That copy is text, not a link. Use + then Paste to add text."
            }
        }
    }

    /// The link's site for the card's one line: the host without a leading "www.", or the whole address if it has none.
    public static func displayHost(of url: URL) -> String {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Records a clipboard check, on appearing, returning to the app, or a clipboard change.
    public mutating func observe(changeCount: Int, holdsProbableLink: Bool) {
        self.changeCount = changeCount
        self.holdsProbableLink = holdsProbableLink
    }

    /// The listener dismissed the offer, added the link from it, or opened the Add sheet, which has its own Paste.
    public mutating func markHandled() {
        guard let changeCount else { return }
        handledChangeCount = changeCount
    }
}
