import Foundation

/// A folder's location in words a listener can read (#3770). Full iOS paths, such as
/// `…/AppGroup/<UUID>/File Provider Storage/<opaque id>/Work/Clippings`, can't be read at a glance, so this keeps a recognised
/// prefix and at most the last three folder names, and drops every opaque identifier. Pure: a function of the path, applied to
/// its NFC form.
///
/// | Path contains | Prefix | Folder names taken from |
/// | --- | --- | --- |
/// | `Mobile Documents/com~apple~CloudDocs/` | "iCloud Drive" | after it |
/// | `Mobile Documents/iCloud~<a>~<b>/Documents/` | `<b>` with its first letter capitalized (`iCloud~md~obsidian` gives "Obsidian") | after it |
/// | `File Provider Storage/` | none (On My iPhone and other providers can't be told apart) | after it, skipping opaque components |
/// | anything else | none | the whole path |
///
/// An opaque component is a UUID, or 16 or more characters drawn only from hex digits, `-` and `_`. When names are cut, "…" comes
/// first: "iCloud Drive › … › Vault › Web › Clippings".
///
/// **The stated limit:** two folders whose prefix and last three names match look the same.
public enum FolderLocationLabel {
    public static let separator = " › "
    public static let maximumNames = 3

    /// The readable location, or nil when the path is empty or holds nothing readable (the root, or only opaque identifiers).
    public static func label(forPath rawPath: String) -> String? {
        pieces(forPath: rawPath, withCut: true)?.joined(separator: separator)
    }

    /// What VoiceOver says after "in": the same names with commas instead of the arrow, and no "…". "iCloud Drive, Obsidian, Clippings".
    public static func spokenLabel(forPath rawPath: String) -> String? {
        pieces(forPath: rawPath, withCut: false)?.joined(separator: ", ")
    }

    private static func pieces(forPath rawPath: String, withCut: Bool) -> [String]? {
        let parts = readable(rawPath)
        guard parts.prefix != nil || !parts.names.isEmpty else { return nil }
        var shown = parts.names
        var cut = false
        if shown.count > maximumNames {
            shown = Array(shown.suffix(maximumNames))
            cut = true
        }
        var pieces: [String] = []
        if let prefix = parts.prefix { pieces.append(prefix) }
        if cut, withCut { pieces.append("…") }
        pieces.append(contentsOf: shown)
        return pieces
    }

    // MARK: - Reading the path

    private static let iCloudDrive = "Mobile Documents/com~apple~CloudDocs/"
    private static let fileProvider = "File Provider Storage/"

    private static func readable(_ rawPath: String) -> (prefix: String?, names: [String]) {
        var path = rawPath.precomposedStringWithCanonicalMapping
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path.precomposedStringWithCanonicalMapping }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, []) }
        // A trailing slash is just how a folder URL is written, and empty parts of the path are dropped below.
        var slashed = trimmed + "/"
        while slashed.contains("//") { slashed = slashed.replacingOccurrences(of: "//", with: "/") }

        if let range = slashed.range(of: iCloudDrive) {
            return ("iCloud Drive", components(of: String(slashed[range.upperBound...])))
        }
        if let app = appContainer(in: slashed) {
            return (app.name, components(of: app.rest))
        }
        if let range = slashed.range(of: fileProvider) {
            return (nil, components(of: String(slashed[range.upperBound...])).filter { !isOpaque($0) })
        }
        return (nil, components(of: slashed))
    }

    /// `…/Mobile Documents/iCloud~md~obsidian/Documents/Vault/` gives ("Obsidian", "Vault/").
    private static func appContainer(in path: String) -> (name: String, rest: String)? {
        guard let start = path.range(of: "Mobile Documents/iCloud~") else { return nil }
        let afterTilde = path[start.upperBound...]
        guard let slash = afterTilde.firstIndex(of: "/") else { return nil }
        let identifier = String(afterTilde[afterTilde.startIndex..<slash])
        let remainder = String(afterTilde[afterTilde.index(after: slash)...])
        guard remainder.hasPrefix("Documents/") else { return nil }
        // The identifier's parts after "iCloud~" are `<a>~<b>`, or more; the app's own name is the last.
        guard let last = identifier.split(separator: "~").last, let first = last.first else { return nil }
        let capital = String(first).uppercased()
        let name = (capital.count == 1 ? capital : String(first)) + last.dropFirst()  // "ß" would become "SS"
        return (name, String(remainder.dropFirst("Documents/".count)))
    }

    private static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// A UUID, or 16 or more characters drawn only from hex digits, `-` and `_`.
    static func isOpaque(_ component: String) -> Bool {
        if UUID(uuidString: component) != nil { return true }
        guard component.count >= 16 else { return false }
        return component.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "0"..."9", "a"..."f", "A"..."F", "-", "_": return true
            default: return false
            }
        }
    }
}
