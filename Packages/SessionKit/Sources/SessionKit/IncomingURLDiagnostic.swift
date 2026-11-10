import Foundation

/// What Diagnostics keeps about a URL that opened the app (#4031): enough to tell a Live Activity tap that reached the
/// app from one that never did, and nothing that identifies a person or opens a share.
///
/// Never the path, the query or the fragment: a share link's key lives there, and a source link names what a listener
/// reads. The host is kept only for the app's own scheme, where it is one of a few fixed words (`compact-control`).
/// The command is kept as a short word because it says which button was tapped.
public enum IncomingURLDiagnostic {
    public static func fields(for url: URL, appScheme: String, compactHost: String) -> [String: String] {
        let scheme = (url.scheme ?? "").lowercased()
        if url.isFileURL {
            return ["kind": "file", "extension": word(url.pathExtension.lowercased(), limit: 16)]
        }
        guard scheme == appScheme.lowercased() else {
            return ["kind": scheme == "https" || scheme == "http" ? "web" : "other_scheme"]
        }
        let host = (url.host ?? "").lowercased()
        var fields = ["kind": "app_scheme", "host": word(host, limit: 24)]
        if host == compactHost.lowercased() {
            fields["kind"] = "compact_control"
            let command = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "command" })?.value
            fields["command"] = command.map { word($0, limit: 40) } ?? "none"
        }
        return fields
    }

    /// Letters, digits, `_` and `-` only, cut short, so a made-up URL can't put free text into the export.
    private static func word(_ text: String, limit: Int) -> String {
        let kept = text.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
        return String(String.UnicodeScalarView(kept.prefix(limit)))
    }
}
