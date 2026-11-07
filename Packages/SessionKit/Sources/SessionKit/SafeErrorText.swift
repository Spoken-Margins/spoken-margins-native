import Foundation

/// An `Error` as words that are safe to put in the diagnostics export (#3548). The message of a system or
/// library error can name a file or a folder the listener chose, and `String(describing:)` of an enum prints its
/// payload, which may be a title or a path. So this keeps only what can't hold listener data: the error's domain
/// and code, the same for each underlying error, and, for an enum we define, the case name without its payload.
/// It never reads `localizedDescription`, `errorDescription` or the description of an unknown error.
///
/// Example: `NSCocoaErrorDomain#260 < NSPOSIXErrorDomain#2`, or `SessionKit.SomeError#1:invalidManifest`.
///
/// If a failure can only be told apart by its message, give that failure its own enum case or code; the message
/// does not belong in the export.
public enum SafeErrorText {
    /// Domain and code of the error, then of each underlying error (up to four in all), plus the case name for
    /// an enum error. At most 200 characters.
    public static func describe(_ error: Error) -> String {
        var chain: [String] = []
        var current: NSError? = error as NSError
        while let nsError = current, chain.count < 4 {
            chain.append("\(safeDomain(nsError.domain))#\(nsError.code)")
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        var text = chain.joined(separator: " < ")
        if let name = caseName(error) { text += ":\(name)" }
        return text.count > 200 ? String(text.prefix(200)) : text
    }

    /// A `DecodingError` as the field that failed and how: `decoding:representations.0.kind:dataCorrupted`. The coding
    /// path is our own schema's names and list positions; a key that isn't a plain name (a dictionary key from the
    /// packet) is `key`. The error's own message is left out, because it can quote the value.
    public static func decodingDetail(_ error: DecodingError) -> String {
        let context: DecodingError.Context
        switch error {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c): context = c
        @unknown default: return "decoding:unknown"
        }
        let path = context.codingPath.map { key in
            key.intValue.map(String.init) ?? (isIdentifier(key.stringValue, allowing: "") && key.stringValue.count <= 48 ? key.stringValue : "key")
        }.joined(separator: ".")
        return "decoding:\(path):\(caseName(error) ?? "unknown")"
    }

    /// A domain is a type or framework name. One that holds spaces, slashes or other text is not, and leaves as `other`.
    static func safeDomain(_ domain: String) -> String {
        isIdentifier(domain, allowing: ".") && domain.count <= 96 ? domain : "other"
    }

    /// The case name of an enum error, never its payload. A case with no payload prints as its own name; an
    /// enum with its own `description` that isn't a bare identifier is left out.
    static func caseName(_ error: Error) -> String? {
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return nil }
        if let label = mirror.children.first?.label {
            return isIdentifier(label, allowing: "") && label.count <= 64 ? label : nil
        }
        let bare = String(describing: error)
        return isIdentifier(bare, allowing: "") && bare.count <= 64 ? bare : nil
    }

    private static func isIdentifier(_ text: String, allowing extra: String) -> Bool {
        guard let first = text.unicodeScalars.first, first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || extra.unicodeScalars.contains(scalar))
        }
    }
}
