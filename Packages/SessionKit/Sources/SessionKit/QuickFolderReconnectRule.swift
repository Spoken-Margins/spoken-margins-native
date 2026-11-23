import Foundation

/// What choosing a folder again means for the Quick Folder's remembered files (#3770, Design PR 2). A folder the app can no longer
/// open ("Can't open this folder") is fixed with "Choose Folder Again". If the listener picks the folder it already had, the app
/// reconnects and keeps what the last scan learned: the folder's path, when it was last checked and its problem. Any other folder,
/// or a stored path that is unknown, is a different folder, and those are dropped. The files dismissed from Following stay either
/// way. Nothing here queues anything: new files only wait on Following (#4274).
///
/// Pure: two paths in, one decision out. The paths are compared in a standard form, so a trailing slash, a doubled slash, a `.` or
/// `..` component, Unicode normalization (NFC against NFD names) and iOS's `/private/var` against `/var` do not make the same
/// folder look different. Case is not folded: two paths that differ only in case count as different folders. That is the safe
/// direction, because the cost of a wrong "different" is only forgetting the last scan's path and time until the next scan.
public enum QuickFolderReconnectRule {
    public enum Decision: Equatable, Sendable {
        /// The same folder: keep what the last scan learned (path, last checked, problem).
        case keepSeenFiles
        /// A different folder, or an unknown stored path: drop what the last scan learned.
        case freshBaseline
    }

    /// The decision for `chosenPath` against the path a scan stored (`quickAccessFolderPath`), nil until one has finished.
    public static func decide(storedPath: String?, chosenPath: String) -> Decision {
        guard let storedPath else { return .freshBaseline }
        let stored = standardized(storedPath)
        let chosen = standardized(chosenPath)
        guard !stored.isEmpty, stored == chosen else { return .freshBaseline }
        return .keepSeenFiles
    }

    /// The path in the form two paths are compared in. Empty for an empty path. Always absolute-looking when the input was: a
    /// relative path keeps no leading slash.
    public static func standardized(_ rawPath: String) -> String {
        var path = rawPath.precomposedStringWithCanonicalMapping
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path.precomposedStringWithCanonicalMapping }
        let isAbsolute = path.hasPrefix("/")
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                if let last = parts.last, last != ".." { parts.removeLast() } else if !isAbsolute { parts.append(part) }
            default: parts.append(part)
            }
        }
        // iOS and macOS spell the same folder `/private/var/...` and `/var/...` (and `tmp`, `etc`).
        if isAbsolute, parts.count >= 2, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) { parts.removeFirst() }
        let joined = parts.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }
}
