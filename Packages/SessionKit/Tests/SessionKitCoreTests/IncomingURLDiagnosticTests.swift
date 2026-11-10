import XCTest
@testable import SessionKit

final class IncomingURLDiagnosticTests: XCTestCase {
    private func fields(_ text: String) -> [String: String] {
        IncomingURLDiagnostic.fields(for: URL(string: text)!, appScheme: "spokenmargins", compactHost: "compact-control")
    }

    func testALiveActivityTapNamesItsCommand() {
        XCTAssertEqual(fields("spokenmargins://compact-control?command=openPlayback"),
                       ["kind": "compact_control", "host": "compact-control", "command": "openPlayback"])
        XCTAssertEqual(fields("spokenmargins://compact-control?command=play&chapterId=ch-12")["command"], "play")
        XCTAssertEqual(fields("spokenmargins://compact-control")["command"], "none")
    }

    func testAShareLinkNeverWritesItsPathOrKey() {
        let written = fields("https://share.spokenmargins.com/s/AbC123xyz?v=2#key=TOPSECRETKEY")
        XCTAssertEqual(written, ["kind": "web"])
        XCTAssertFalse(written.values.joined().contains("TOPSECRETKEY"))
        XCTAssertFalse(written.values.joined().contains("AbC123xyz"))
    }

    func testOtherAppLinksKeepOnlyTheirHostWord() {
        let written = fields("spokenmargins://listening-edition?id=PRIVATE-ID-9")
        XCTAssertEqual(written, ["kind": "app_scheme", "host": "listening-edition"])
        XCTAssertFalse(written.values.joined().contains("PRIVATE"))
    }

    func testAFileKeepsOnlyItsExtension() {
        XCTAssertEqual(fields("file:///private/var/mobile/Documents/Harbour%20Lights.spokenmargins"),
                       ["kind": "file", "extension": "spokenmargins"])
    }

    func testAMadeUpCommandCannotCarryFreeText() {
        let command = fields("spokenmargins://compact-control?command=play%20for%20Jess%20Kusher%0A%22%3B--and-then-a-very-long-tail-of-words")["command"]!
        XCTAssertLessThanOrEqual(command.count, 40)
        XCTAssertNil(command.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted))
    }

    func testAnotherSchemeIsNamedOnlyAsOther() {
        XCTAssertEqual(fields("otherapp://anything/secret?token=1"), ["kind": "other_scheme"])
    }
}
