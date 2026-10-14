import Foundation

/// A compiled regular expression with the few operations the front end needs, matching Python's
/// `re` closely enough that the Swift port reproduces the Python reference exactly.
///
/// Patterns are written as in the reference (`\1` is `$1` in a template). Matching runs on UTF-16,
/// so every range is converted back to `String` before it leaves this type.
struct Rx: @unchecked Sendable {
    /// One match, with its groups as `String`s.
    struct Match {
        let text: NSString
        let result: NSTextCheckingResult

        var whole: String { text.substring(with: result.range) }

        /// The group's text, or nil when it didn't take part in the match.
        func group(_ index: Int) -> String? {
            let range = result.range(at: index)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }

        var range: NSRange { result.range }
    }

    private let expression: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        do {
            expression = try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("front end pattern doesn't compile: \(pattern): \(error)")
        }
    }

    /// Every non-overlapping match, left to right (Python's `finditer`).
    func matches(in string: String) -> [Match] {
        let text = NSString(string: string)
        return expression.matches(in: string, range: NSRange(location: 0, length: text.length))
            .map { Match(text: text, result: $0) }
    }

    /// Python's `re.search`.
    func firstMatch(in string: String) -> Match? {
        let text = NSString(string: string)
        return expression.firstMatch(in: string, range: NSRange(location: 0, length: text.length))
            .map { Match(text: text, result: $0) }
    }

    /// Python's `re.match`: the pattern must start with `^` when it is meant to be anchored.
    func isMatch(_ string: String) -> Bool { firstMatch(in: string) != nil }

    /// Python's `re.fullmatch`.
    func fullMatches(_ string: String) -> Bool {
        let text = NSString(string: string)
        guard let found = expression.firstMatch(in: string, options: [.anchored], range: NSRange(location: 0, length: text.length))
        else { return false }
        return found.range.length == text.length
    }

    /// Python's `re.sub` with a replacement function.
    func sub(_ string: String, _ replacement: (Match) -> String) -> String {
        let text = NSString(string: string)
        var out = ""
        var cursor = 0
        for result in expression.matches(in: string, range: NSRange(location: 0, length: text.length)) {
            let range = result.range
            out += text.substring(with: NSRange(location: cursor, length: range.location - cursor))
            out += replacement(Match(text: text, result: result))
            cursor = range.location + range.length
        }
        return out + text.substring(from: cursor)
    }

    /// Python's `re.sub` with a template (`$1` for group 1; `\$` for a literal dollar).
    func sub(_ string: String, template: String) -> String {
        expression.stringByReplacingMatches(
            in: string, range: NSRange(location: 0, length: NSString(string: string).length), withTemplate: template
        )
    }

    /// Python's `re.sub(..., count=1)` with a literal replacement.
    func subFirst(_ string: String, with literal: String) -> String {
        let text = NSString(string: string)
        guard let result = expression.firstMatch(in: string, range: NSRange(location: 0, length: text.length)) else { return string }
        return text.replacingCharacters(in: result.range, with: literal)
    }

    /// Every match's whole text (Python's `findall` when the pattern has no groups).
    func findAll(in string: String) -> [String] { matches(in: string).map(\.whole) }
}

extension String {
    /// Python's `str.replace` for a literal.
    func replacingLiteral(_ target: String, with replacement: String) -> String {
        replacingOccurrences(of: target, with: replacement, options: .literal)
    }

    /// Python's `str.rpartition`.
    func rpartition(_ separator: Character) -> (head: String, separator: String, tail: String) {
        guard let index = lastIndex(of: separator) else { return ("", "", self) }
        return (String(self[..<index]), String(separator), String(self[self.index(after: index)...]))
    }

    /// The characters as Python sees a string: Unicode code points.
    var codePoints: [Unicode.Scalar] { Array(unicodeScalars) }
}
