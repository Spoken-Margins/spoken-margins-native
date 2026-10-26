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

    /// What a Paste tap on the card does with the clipboard's text. The card offered a link, so it adds
    /// exactly what the link rules accept and nothing else; other text is never added from here.
    public static func pasteOutcome(for content: String?) -> PasteOutcome {
        if case .link = ClipboardIntakeClassifier.classify(content) { return .addLink }
        return .notALink
    }

    public enum PasteOutcome: Equatable, Sendable {
        case addLink
        case notALink

        public var message: String? {
            switch self {
            case .addLink: nil
            case .notALink: "That copy is text, not a link. Use + then Paste to add text."
            }
        }
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
