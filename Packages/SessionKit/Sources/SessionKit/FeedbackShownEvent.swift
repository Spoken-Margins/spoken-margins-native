import Foundation

/// The playback-event record for a banner (toast) the listener was shown, or was refused (#3344).
///
/// Toast text can hold an item title ("Could not import My Secret Plans"), so the export never carries it
/// (`DiagnosticsExport.keyMayContainUserContent`, #968). This record carries what lets a tester tell which
/// toast it was without the words: the kind, the code location that raised it, a short hash of the text, and
/// whether it had a button. Nothing the listener typed, pasted or chose reaches the fields.
public enum FeedbackShownEvent {
    /// Record kind when the banner was put on screen.
    public static let shownKind = "feedback.shown"
    /// Record kind when `FeedbackBannerPolicy.mayReplace` refused it, so the listener never saw it.
    public static let suppressedKind = "feedback.suppressed"

    /// Longest file name kept in `site`. A real one is `File.swift:123`.
    static let maxSiteLength = 80

    public static func kind(suppressed: Bool) -> String {
        suppressed ? suppressedKind : shownKind
    }

    /// - Parameters:
    ///   - fileID: the `#fileID` of the code that raised the toast ("Module/File.swift").
    ///   - line: its `#line`.
    ///   - message: used only to make `textToken`; it is never stored.
    public static func fields(
        kind: FeedbackBannerPolicy.Kind,
        fileID: String,
        line: Int,
        message: String,
        hasAction: Bool,
        replaced: Bool,
        suppressed: Bool
    ) -> [String: String] {
        [
            "kind": kindName(kind),
            "site": site(fileID: fileID, line: line),
            "textToken": DiagnosticsExport.token(message),
            "hasAction": String(hasAction),
            "replaced": String(replaced && !suppressed),
            "suppressed": String(suppressed),
        ]
    }

    static func kindName(_ kind: FeedbackBannerPolicy.Kind) -> String {
        switch kind {
        case .success: return "success"
        case .warning: return "warning"
        case .error: return "error"
        }
    }

    /// `File.swift:123` from `Module/File.swift` and 123. The compiler makes `#fileID` a module and a file
    /// name. This keeps only a short run of file-name characters, so a caller that passes anything else
    /// (a title, a path) gets `unknown` and never leaks it.
    static func site(fileID: String, line: Int) -> String {
        let file = fileID.split(separator: "/").last.map(String.init) ?? ""
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+-.")
        guard !file.isEmpty, file.count <= maxSiteLength,
              file.unicodeScalars.allSatisfy(allowed.contains) else { return "unknown" }
        return "\(file):\(max(line, 0))"
    }
}
