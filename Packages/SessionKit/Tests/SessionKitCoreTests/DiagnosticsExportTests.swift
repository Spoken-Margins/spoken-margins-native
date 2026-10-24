import Foundation
import XCTest
@testable import SessionKit

/// #968: the diagnostics export is the one place a tester sends data out of the app, so each rule that decides
/// what may leave the phone has a test that fails when the rule is broken.
final class DiagnosticsExportTests: XCTestCase {
    private func fixed(
        developerRecording: String? = "{\"recording\":true}",
        playbackEvents: String? = "{\"events\":[]}",
        targetType: String? = "item_text_tts"
    ) -> DiagnosticsExport.Fixed {
        DiagnosticsExport.Fixed(
            developerBuild: "0.1 (31) abc1234",
            developerRecording: developerRecording,
            playbackEvents: playbackEvents,
            exportedAt: Date(timeIntervalSince1970: 1_791_000_000),
            playbackStatus: "playing",
            sessionPhase: "item_playback",
            targetType: targetType,
            pendingAIJobs: 3
        )
    }

    // MARK: Rule A: keys that may hold what the listener typed, pasted or chose

    func testLiveEntriesThatMayHoldUserContentNeverLeave() {
        let live = [
            "lastStatus": "Saved a Margin on Dear Diary",
            "recentFailure": "Could not import My Secret Plans",
            "quickAccessFolder": "Family Taxes",
            "lastSourceLinkClipboardPaste": "pasted text",
            "lastBrowserTextSource": "private source content",
            "runtimeProfile": "test-profile",
        ]
        let entries = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed())

        for key in ["lastStatus", "recentFailure", "quickAccessFolder", "lastSourceLinkClipboardPaste", "lastBrowserTextSource"] {
            XCTAssertNil(entries[key], "\(key) holds user content")
        }
        XCTAssertEqual(entries["runtimeProfile"], "test-profile")
    }

    func testOnlyTheExactKeyNamesAreDropped() {
        let live = [
            "lastStatusCode": "200",
            "recentFailures": "3",
            "LastStatus": "x",
            "quickAccessFolderCount": "2",
        ]
        let entries = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed())

        for (key, value) in live {
            XCTAssertEqual(entries[key], value, "\(key) is not one of the five named keys")
        }
    }

    // MARK: Rule B: web addresses and paths are redacted in live values and stored Margin entries

    func testWebAddressesAndPathsAreRedactedInLiveValuesAndStoredEntries() {
        let rows: [(input: String, expected: String)] = [
            ("https://example.com/a?b=c", "<redacted-url>"),
            ("http://example.com", "<redacted-url>"),
            ("failed at https://example.com/feed.xml now", "failed at <redacted-url> now"),
            ("see https://example.com/page.", "see <redacted-url>"),
            ("two https://a.example/x and http://b.example/y", "two <redacted-url> and <redacted-url>"),
            ("/private/var/mobile/Containers/Data/x.m4a", "<redacted-path>"),
            ("/Users/cole/Library/x", "<redacted-path>"),
            ("/var/mobile/Containers/y", "<redacted-path>"),
            ("wrote /var/mobile/Containers/y then stopped", "wrote <redacted-path> then stopped"),
            ("file:///Users/cole/Documents/a.pdf", "file://<redacted-path>"),
            ("nothing to hide here", "nothing to hide here"),
            ("", ""),
            ("ratio 3/4 and a/b", "ratio 3/4 and a/b"),
        ]
        for row in rows {
            let entries = DiagnosticsExport.entries(
                live: ["liveValue": row.input],
                stored: ["marginCapture-session-1-ij-1": row.input],
                fixed: fixed()
            )
            XCTAssertEqual(entries["liveValue"], row.expected, "live: \(row.input)")
            XCTAssertEqual(entries["marginCapture-session-1-ij-1"], row.expected, "stored: \(row.input)")
        }
    }

    func testRedactionDoesNotCutAValueAtTheFirstLineBreak() {
        XCTAssertEqual(
            DiagnosticsExport.redactedValue("first https://example.com/a\nsecond /Users/cole/b\nthird"),
            "first <redacted-url>\nsecond <redacted-path>\nthird"
        )
    }

    // MARK: Rule C: a stored entry wins a key clash

    func testAStoredEntryOverridesALiveEntryWithTheSameKey() {
        let entries = DiagnosticsExport.entries(
            live: ["marginCapture-session-1-ij-1": "live", "onlyLive": "live"],
            stored: ["marginCapture-session-1-ij-1": "stored", "onlyStored": "stored"],
            fixed: fixed()
        )

        XCTAssertEqual(entries["marginCapture-session-1-ij-1"], "stored")
        XCTAssertEqual(entries["onlyLive"], "live")
        XCTAssertEqual(entries["onlyStored"], "stored")
    }

    // MARK: Rule D: the fixed keys are set last

    func testTheFixedKeysAreTheLastWordEvenWhenALiveOrStoredEntryHasTheSameKey() {
        let clashing = [
            "developerBuild": "live build",
            "developerRecording": "live recording",
            "playbackEvents": "live events",
            "schemaVersion": "live schema",
            "exportedAt": "live time",
            "playbackStatus": "live status",
            "sessionPhase": "live phase",
            "targetType": "live target",
            "pendingAIJobs": "99",
            "responsiveness": "live summary",
        ]
        let entries = DiagnosticsExport.entries(live: clashing, stored: clashing, fixed: fixed())

        XCTAssertEqual(entries["developerBuild"], "0.1 (31) abc1234")
        XCTAssertEqual(entries["developerRecording"], "{\"recording\":true}")
        XCTAssertEqual(entries["playbackEvents"], "{\"events\":[]}")
        XCTAssertEqual(entries["schemaVersion"], "spoken-margins.diagnostics.v1")
        XCTAssertEqual(entries["exportedAt"], "2026-10-03T04:00:00Z")
        XCTAssertEqual(entries["playbackStatus"], "playing")
        XCTAssertEqual(entries["sessionPhase"], "item_playback")
        XCTAssertEqual(entries["targetType"], "item_text_tts")
        XCTAssertEqual(entries["pendingAIJobs"], "3")
        XCTAssertEqual(entries["responsiveness"], ResponsivenessSummary(playbackEventsJSON: "{\"events\":[]}").text)
    }

    func testARecordingThatIsNotThereLeavesTheKeyOutEvenIfALiveEntryHadOne() {
        let entries = DiagnosticsExport.entries(
            live: ["developerRecording": "stale", "playbackEvents": "stale", "responsiveness": "stale"],
            stored: ["developerRecording": "stale"],
            fixed: fixed(developerRecording: nil, playbackEvents: nil)
        )

        XCTAssertFalse(entries.keys.contains("developerRecording"))
        XCTAssertFalse(entries.keys.contains("playbackEvents"))
        XCTAssertFalse(entries.keys.contains("responsiveness"))
    }

    func testNoTargetIsExportedAsNone() {
        let entries = DiagnosticsExport.entries(live: [:], stored: [:], fixed: fixed(targetType: nil))

        XCTAssertEqual(entries["targetType"], "none")
    }

    func testTheExportCarriesExactlyTheTenFixedKeysWhenThereIsNothingElse() {
        let entries = DiagnosticsExport.entries(live: [:], stored: [:], fixed: fixed())

        XCTAssertEqual(
            Set(entries.keys),
            ["developerBuild", "developerRecording", "playbackEvents", "schemaVersion", "exportedAt",
             "playbackStatus", "sessionPhase", "targetType", "pendingAIJobs", "responsiveness"]
        )
    }

    // MARK: The file text

    func testTheTextIsJSONWithTheKeysInOrderAndEveryEntryIntact() throws {
        // Eight keys, so a dictionary's own order matches the sorted one only once in forty thousand runs.
        let entries = [
            "h": "eight", "b": "two", "a": "one https://kept.example", "g": "seven",
            "c": "line\nbreak \"quoted\"", "f": "six", "d": "four", "e": "five",
        ]
        let text = try DiagnosticsExport.jsonText(entries)

        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(parsed, entries)
        let keys = entries.keys.sorted()
        let positions = try keys.map { try XCTUnwrap(text.range(of: "\"\($0)\" :") ?? text.range(of: "\"\($0)\":")).lowerBound }
        XCTAssertEqual(positions, positions.sorted(), "keys come out sorted: \(keys)")
        XCTAssertTrue(text.contains("\n"), "pretty-printed")
    }

    func testTheSchemaVersionNeverChangesByAccident() {
        XCTAssertEqual(DiagnosticsExport.schemaVersion, "spoken-margins.diagnostics.v1")
    }
}
