import Foundation
import XCTest

/// Helpers for the tests that read app `.swift` files as text (#4306). A `contains` over a whole file passes when the text
/// sits in a comment, in another view, or in the one place that was not changed. These helpers drop comments and cut out the
/// specific call, block or statement a guard is about, so a guard looks at that piece of code and nothing else.
///
/// They are text tools, not a parser: they know comments, string literals and balanced `()` and `{}`, which is all the
/// guards need. Line numbers are kept, so `code(_:)` lines up with the raw file line for line.
enum SwiftSourceScan {
    /// The text with `//` and `/* */` comments replaced by nothing (newlines stay). String literals are kept whole.
    static func code(_ text: String) -> String {
        let chars = Array(text)
        var out = String()
        var index = 0
        while index < chars.count {
            let char = chars[index]
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if char == "/", next == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else if char == "/", next == "*" {
                var depth = 1
                index += 2
                while index < chars.count, depth > 0 {
                    if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "*" { depth += 1; index += 2 }
                    else if chars[index] == "*", index + 1 < chars.count, chars[index + 1] == "/" { depth -= 1; index += 2 }
                    else { if chars[index] == "\n" { out.append("\n") }; index += 1 }
                }
            } else if char == "\"" || (char == "#" && stringStart(chars, index) != nil) {
                let end = stringEnd(chars, from: index)
                out.append(String(chars[index..<end]))
                index = end
            } else {
                out.append(char)
                index += 1
            }
        }
        return out
    }

    /// Where a string literal that starts at `index` (`"`, `"""`, or `#"` raw forms) ends, one past its closing quote.
    private static func stringEnd(_ chars: [Character], from index: Int) -> Int {
        var hashes = 0
        var cursor = index
        while cursor < chars.count, chars[cursor] == "#" { hashes += 1; cursor += 1 }
        guard cursor < chars.count, chars[cursor] == "\"" else { return index + 1 }
        let triple = cursor + 2 < chars.count && chars[cursor + 1] == "\"" && chars[cursor + 2] == "\""
        cursor += triple ? 3 : 1
        let closing = String(repeating: "\"", count: triple ? 3 : 1) + String(repeating: "#", count: hashes)
        let closeChars = Array(closing)
        while cursor < chars.count {
            if chars[cursor] == "\\", hashes == 0 { cursor += 2; continue }
            if cursor + closeChars.count <= chars.count, Array(chars[cursor..<cursor + closeChars.count]) == closeChars {
                return cursor + closeChars.count
            }
            if !triple, chars[cursor] == "\n" { return cursor }
            cursor += 1
        }
        return chars.count
    }

    private static func stringStart(_ chars: [Character], _ index: Int) -> Int? {
        var cursor = index
        while cursor < chars.count, chars[cursor] == "#" { cursor += 1 }
        return cursor < chars.count && chars[cursor] == "\"" ? cursor : nil
    }

    /// The offset just past the bracket that closes the one at `open`, skipping string literals. Nil when it never closes.
    static func closing(_ chars: [Character], open: Int) -> Int? {
        let (opener, closer): (Character, Character) = chars[open] == "(" ? ("(", ")") : ("{", "}")
        var depth = 0
        var index = open
        while index < chars.count {
            let char = chars[index]
            if char == "\"" || (char == "#" && stringStart(chars, index) != nil) {
                index = stringEnd(chars, from: index)
                continue
            }
            if char == opener { depth += 1 }
            if char == closer { depth -= 1; if depth == 0 { return index + 1 } }
            index += 1
        }
        return nil
    }

    /// A call written as `header` + arguments + `)`, with the `{ … }` block that follows it if there is one.
    struct Call {
        let arguments: String
        let block: String?
        /// Offsets into the scanned code of the whole call including its block.
        let range: Range<Int>
    }

    /// Every call that begins with `header` (for example `.swipeActions(`), in order.
    static func calls(_ header: String, in code: String) -> [Call] {
        let chars = Array(code)
        let head = Array(header)
        precondition(head.last == "(", "a call header ends at its opening parenthesis")
        var found: [Call] = []
        var index = 0
        while index + head.count <= chars.count {
            guard Array(chars[index..<index + head.count]) == head else { index += 1; continue }
            let open = index + head.count - 1
            guard let afterArguments = closing(chars, open: open) else { break }
            let arguments = String(chars[(open + 1)..<(afterArguments - 1)])
            var cursor = afterArguments
            while cursor < chars.count, chars[cursor] == " " { cursor += 1 }
            if cursor < chars.count, chars[cursor] == "{", let afterBlock = closing(chars, open: cursor) {
                found.append(Call(arguments: arguments, block: String(chars[(cursor + 1)..<(afterBlock - 1)]), range: index..<afterBlock))
                index = afterBlock
            } else {
                found.append(Call(arguments: arguments, block: nil, range: index..<afterArguments))
                index = afterArguments
            }
        }
        return found
    }

    /// The body of the first `{ … }` that follows `marker`, for a `func` or a `var`. Nil when the marker is missing.
    static func body(after marker: String, in code: String) -> String? {
        guard let found = code.range(of: marker) else { return nil }
        let chars = Array(code)
        var index = code.distance(from: code.startIndex, to: found.upperBound)
        while index < chars.count, chars[index] != "{" { index += 1 }
        guard index < chars.count, let end = closing(chars, open: index) else { return nil }
        return String(chars[(index + 1)..<(end - 1)])
    }

    /// The `{ … }` of the `catch` that follows `marker`.
    static func catchBody(after marker: String, in code: String) -> String? {
        guard let found = code.range(of: marker) else { return nil }
        return body(after: "catch", in: String(code[found.upperBound...]))
    }

    /// The statement a modifier chain belongs to: the lines from the nearest line above `marker` that starts a `Button`
    /// (or `Text`, ...) to the line that holds `marker`. This is the unit a `.tint` or an identifier belongs to.
    static func chain(endingAt marker: String, startingWith starts: [String], in code: String) -> String? {
        let lines = code.components(separatedBy: "\n")
        guard let end = lines.firstIndex(where: { $0.contains(marker) }) else { return nil }
        var start = end
        while start > 0, !starts.contains(where: { lines[start].trimmingCharacters(in: .whitespaces).hasPrefix($0) }) { start -= 1 }
        guard starts.contains(where: { lines[start].trimmingCharacters(in: .whitespaces).hasPrefix($0) }) else { return nil }
        return lines[start...end].joined(separator: "\n")
    }

    /// The call of `header` whose block holds `marker`, the innermost if several nest.
    static func call(_ header: String, enclosing marker: String, in code: String) -> Call? {
        guard let at = code.range(of: marker) else { return nil }
        let offset = code.distance(from: code.startIndex, to: at.lowerBound)
        return calls(header, in: code).last { $0.block != nil && $0.range.contains(offset) }
    }
}

/// Self-tests: a guard built on these helpers is only as honest as they are.
final class SwiftSourceScanTests: XCTestCase {
    func testCommentsAreDroppedButStringsKeepTheirSlashes() {
        let text = "a // gone\nb /* gone\nstill */ c\nlet u = \"http://x\" // tail\nlet r = #\"a // b\"#\n"
        let code = SwiftSourceScan.code(text)
        XCTAssertFalse(code.contains("gone"))
        XCTAssertFalse(code.contains("tail"))
        XCTAssertTrue(code.contains("\"http://x\""))
        XCTAssertTrue(code.contains("#\"a // b\"#"))
        XCTAssertEqual(code.components(separatedBy: "\n").count, text.components(separatedBy: "\n").count, "lines stay aligned")
    }

    func testABlockIsBalancedAroundBracesInStrings() throws {
        let code = SwiftSourceScan.code("func f() {\n  let s = \"}\"\n  if x { y() }\n  // }\n}\nfunc g() { other() }")
        let body = try XCTUnwrap(SwiftSourceScan.body(after: "func f", in: code))
        XCTAssertTrue(body.contains("y()"))
        XCTAssertFalse(body.contains("other()"))
    }

    func testACallKnowsItsArgumentsAndItsBlock() throws {
        let code = SwiftSourceScan.code("v.swipeActions(edge: .leading, allowsFullSwipe: true) { // was !done\n Button(\"a\") {}\n}\n.other()")
        let call = try XCTUnwrap(SwiftSourceScan.calls(".swipeActions(", in: code).first)
        XCTAssertEqual(call.arguments, "edge: .leading, allowsFullSwipe: true")
        XCTAssertTrue(try XCTUnwrap(call.block).contains("Button"))
    }

    func testTheChainOfAButtonStopsAtItsOwnButton() throws {
        let code = "Button(a) {\n}\n.tint(.red)\n.accessibilityIdentifier(\"one\")\nButton(b) {\n}\n.tint(AppColors.swipeSlate)\n.accessibilityIdentifier(\"two\")"
        let chain = try XCTUnwrap(SwiftSourceScan.chain(endingAt: "\"two\"", startingWith: ["Button"], in: code))
        XCTAssertTrue(chain.contains("swipeSlate"))
        XCTAssertFalse(chain.contains(".red"))
    }
}
