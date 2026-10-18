import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #1971: the screens say "Margin", the listener's word. This scans the app's SwiftUI string literals for the
/// code's words. It reads literals only: identifiers, accessibility identifiers, diagnostics and file names keep
/// their names, because journeys and exports depend on them.
final class ListenerWordsInViewsTests: XCTestCase {
    /// The code's words for what the listener calls a Margin or the place it sits. Singular "anchor" stays: the
    /// sharing screens' "anchor evidence" is a separate term of art.
    private static let bannedWords = try! NSRegularExpression(
        pattern: #"\b[Ii]nterjections?\b|\b[Aa]nchors\b|\b[Aa]nchor (?:text|context|excerpts)\b|Source Notes"#)
    private static let stringLiteral = try! NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
    /// A literal that is the argument of a call or label that names code, not text: an identifier, a tag, a
    /// diagnostics key, a symbol, a switch case. Only that literal is blanked, so the visible text on the same line
    /// (`Label("Delete Interjection", systemImage: "trash")`, `Text("Source Notes").tag("source")`) is still scanned.
    private static let codeLiteral = try! NSRegularExpression(
        pattern: #"(systemImage:\s*|\.tag\(\s*|accessibilityIdentifier\(\s*|diagnostics\[\s*|\bcase\s+)"(?:[^"\\]|\\.)*""#)

    /// The banned words found in the string literals of `source` that a listener can read, with the line that holds them.
    /// Any literal counts, whatever call holds it (a ternary arm, a return value, a banner, an accessibility label).
    /// A single token such as a path, key or identifier is not text.
    static func offences(in source: String) -> [String] {
        var found: [String] = []
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var text = String(line)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            text = codeLiteral.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1\"\"")
            let range = NSRange(text.startIndex..., in: text)
            for match in stringLiteral.matches(in: text, range: range) {
                guard let literalRange = Range(match.range(at: 1), in: text) else { continue }
                let literal = withoutInterpolations(String(text[literalRange]))
                guard literal.contains(" ") || (literal.first?.isUppercase == true && literal.allSatisfy(\.isLetter)) else { continue }
                if bannedWords.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)) != nil {
                    found.append("line \(index + 1): \(literal)")
                }
            }
        }
        return found
    }

    /// `"Playing at \(model.playingInterjectionAudioRate)×"` names code inside the text; only the words around it show.
    private static func withoutInterpolations(_ literal: String) -> String {
        var result = ""
        var depth = 0
        var index = literal.startIndex
        while index < literal.endIndex {
            let character = literal[index]
            let next = literal.index(after: index)
            if depth == 0, character == "\\", next < literal.endIndex, literal[next] == "(" {
                depth = 1
                index = literal.index(after: next)
                continue
            }
            if depth > 0 {
                if character == "(" { depth += 1 } else if character == ")" { depth -= 1 }
            } else {
                result.append(character)
            }
            index = next
        }
        return result
    }

    func testAnInterpolatedNameIsNotTheTextTheListenerReads() {
        XCTAssertTrue(Self.offences(in: #"Label("Playing at \(model.playingInterjectionAudioRate.formatted(.number.precision(.fractionLength(0...2))))× to match the item", systemImage: "waveform")"#).isEmpty)
        XCTAssertEqual(Self.offences(in: #"Text("\(count) Interjections")"#).count, 1)
    }

    func testTheScannerFindsTheWordsItBans() {
        XCTAssertEqual(Self.offences(in: #"Button("Delete Interjection", role: .destructive) {}"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"Section("Anchors") {"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"Text("Source Notes")"#).count, 1)
        XCTAssertEqual(Self.offences(in: #".navigationTitle("Interjections")"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"Label(copied ? "Copied" : "Copy Transcript and Anchors", action: copy)"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"pendingDeletion == .transcript ? "Delete this transcript?" : "Delete this interjection?","#).count, 1)
        XCTAssertEqual(Self.offences(in: #"reportConfirmation("Copied Margin with its anchors.")"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"return "Interjection summary""#).count, 1)
        XCTAssertEqual(Self.offences(in: #".accessibilityLabel("Anchor text before this Margin")"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"Text(verbatim: "No sessions with interjections")"#).count, 1)
    }

    /// Audit: skipping whole lines hid the usual forms, a label with a symbol and a row with a tag.
    func testTheScannerReadsTheVisibleTextOnALineThatAlsoHoldsCode() {
        XCTAssertEqual(Self.offences(in: #"Label("Delete Interjection", systemImage: "trash")"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"Label(copied ? "Copied" : "Copy Transcript and Anchors", systemImage: copied ? "checkmark" : "doc.on.doc")"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"Text("Source Notes").tag("source_interjections")"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"Button("Delete Interjection") {}.accessibilityIdentifier("interjection.detail.delete")"#).count, 1)
    }

    func testTheScannerIgnoresIdentifiersAndComments() {
        XCTAssertTrue(Self.offences(in: #".accessibilityIdentifier("interjection.detail.delete")"#).isEmpty)
        XCTAssertTrue(Self.offences(in: #"let payload = ["interjections": records]"#).isEmpty)
        XCTAssertTrue(Self.offences(in: #"Text("Delete Margin").tag("source_interjections")"#).isEmpty)
        XCTAssertTrue(Self.offences(in: #"Label("Delete Margin", systemImage: "interjection.trash")"#).isEmpty)
        XCTAssertTrue(Self.offences(in: #"case "interjection summary": return 1"#).isEmpty)
        XCTAssertTrue(Self.offences(in: #"diagnostics["Interjection count"] = "n""#).isEmpty)
        XCTAssertTrue(Self.offences(in: #"// Button("Delete Interjection")"#).isEmpty)
        XCTAssertTrue(Self.offences(in: "let kind = \"interjection_summary\"").isEmpty)
    }

    func testNoScreenSaysInterjectionAnchorsOrSourceNotes() throws {
        let directory = try TestInputs.directory(.appSources)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertGreaterThan(files.count, 50, "The scan found the app's sources")
        // The test seeds are fixture data and the on-device model's prompts are for the model, not the listener.
        let notForListeners: Set = ["Gate1AppModel+UITestingSeeds.swift", "LocalFoundationModels.swift"]
        var offences: [String] = []
        for file in files where !notForListeners.contains(file) {
            let source = try String(contentsOf: directory.appending(path: file), encoding: .utf8)
            offences += Self.offences(in: source).map { "\(file) \($0)" }
        }
        XCTAssertEqual(offences, [], "Say Margin, 'Where in the source' or 'Margins' to the listener (Design/brief.md rule 7)")
    }
}
