import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #1971: the screens say "Margin", the listener's word. This scans the app's SwiftUI string literals for the
/// code's words. It reads literals only: identifiers, accessibility identifiers, diagnostics and file names keep
/// their names, because journeys and exports depend on them.
final class ListenerWordsInViewsTests: XCTestCase {
    private static let bannedWords = ["Interjection", "Anchors", "Source Notes"]
    private static let literalPattern = try! NSRegularExpression(
        pattern: #"(?:\b(?:Text|Button|Label|Section|Toggle|LabeledContent|TextField|Picker|DisclosureGroup|Menu|NavigationLink)|\.navigationTitle|\.confirmationDialog|\.alert)\(\s*"([^"\n]*)""#)

    /// The banned words found in the user-facing literals of `source`, with the line that holds them.
    static func offences(in source: String) -> [String] {
        var found: [String] = []
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let text = String(line)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in literalPattern.matches(in: text, range: range) {
                guard let literalRange = Range(match.range(at: 1), in: text) else { continue }
                let literal = withoutInterpolations(String(text[literalRange]))
                for word in bannedWords where literal.contains(word) { found.append("line \(index + 1): \(literal)") }
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
        XCTAssertEqual(Self.offences(in: #"Text("Source Notes").tag("source_interjections")"#).count, 1)
        XCTAssertEqual(Self.offences(in: #".navigationTitle("Interjections")"#).count, 1)
        XCTAssertEqual(Self.offences(in: #"Label("Copy Transcript and Anchors", systemImage: "doc")"#).count, 1)
    }

    func testTheScannerIgnoresIdentifiersAndComments() {
        XCTAssertTrue(Self.offences(in: #".accessibilityIdentifier("interjection.detail.delete")"#).isEmpty)
        XCTAssertTrue(Self.offences(in: #"Text("Delete Margin").tag("source_interjections")"#).isEmpty)
        XCTAssertTrue(Self.offences(in: #"// Button("Delete Interjection")"#).isEmpty)
        XCTAssertTrue(Self.offences(in: "let kind = \"interjection_summary\"").isEmpty)
    }

    func testNoScreenSaysInterjectionAnchorsOrSourceNotes() throws {
        let directory = try TestInputs.directory(.appSources)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertGreaterThan(files.count, 50, "The scan found the app's sources")
        var offences: [String] = []
        for file in files {
            let source = try String(contentsOf: directory.appending(path: file), encoding: .utf8)
            offences += Self.offences(in: source).map { "\(file) \($0)" }
        }
        XCTAssertEqual(offences, [], "Say Margin, 'Where in the source' or 'Margins' to the listener (Design/brief.md rule 7)")
    }
}
