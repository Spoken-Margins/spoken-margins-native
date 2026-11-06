import Foundation

/// A photo of the page, slide or whiteboard a live-session Margin is about (#2708). The picture itself is a file on
/// this phone; this value is the reference to it and the facts the app needs without opening it.
///
/// Rules this type holds, so the camera code that comes later cannot get them wrong:
/// - The path is relative to the app's data folder and sits under `folder`, never absolute and never with `..`, so a
///   session file copied to another phone, or a crafted one, cannot point outside the app's own storage.
/// - A photo is downscaled before it is kept: `fitted(width:height:)` gives the size, and `init` refuses anything over
///   `maxLongEdgePixels` or `maxByteCount`. The listener's own copy of a page is not a reason to fill the phone.
/// - A photo never travels. No packet, share link or manifest names this type (`LiveSessionPhotoTests` fails if
///   `SessionKitSharing` mentions it), so a Margin shared from a session loses its photo unless a later, explicit step
///   adds one.
/// - It is optional on `LiveSessionMargin`, so a session saved by an earlier build reads unchanged and an earlier
///   build reading a new one ignores it.
public struct LiveSessionPhoto: Codable, Equatable, Hashable, Sendable {
    /// Where photos live, under the app's data folder.
    public static let folder = "SpokenMargins/live-photos"
    /// The longest side a kept photo may have. Enough to read a printed page; a full-resolution shot is far more.
    public static let maxLongEdgePixels = 2_048
    /// The most a kept photo may take: 1.5 MB.
    public static let maxByteCount = 1_500_000
    static let allowedExtensions: Set<String> = ["jpg", "jpeg", "heic"]

    /// Relative to the app's data folder: "SpokenMargins/live-photos/<session>/<margin>.jpg".
    public private(set) var path: String
    public private(set) var widthPx: Int
    public private(set) var heightPx: Int
    public private(set) var byteCount: Int

    public init?(path: String, widthPx: Int, heightPx: Int, byteCount: Int) {
        guard Self.isValid(path: path),
              widthPx > 0, heightPx > 0, max(widthPx, heightPx) <= Self.maxLongEdgePixels,
              byteCount > 0, byteCount <= Self.maxByteCount
        else { return nil }
        self.path = path
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.byteCount = byteCount
    }

    /// Decoding does not throw for a photo that breaks the rules (one bad reference must not lose the whole session);
    /// callers read it through `LiveSessionMargin.validPhoto`, which is nil for such a photo.
    public var isWithinRules: Bool {
        Self.isValid(path: path) && widthPx > 0 && heightPx > 0 && max(widthPx, heightPx) <= Self.maxLongEdgePixels
            && byteCount > 0 && byteCount <= Self.maxByteCount
    }

    /// True for a path inside `folder` with a photo extension and no empty, `.` or `..` part.
    public static func isValid(path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("%"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return false }
        let prefix = folder.split(separator: "/").map(String.init)
        guard parts.count > prefix.count + 1, Array(parts.prefix(prefix.count)) == prefix else { return false }
        let ext = (parts.last! as NSString).pathExtension.lowercased()
        return allowedExtensions.contains(ext)
    }

    /// The size to scale a captured picture to: never larger than the original, the longest side at most
    /// `maxLongEdgePixels`, the shape kept, and at least one pixel on each side. Nil for a picture with no size.
    public static func fitted(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let longest = max(width, height)
        guard longest > maxLongEdgePixels else { return (width, height) }
        let scale = Double(maxLongEdgePixels) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// A picture of a page needs a text alternative (VoiceOver, the export): the listener's own words if they gave
    /// any, else the place they named, else a plain description.
    public static func altText(text: String, whereNote: String?, place: LiveSessionPlace?) -> String {
        // One line, at most 120 characters: it goes in a single line of the export and on a VoiceOver label.
        var words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if words.count > 120 { words = String(words.prefix(120)) + "…" }
        if !words.isEmpty { return "Photo with Margin: " + words }
        if let place { return "Photo of the page at \(place.label)" }
        if let note = whereNote?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !note.isEmpty {
            return "Photo of the page at \(note.prefix(60))"
        }
        return "Photo of the page"
    }
}

extension LiveSessionMargin {
    /// The photo, when it keeps the rules; a session file edited or damaged by hand can carry one that does not.
    public var validPhoto: LiveSessionPhoto? { photo.flatMap { $0.isWithinRules ? $0 : nil } }

    /// The text alternative for this Margin's photo; nil when it has none.
    public var photoAltText: String? {
        validPhoto.map { _ in LiveSessionPhoto.altText(text: text, whereNote: whereNote, place: place) }
    }
}
