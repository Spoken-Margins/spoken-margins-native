import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #3548: the export decides by the shape of a value, not only by a hand-kept list of keys, so a new key that
/// carries an item id, a title or a path can't leak it by being new.
final class DiagnosticsExportPrivacyTests: XCTestCase {
    private static let salt = Data("privacy-salt".utf8)

    private func fixed(playbackEvents: String? = "{\"events\":[]}", developerRecording: String? = nil) -> DiagnosticsExport.Fixed {
        DiagnosticsExport.Fixed(
            developerBuild: "0.1 (36) abc1234",
            developerRecording: developerRecording,
            playbackEvents: playbackEvents,
            exportedAt: Date(timeIntervalSince1970: 1_791_000_000),
            playbackStatus: "playing",
            sessionPhase: "item_playback",
            targetType: nil,
            pendingAIJobs: 0
        )
    }

    // MARK: Salt

    func testTokensDifferBetweenExportsAndMatchInsideOne() {
        let live = ["lastImport": "item-browser-my-secret-plans-https-example-com", "podcastDownload:Secret Title": "queued"]
        let first = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed(), salt: Data("one".utf8))
        let again = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed(), salt: Data("one".utf8))
        let other = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed(), salt: Data("two".utf8))
        XCTAssertEqual(first, again, "one salt, one export")
        XCTAssertNotEqual(first["lastImport"], other["lastImport"])
        XCTAssertNotEqual(first.keys.sorted(), other.keys.sorted(), "keys carry tokens too")
        XCTAssertNotEqual(
            first["lastImport"], DiagnosticsExport.token(live["lastImport"]!),
            "an unsalted hash of a guessed id must not match"
        )
    }

    func testEveryExportMakesItsOwnSalt() {
        XCTAssertNotEqual(DiagnosticsExport.newSalt(), DiagnosticsExport.newSalt())
        let live = ["lastImport": "item-browser-my-secret-plans"]
        let a = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed())
        let b = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed())
        XCTAssertNotEqual(a["lastImport"], b["lastImport"])
    }

    // MARK: Item ids under keys nobody listed

    private static let secretFragments = ["secret", "plans", "taxes", "diary", "zanzibar"]

    /// Every way an item id or session id reaches a value: alone, inside a longer line, and after `=`.
    private static let idValues = [
        "item-browser-my-secret-plans-https-example-com-a",
        "item-obsidian-1791000000-3-dear-diary-taxes",
        "session-item-browser-my-secret-plans-https-example-com-a-8F1C2D3E-0000-4000-8000-000000000000",
        "session-item-browser-zanzibar-diaries-gate1-001",
        "sessionId=session-item-browser-my-secret-plans-x-gate1-002 itemId=item-browser-my-secret-plans-x",
        "failed: item-browser-dear-diary-taxes, retrying",
        "ITEM-BROWSER-MY-SECRET-PLANS",
        "item-browser-caf\u{E9}-secret-plans-na\u{EF}vet\u{E9}-\u{65E5}\u{672C}\u{8A9E}-x",
        "line one\nitem-browser-secret-plans",
    ]

    func testAnItemIdUnderAnyKeyLeavesAsAToken() throws {
        let keys = ["sessionId", "restoredSession", "sharedLinkVoiceover", "followedPublisherAudio", "brandNewKey", "a.b", "x_y"]
        for key in keys {
            for value in Self.idValues {
                let entries = DiagnosticsExport.entries(live: [key: value], stored: [:], fixed: fixed(), salt: Self.salt)
                let text = try DiagnosticsExport.jsonText(entries).lowercased()
                for fragment in Self.secretFragments {
                    XCTAssertFalse(text.contains(fragment), "\(fragment) of \(value.prefix(40)) is under \(key)")
                }
                XCTAssertFalse(text.contains("item-"), "an item id survives under \(key): \(value.prefix(40))")
            }
        }
    }

    func testAnItemIdInAStoredEntryLeavesAsAToken() throws {
        let entries = DiagnosticsExport.entries(
            live: [:], stored: ["marginCapture-x": "reasons=none item=item-browser-my-secret-plans"], fixed: fixed(), salt: Self.salt
        )
        XCTAssertFalse(try DiagnosticsExport.jsonText(entries).contains("secret"))
    }

    func testTheSameIdGivesTheSameTokenInTwoValuesAndTheTokenIsNotScrubbedAgain() {
        let id = "item-browser-my-secret-plans"
        let once = DiagnosticsExport.redactedValue("a \(id) b", salt: Self.salt)
        XCTAssertEqual(once, "a <id:\(DiagnosticsExport.token(id, salt: Self.salt))> b")
        XCTAssertEqual(DiagnosticsExport.redactedValue(once, salt: Self.salt), once, "a second pass changes nothing")
    }

    func testAnIdBeforeAFullStopKeepsItsTokenAndTheStop() {
        let id = "item-browser-my-secret-plans"
        let token = DiagnosticsExport.token(id, salt: Self.salt)
        XCTAssertEqual(DiagnosticsExport.redactedValue("saved \(id).", salt: Self.salt), "saved <id:\(token)>.")
    }

    func testAKeyWithAnIdInItsPrefixOrNoColonIsScrubbedToo() throws {
        let entries = DiagnosticsExport.entries(
            live: ["foo-item-browser-my-secret-plans": "x"], stored: ["item-browser-my-secret-plans": "y"], fixed: fixed(), salt: Self.salt
        )
        XCTAssertFalse(try DiagnosticsExport.jsonText(entries).contains("secret"))
    }

    /// Neighbouring inputs: nothing that only looks like an id is damaged.
    func testWordsThatMerelyContainItemAreLeftAlone() {
        for text in ["item:abc", "items-2", "an item", "problem-item", "pending: 3 items", "", "item-", "digitem-x"] {
            XCTAssertEqual(DiagnosticsExport.redactedValue(text, salt: Self.salt), text, text)
        }
    }

    // MARK: Event logs

    func testRawIdsInTheEventLogsBecomeTokensAndTheLogStaysValidJSON() throws {
        let log = """
        {"events":[
          {"kind":"playback.markComplete.hidden","fields":{"item":"item-browser-my-secret-plans"}},
          {"kind":"position.backward","fields":{"sessionId":"session-item-browser-my-secret-plans-gate1-001","itemId":"item-browser-my-secret-plans","durationMs":1234}}
        ]}
        """
        let entries = DiagnosticsExport.entries(live: [:], stored: [:], fixed: fixed(playbackEvents: log, developerRecording: log), salt: Self.salt)
        for key in ["playbackEvents", "developerRecording"] {
            let text = try XCTUnwrap(entries[key])
            XCTAssertFalse(text.contains("secret"), key)
            let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            let events = try XCTUnwrap(parsed?["events"] as? [[String: Any]])
            XCTAssertEqual(events.count, 2)
            let fields = try XCTUnwrap(events[1]["fields"] as? [String: Any])
            XCTAssertEqual(fields["durationMs"] as? Int, 1234, "numbers are untouched")
            XCTAssertEqual(
                fields["itemId"] as? String,
                "<id:\(DiagnosticsExport.token("item-browser-my-secret-plans", salt: Self.salt))>"
            )
        }
    }

    func testRecordTimeTokensAreSaltedPerExportAndNumbersAndOtherWordsAreNot() throws {
        let unsalted = "0123456789abcdef" // 16 hex, as the recorder writes
        let toast = "0123456789ab" // 12 hex, as a toast's text token
        let log = "{\"events\":[{\"item\":\"\(unsalted)\",\"textToken\":\"\(toast)\",\"bytes\":123456789012345,\"n\":\"123456789012\",\"w\":\"abcdefabcdef0\"}]}"
        let one = DiagnosticsExport.entries(live: [:], stored: [:], fixed: fixed(playbackEvents: log), salt: Data("one".utf8))
        let two = DiagnosticsExport.entries(live: [:], stored: [:], fixed: fixed(playbackEvents: log), salt: Data("two".utf8))
        let a = try XCTUnwrap(one["playbackEvents"]), b = try XCTUnwrap(two["playbackEvents"])
        XCTAssertFalse(a.contains(unsalted))
        XCTAssertFalse(a.contains("\"\(toast)\""))
        XCTAssertNotEqual(a, b, "tokens differ between exports")
        XCTAssertTrue(a.contains("123456789012345") && a.contains("\"123456789012\""), "an all-digit run is a number")
        XCTAssertTrue(a.contains("abcdefabcdef0"), "a 13-digit run is not a token")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(a.utf8)))
    }

    func testTheResponsivenessLineStillReadsTheOriginalEvents() {
        let log = "{\"events\":[{\"kind\":\"main.hang\",\"fields\":{\"durationMs\":\"900\",\"screen\":\"playback\"}}]}"
        let entries = DiagnosticsExport.entries(live: [:], stored: [:], fixed: fixed(playbackEvents: log), salt: Self.salt)
        XCTAssertEqual(entries["responsiveness"], ResponsivenessSummary(playbackEventsJSON: log).text)
    }

    // MARK: Paths

    /// Neighbouring inputs for the path rule: spaces, iCloud Drive, a trailing sentence, two paths in one
    /// line, brackets, Unicode, lookalikes that are not paths.
    func testPathsWithSpacesAreRedactedWhole() {
        let table: [(String, String)] = [
            ("/var/mobile/Containers/Data/Application/EX/Library/Application Support/PreparedAudio/item-EXAMPLE.m4a", "<redacted-path>"),
            ("/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Family Taxes/2025 return.pdf", "<redacted-path>"),
            ("/tmp/Example File.pdf", "<redacted-path>"),
            ("/Volumes/Backup Drive/Old Notes/plan b.txt", "<redacted-path>"),
            ("Could not write /Users/cole/My Docs/Notes.txt: No space left on device", "Could not write <redacted-path>: No space left on device"),
            ("failed at /var/a/b.m4a then /var/c/d e.m4a", "failed at <redacted-path> then <redacted-path>"),
            ("(/var/a/b c.pdf)", "(<redacted-path>)"),
            ("path=/var/a b/c", "path=<redacted-path>"),
            ("/Users/josé/Café Notes/日本語 メモ.txt", "<redacted-path>"),
            ("/var/x/Family Taxes 2025.pdf", "<redacted-path>"),
            ("/var/x/My Secret Family Plans for 2025 final.pdf failed", "<redacted-path> failed"),
            ("/Library/Mobile Documents/Taxes/Return.pdf, retrying", "<redacted-path>, retrying"),
            ("/home/cole/a b.txt", "<redacted-path>"),
            ("/var/mobile/Containers/Data/Application/EX/Library/Caches", "<redacted-path>"),
            ("file:///var/mobile/My Folder/x.m4a", "file://<redacted-path>"),
            ("https://example.com/var/x/y z", "<redacted-url> z"),
            ("/variable/foo", "/variable/foo"),
            ("a/var/b", "a/var/b"),
            ("/", "/"),
            ("", ""),
            ("no path here, only words", "no path here, only words"),
        ]
        for (input, expected) in table {
            XCTAssertEqual(DiagnosticsExport.redactedValue(input, salt: Self.salt), expected, input)
        }
    }

    func testAQuotedFileNameInASystemErrorIsRedacted() {
        let table: [(String, String)] = [
            ("The file \u{201C}Family Taxes 2025.pdf\u{201D} couldn\u{2019}t be opened.", "The file \u{201C}<redacted-file>\u{201D} couldn\u{2019}t be opened."),
            ("The file \"My Secret Plans.docx\" doesn't exist", "The file \"<redacted-file>\" doesn't exist"),
            ("Expected \"playing\" or \"paused\"", "Expected \"playing\" or \"paused\""),
            ("state \"v2.1\" reached", "state \"<redacted-file>\" reached"),
        ]
        for (input, expected) in table {
            XCTAssertEqual(DiagnosticsExport.redactedValue(input, salt: Self.salt), expected, input)
        }
    }

    // MARK: Guard: the app's real keys

    /// Reads the app's own `diagnostics["…"]` key names from its sources, so a key added later is covered by the
    /// same check without anyone adding it to a list. A leak by a new key can only come from a value shape the
    /// scrubber doesn't know, and this fails when one of the shapes below gets through.
    func testNoRealDiagnosticKeyCanCarryAnItemIdATitleOrAPath() throws {
        let keys = try Self.appDiagnosticKeys()
        XCTAssertGreaterThan(keys.count, 100, "the key scan found too few keys: has the diagnostics code moved?")
        let values = Self.idValues + [
            "/var/mobile/Family Taxes/Secret Plans.pdf",
            "failed: The file \u{201C}Secret Plans.pdf\u{201D} couldn\u{2019}t be opened",
            "https://example.com/secret-plans",
        ]
        let fixedNames: Set<String> = [
            "developerBuild", "developerRecording", "playbackEvents", "schemaVersion", "exportedAt",
            "playbackStatus", "sessionPhase", "targetType", "pendingAIJobs", "responsiveness",
        ]
        var live: [String: String] = [:]
        for (index, key) in keys.enumerated() where !fixedNames.contains(key) {
            live[key] = values[index % values.count]
            live["\(key):item-browser-my-secret-plans"] = values[(index + 1) % values.count]
        }
        let entries = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed(), salt: Self.salt)
        let text = try DiagnosticsExport.jsonText(entries).lowercased()
        for fragment in Self.secretFragments + ["example.com", "/var/"] {
            XCTAssertFalse(text.contains(fragment), "\(fragment) reached the export through one of the app's keys")
        }
        XCTAssertFalse(text.contains("item-"))
    }

    private static func appDiagnosticKeys() throws -> [String] {
        // Through the helper, so a package checked out alone skips with the input named (#1851).
        let sources = try TestInputs.directory(.appSources)
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            XCTFail("The app sources are not at \(sources.path): this guard reads them.")
            return []
        }
        let pattern = try NSRegularExpression(pattern: #"diagnostics\["([A-Za-z0-9_.-]+)"\]"#)
        var found = Set<String>()
        for case let file as URL in walker where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
            }
        }
        return found.sorted()
    }
}
