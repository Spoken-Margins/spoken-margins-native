import Foundation

/// Playback failures in privacy-safe diagnostics used to appear only as hashes, and the player's
/// own message ("The operation could not be completed") hides the real cause (#237). These helpers
/// keep the error's domain and code chain, which name the cause, and strip anything that could
/// identify a listener's library before the text is exported unhashed.
public enum PlaybackFailureDetail {
    /// The error's message followed by its domain and code, then each underlying error's, e.g.
    /// `The operation could not be completed [AVFoundationErrorDomain -11800 < NSOSStatusErrorDomain -12842]`.
    public static func describe(_ error: Error) -> String {
        var chain: [String] = []
        var current: NSError? = error as NSError
        while let nsError = current, chain.count < 4 {
            chain.append("\(nsError.domain) \(nsError.code)")
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(error.localizedDescription) [\(chain.joined(separator: " < "))]"
    }

    /// `failure` with URLs, file paths and quoted names removed, short enough for an event log.
    public static func privacySafe(_ failure: String?) -> String {
        guard let failure, !failure.isEmpty else { return "none" }
        var text = failure
        for (pattern, replacement) in redactions {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.count > 240 ? String(text.prefix(240)) + "…" : text
    }

    private static let redactions: [(String, String)] = [
        (#"[A-Za-z][A-Za-z0-9+.-]*://[^\s\]\[;,]+"#, "<url>"),
        (#"(?<![\w.])(?:~|/)[^\s\]\[;,]*/[^\s\]\[;,]*"#, "<path>"),
        (#"[“"][^”"]*[”"]"#, "<name>")
    ]
}
