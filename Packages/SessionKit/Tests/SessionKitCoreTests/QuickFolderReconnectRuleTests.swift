import XCTest
@testable import SessionKit

/// #3770: choosing a folder again keeps what the app knew only when it is the same folder. A table of the same path written
/// differently, and of the look-alikes that must not reconnect.
final class QuickFolderReconnectRuleTests: XCTestCase {
    private let vault = "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Obsidian/Clippings"

    private func decide(_ stored: String?, _ chosen: String, file: StaticString = #filePath, line: UInt = #line) -> QuickFolderReconnectRule.Decision {
        QuickFolderReconnectRule.decide(storedPath: stored, chosenPath: chosen)
    }

    func testTheSameFolderWrittenDifferentlyReconnects() {
        let rows: [(String, String)] = [
            ("identical", vault),
            ("trailing slash, how a folder URL is written", vault + "/"),
            ("doubled slash", vault.replacingOccurrences(of: "Obsidian/", with: "Obsidian//")),
            ("a dot component", vault.replacingOccurrences(of: "Obsidian/", with: "Obsidian/./")),
            ("a dot-dot component", vault.replacingOccurrences(of: "Obsidian/", with: "Obsidian/Other/../")),
            ("a file URL", "file://" + vault.replacingOccurrences(of: " ", with: "%20")),
        ]
        for (name, chosen) in rows {
            XCTAssertEqual(decide(vault, chosen), .keepSeenFiles, name)
            XCTAssertEqual(decide(chosen, vault), .keepSeenFiles, "\(name), the other way round")
        }
    }

    func testUnicodeNormalizationDoesNotSplitAFolder() {
        let composed = "/x/Caf\u{00E9} Notes"
        let decomposed = "/x/Cafe\u{0301} Notes"
        XCTAssertNotEqual(composed.unicodeScalars.count, decomposed.unicodeScalars.count)
        // Swift's `==` already treats the two as equal, so compare the scalars: this fails if the NFC step is removed.
        XCTAssertEqual(
            Array(QuickFolderReconnectRule.standardized(composed).unicodeScalars),
            Array(QuickFolderReconnectRule.standardized(decomposed).unicodeScalars)
        )
        XCTAssertEqual(decide(composed, decomposed), .keepSeenFiles)
        XCTAssertEqual(decide(decomposed, composed), .keepSeenFiles)
    }

    func testPrivateVarIsVar() {
        XCTAssertEqual(decide("/private/var/mobile/Documents/Clippings", "/var/mobile/Documents/Clippings"), .keepSeenFiles)
        XCTAssertEqual(decide("/var/mobile/Documents/Clippings", "/private/var/mobile/Documents/Clippings"), .keepSeenFiles)
        XCTAssertEqual(decide("/private/tmp/a", "/tmp/a"), .keepSeenFiles)
        XCTAssertEqual(decide("/private/etc/a", "/etc/a"), .keepSeenFiles)
        XCTAssertEqual(decide("/private/other/a", "/other/a"), .freshBaseline, "only the system folders share a spelling")
        XCTAssertEqual(decide("/private/varnish/a", "/varnish/a"), .freshBaseline, "a folder that merely starts with var")
    }

    func testADifferentFolderTakesAFreshBaseline() {
        let rows: [(String, String)] = [
            ("the same name somewhere else", "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Work/Clippings"),
            ("its parent", "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Obsidian"),
            ("a folder inside it", vault + "/2026"),
            ("a sibling that starts with the same letters", vault + "2"),
            ("a different case", vault.replacingOccurrences(of: "Clippings", with: "clippings")),
            ("a different name", vault.replacingOccurrences(of: "Clippings", with: "Reading")),
            ("the root", "/"),
            ("empty", ""),
        ]
        for (name, chosen) in rows {
            XCTAssertEqual(decide(vault, chosen), .freshBaseline, name)
        }
    }

    func testAnUnknownStoredPathIsAFreshBaseline() {
        XCTAssertEqual(decide(nil, vault), .freshBaseline, "an upgrade from a build that stored no path")
        XCTAssertEqual(decide("", vault), .freshBaseline)
        XCTAssertEqual(decide("", ""), .freshBaseline, "two unknowns are not the same folder")
        XCTAssertEqual(decide("/", "/"), .keepSeenFiles, "the root is a path")
    }

    func testStandardizedForm() {
        let rows: [(String, String)] = [
            ("", ""),
            ("/", "/"),
            ("/a/b", "/a/b"),
            ("/a/b/", "/a/b"),
            ("//a///b", "/a/b"),
            ("/a/./b", "/a/b"),
            ("/a/b/../c", "/a/c"),
            ("/../a", "/a"),
            ("/a/../..", "/"),
            ("a/b/", "a/b"),
            ("../a", "../a"),
            ("a/../../b", "../b"),
            ("/private/var/x", "/var/x"),
            ("/private", "/private"),
        ]
        for (raw, expected) in rows {
            XCTAssertEqual(QuickFolderReconnectRule.standardized(raw), expected, raw)
        }
    }

    func testAVeryLongPathIsHandled() {
        let deep = "/" + Array(repeating: "folder", count: 5_000).joined(separator: "/")
        XCTAssertEqual(decide(deep, deep + "/"), .keepSeenFiles)
        XCTAssertEqual(decide(deep, deep + "/x"), .freshBaseline)
    }
}
