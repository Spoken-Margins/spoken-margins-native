import Foundation

/// Reads the response out of a shared ChatGPT page (#874).
///
/// A page like `https://chatgpt.com/s/t_…` draws the chat with scripts, so its visible HTML holds only the
/// title. The chat itself is in the page as data: inline `<script>` blocks call
/// `window.__reactRouterContext.streamController.enqueue("…")`, and the first chunk is React Router's
/// flattened JSON (one array; an object's keys and values are positions in that array). Reading the data
/// avoids running any of the site's scripts.
public enum ChatGPTSharedPage {
    public enum ParseError: Error, LocalizedError, Equatable {
        case noPageData
        case noResponse

        public var errorDescription: String? {
            switch self {
            case .noPageData:
                "ChatGPT's shared page did not include the chat. Open the link in Safari to check that it still works."
            case .noResponse:
                "This shared ChatGPT page has no response text to read."
            }
        }
    }

    /// A page whose URL looks like a ChatGPT share link: `/s/<id>` or the older `/share/<id>`.
    public static func matches(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "chatgpt.com" || host == "www.chatgpt.com" || host == "chat.openai.com" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count >= 2 && (parts[0] == "s" || parts[0] == "share")
    }

    /// The shared response as an article to import.
    /// - Parameters:
    ///   - pageSource: the page's HTML, or the text of its inline scripts.
    ///   - pageTitle: the page's `<title>`, used when the data carries no chat title.
    public static func handoff(fromPageSource pageSource: String, url: URL, pageTitle: String? = nil) throws -> BrowserTextHandoff {
        let documents = flatDocuments(inPageSource: pageSource)
        guard !documents.isEmpty else { throw ParseError.noPageData }
        var messages: [Message] = []
        var chatTitle: String?
        var postedAt: Double?
        for document in documents {
            collect(document, messages: &messages)
            if chatTitle == nil { (chatTitle, postedAt) = post(in: document) }
        }
        let text = transcript(from: dedupedInOrder(messages))
        guard !text.isEmpty else { throw ParseError.noResponse }
        let title = firstNonEmpty(chatTitle, cleanedPageTitle(pageTitle)) ?? fallbackTitle(for: text)
        return BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(
                url: url.absoluteString,
                title: title,
                author: "ChatGPT",
                publishedAt: postedAt.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
            ),
            text: text,
            contentFormat: .markdown,
            requestedContinuation: BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app")
        )
    }

    // MARK: Page data

    /// The decoded object graph of every flattened-data chunk in the page.
    static func flatDocuments(inPageSource source: String) -> [Any] {
        var documents: [Any] = []
        for literal in enqueuedStringLiterals(in: source) {
            guard let chunk = decodeJSONString(literal), chunk.first == "[",
                  let table = (try? JSONSerialization.jsonObject(with: Data(chunk.utf8))) as? [Any],
                  let graph = FlatData(table: table).root() else { continue }
            documents.append(graph)
        }
        return documents
    }

    /// The raw text (quotes included) of each string literal passed to `.enqueue(`. Scanned by hand: a
    /// regular expression over a page this large can overflow ICU's stack.
    private static func enqueuedStringLiterals(in source: String) -> [String] {
        let bytes = Array(source.utf8)
        let marker = Array(".enqueue(\"".utf8)
        var literals: [String] = []
        var index = 0
        while index + marker.count <= bytes.count {
            guard bytes[index] == marker[0], bytes[index..<(index + marker.count)].elementsEqual(marker) else {
                index += 1
                continue
            }
            let start = index + marker.count - 1
            var end = start + 1
            var escaped = false
            while end < bytes.count {
                if escaped { escaped = false } else if bytes[end] == UInt8(ascii: "\\") { escaped = true } else if bytes[end] == UInt8(ascii: "\"") { break }
                end += 1
            }
            guard end < bytes.count else { break }
            if let literal = String(bytes: bytes[start...end], encoding: .utf8) { literals.append(literal) }
            index = end + 1
        }
        return literals
    }

    private static func decodeJSONString(_ literal: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed)) as? String
    }

    /// React Router's flattened encoding: `table[0]` is the root; an object's `"_N"` key means the key is the
    /// string at `table[N]`, and its values, like an array's items, are positions in `table`. A negative
    /// position means no value.
    private struct FlatData {
        let table: [Any]
        private var memo: [Int: Any] = [:]
        private var inProgress: Set<Int> = []

        init(table: [Any]) { self.table = table }

        func root() -> Any? {
            var copy = self
            return copy.value(at: 0)
        }

        private mutating func value(at index: Int) -> Any? {
            guard index >= 0, index < table.count else { return nil }
            if let cached = memo[index] { return cached }
            guard inProgress.insert(index).inserted else { return nil }
            defer { inProgress.remove(index) }
            let raw = table[index]
            let resolved: Any?
            if let object = raw as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, child) in object {
                    guard key.hasPrefix("_"), let keyIndex = Int(key.dropFirst()),
                          keyIndex >= 0, keyIndex < table.count, let name = table[keyIndex] as? String,
                          let childIndex = Self.position(child), let value = value(at: childIndex) else { continue }
                    result[name] = value
                }
                resolved = result
            } else if let array = raw as? [Any] {
                // An array that starts with a string is a typed value (a date, a promise); the response is never one.
                if array.first is String { resolved = nil } else {
                    resolved = array.compactMap { item in Self.position(item).flatMap { value(at: $0) } }
                }
            } else {
                resolved = raw
            }
            if let resolved { memo[index] = resolved }
            return resolved
        }

        private static func position(_ item: Any) -> Int? {
            // Children are always positions. A literal `true` or `0` sits in the table itself, never as a child.
            (item as? NSNumber)?.intValue
        }
    }

    // MARK: Messages

    private struct Message {
        var id: String?
        var role: String
        var text: String
        var createdAt: Double?
    }

    private static func collect(_ node: Any, messages: inout [Message]) {
        if let object = node as? [String: Any] {
            if let message = message(from: object) {
                messages.append(message)
                return
            }
            for key in object.keys.sorted() { collect(object[key]!, messages: &messages) }
        } else if let array = node as? [Any] {
            for item in array { collect(item, messages: &messages) }
        }
    }

    private static func message(from object: [String: Any]) -> Message? {
        guard let author = object["author"] as? [String: Any], let role = author["role"] as? String,
              role == "assistant" || role == "user",
              let content = object["content"] as? [String: Any],
              let type = content["content_type"] as? String, type == "text" || type == "multimodal_text",
              let parts = content["parts"] as? [Any] else { return nil }
        if let metadata = object["metadata"] as? [String: Any],
           (metadata["is_visually_hidden_from_conversation"] as? NSNumber)?.boolValue == true { return nil }
        let text = cleaned(parts.compactMap { $0 as? String }.joined(separator: "\n\n"))
        guard !text.isEmpty else { return nil }
        return Message(
            id: object["id"] as? String, role: role, text: text,
            createdAt: (object["create_time"] as? NSNumber)?.doubleValue
        )
    }

    private static func dedupedInOrder(_ messages: [Message]) -> [Message] {
        var seen = Set<String>()
        let unique = messages.filter { message in
            guard let id = message.id else { return true }
            return seen.insert(id).inserted
        }
        guard unique.count > 1, unique.allSatisfy({ $0.createdAt != nil }) else { return unique }
        return unique.enumerated()
            .sorted { ($0.element.createdAt!, $0.offset) < ($1.element.createdAt!, $1.offset) }
            .map(\.element)
    }

    /// A shared response is just the response. A shared run of turns says who spoke; the page doesn't name the person.
    private static func transcript(from messages: [Message]) -> String {
        let speakers = Set(messages.map(\.role))
        guard speakers.count > 1 else { return messages.map(\.text).joined(separator: "\n\n") }
        return messages
            .map { ($0.role == "user" ? "User: " : "ChatGPT: ") + $0.text }
            .joined(separator: "\n\n")
    }

    // MARK: Title

    private static func post(in document: Any) -> (title: String?, postedAt: Double?) {
        guard let object = document as? [String: Any] else {
            if let array = document as? [Any] {
                for item in array { let found = post(in: item); if found.title != nil { return found } }
            }
            return (nil, nil)
        }
        if object["attachments"] is [Any], let title = object["text"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (title.trimmingCharacters(in: .whitespacesAndNewlines), (object["posted_at"] as? NSNumber)?.doubleValue)
        }
        for key in object.keys.sorted() {
            let found = post(in: object[key]!)
            if found.title != nil { return found }
        }
        return (nil, nil)
    }

    private static func cleanedPageTitle(_ title: String?) -> String? {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        if title.hasPrefix("ChatGPT - ") { title.removeFirst("ChatGPT - ".count) }
        return title.isEmpty || title == "ChatGPT" ? nil : title
    }

    private static func fallbackTitle(for text: String) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let plain = firstLine.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        guard !plain.isEmpty else { return "ChatGPT response" }
        return plain.count > 80 ? String(plain.prefix(80)) + "…" : plain
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: Text cleanup

    private static let citationStart: Unicode.Scalar = "\u{E200}"
    private static let citationEnd: Unicode.Scalar = "\u{E201}"
    private static let citationSeparator: Unicode.Scalar = "\u{E202}"

    /// ChatGPT marks citations and entities with private-use characters (`U+E200 kind U+E202 … U+E201`) that
    /// only its own page knows how to draw, and links downloads with `sandbox:` addresses that only exist in
    /// its sandbox. Neither belongs in text to listen to.
    static func cleaned(_ raw: String) -> String {
        var output = String.UnicodeScalarView()
        var scalars = raw.unicodeScalars[...]
        while let scalar = scalars.first {
            guard scalar == citationStart, let close = scalars.firstIndex(of: citationEnd) else {
                if !(0xE200...0xE2FF).contains(scalar.value) { output.append(scalar) }
                scalars = scalars.dropFirst()
                continue
            }
            let body = String(String.UnicodeScalarView(scalars[scalars.index(after: scalars.startIndex)..<close]))
            let replacement = entityName(inCitation: body) ?? ""
            let next = scalars.index(after: close)
            let following = next < scalars.endIndex ? scalars[next] : nil
            if replacement.isEmpty, output.last == " ",
               following == nil || following == "\n" || following == " " || ".,;:!?)".unicodeScalars.contains(following!) {
                output.removeLast()
            }
            output.append(contentsOf: replacement.unicodeScalars)
            scalars = scalars[next...]
        }
        var text = String(output)
        text = text.replacingOccurrences(
            of: #"\[([^\]]*)\]\(sandbox:[^)]*\)"#, with: "$1", options: .regularExpression
        )
        text = text.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `entity` citations carry the words they stand for: `entity U+E202 ["city","Paris","capital of France"]`.
    private static func entityName(inCitation body: String) -> String? {
        let pieces = body.split(separator: Character(citationSeparator), maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0] == "entity",
              let list = (try? JSONSerialization.jsonObject(with: Data(pieces[1].utf8))) as? [Any],
              list.count > 1, let name = list[1] as? String else { return nil }
        return name
    }
}
