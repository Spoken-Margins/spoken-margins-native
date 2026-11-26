import Foundation
import SessionKit

// #4341, slice 3: the listener connects their own Zotero library with their user ID and an API key they make on
// zotero.org. The key is kept in the Keychain by the app; these are the rules and words around it, host-tested.

/// The listener's connected library, as the screens show it. It never holds the key.
public struct ZoteroConnection: Equatable, Sendable {
    public var userID: Int
    /// What Zotero calls the library, read from its records; nil when it said nothing.
    public var libraryName: String?

    public init(userID: Int, libraryName: String?) {
        self.userID = userID
        self.libraryName = libraryName
    }

    /// "Connected as <name>", or "Connected to Zotero" when the library gave no name.
    public var statusLine: String {
        if let libraryName, !libraryName.isEmpty { return "Connected as \(libraryName)" }
        return "Connected to Zotero"
    }
}

public enum ZoteroConnectionInput {
    /// Where Zotero lists a person's user ID and API keys (its web API docs point here).
    public static let keysPage = URL(string: "https://www.zotero.org/settings/keys")!

    public enum Problem: Error, Equatable, Sendable {
        case userIDMissing
        case keyMissing

        public var message: String {
            switch self {
            case .userIDMissing: return "Enter your Zotero user ID. It's the number on your API keys page on zotero.org."
            case .keyMissing: return "Enter your Zotero API key."
            }
        }
    }

    /// The typed user ID and key, trimmed. The ID is digits only (a pasted "userID: 123" or "123 " still reads); the key
    /// is one word of letters and digits, as Zotero makes them.
    public static func validate(userID: String, apiKey: String) -> Result<(userID: Int, apiKey: String), Problem> {
        let idText = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = idText.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).last.map(String.init) ?? ""
        guard !digits.isEmpty, digits.count <= 12, let id = Int(digits), id > 0,
              idText.filter({ $0.isASCII && $0.isNumber }).count == digits.count
        else { return .failure(.userIDMissing) }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 64, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return .failure(.keyMissing)
        }
        return .success((id, key))
    }
}
