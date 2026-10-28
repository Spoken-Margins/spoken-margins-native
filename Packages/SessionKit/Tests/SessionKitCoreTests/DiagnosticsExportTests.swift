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

    // MARK: Rule D: no article title or address in an entry name or value (#2850)

    /// Library ids for web imports are the page title plus the start of the address.
    private static let itemIds = [
        "My Secret Reading List https://example.com/a",
        "Café «Résumé»: Ünïcödé naïveté – 日本語の記事 https://例え.jp/記事",
        "https://substack.com/@someone/p/a-private-post?token=abc",
        "Re: Re: Fwd: the lawyer's memo, (draft) [v2] #3 \"final\"",
        String(repeating: "Zanzibar Harvest Diaries ", count: 40) + "https://example.com/" + String(repeating: "x", count: 300),
        "file name with spaces & symbols.pdf",
        "a:b:c::d",
    ]

    private static let itemKeyNames = [
        "automaticAudioPreparation", "startupAudioPreparation", "podcastDownload", "explicitAudioPreparation",
        "textAudioPrewarm", "sourceTranscriptDiscovery", "localAudioSkim", "podcastPlacementDeferred",
    ]

    func testNoItemIdSurvivesInAnEntryNameForAnyKindOfId() throws {
        for id in Self.itemIds {
            let live = Dictionary(uniqueKeysWithValues: Self.itemKeyNames.map { ("\($0):\(id)", "queued") })
            let entries = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed())
            let text = try DiagnosticsExport.jsonText(entries)
            for fragment in id.split(whereSeparator: { " :/".contains($0) }) where fragment.count >= 4 {
                XCTAssertFalse(text.contains(String(fragment)), "\(fragment) of \(id.prefix(30)) is in the export")
            }
            for name in Self.itemKeyNames {
                let keys = entries.keys.filter { $0.hasPrefix("\(name):") }
                XCTAssertEqual(keys.count, 1, "\(name) keeps one entry for the item")
                XCTAssertEqual(entries[keys[0]], "queued", "the value is kept")
            }
        }
    }

    func testEntriesForTheSameItemShareOneTokenAndDifferentItemsDoNot() {
        let live = [
            "automaticAudioPreparation:\(Self.itemIds[0])": "queued",
            "startupAudioPreparation:\(Self.itemIds[0])": "ready_2_of_4",
            "automaticAudioPreparation:\(Self.itemIds[1])": "queued",
            "lastImport": Self.itemIds[0],
        ]
        let entries = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed())
        let token = DiagnosticsExport.token(Self.itemIds[0])
        XCTAssertEqual(entries["automaticAudioPreparation:\(token)"], "queued")
        XCTAssertEqual(entries["startupAudioPreparation:\(token)"], "ready_2_of_4")
        XCTAssertEqual(entries["lastImport"], token, "a value that names the item carries the same token as its keys")
        XCTAssertEqual(entries["automaticAudioPreparation:\(DiagnosticsExport.token(Self.itemIds[1]))"], "queued")
        XCTAssertNotEqual(token, DiagnosticsExport.token(Self.itemIds[1]))
        XCTAssertEqual(token.count, 12)
    }

    func testValuesThatNameAnItemLeaveAsTokensAndNoneStaysNone() {
        let id = Self.itemIds[0]
        var live: [String: String] = [:]
        for key in DiagnosticsExport.keysHoldingAnItemId { live[key] = id }
        live["lastSourceLinkImport"] = "none"
        live["lastSharedPDFImport"] = "Tax Return 2025.pdf"
        live["lastRemotePDFImport"] = "https://example.com/private.pdf"
        let entries = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed())
        for key in DiagnosticsExport.keysHoldingAnItemId where key != "lastSourceLinkImport" {
            XCTAssertEqual(entries[key], DiagnosticsExport.token(id), key)
        }
        XCTAssertEqual(entries["lastSourceLinkImport"], "none")
        XCTAssertNil(entries["lastSharedPDFImport"], "a file name is what the listener chose")
        XCTAssertEqual(entries["lastRemotePDFImport"], "<redacted-url>")
    }

    func testAFeedEntryImportKeepsItsShapeWithTokensForTheIds() {
        let item = Self.itemIds[2]
        let entries = DiagnosticsExport.entries(
            live: ["sourceEntryImport:https://example.com/feed/1": "item:\(item),subscription:sub-1"],
            stored: [:],
            fixed: fixed()
        )
        let key = "sourceEntryImport:\(DiagnosticsExport.token("https://example.com/feed/1"))"
        XCTAssertEqual(entries[key], "item:\(DiagnosticsExport.token(item)),subscription:sub-1")
    }

    func testKeysWithoutAnIdAndPerMarginKeysAreLeftAlone() {
        let marginKey = PodcastAnchorCaptureDiagnostics.marginKey("marginCuration", sessionId: "s1", interjectionId: "ij-1")
        let entries = DiagnosticsExport.entries(
            live: ["automaticAudioPreparation": "whileCharging", "trailing:": "x", marginKey: "starred", "a:b": "y"],
            stored: [:],
            fixed: fixed()
        )
        XCTAssertEqual(entries["automaticAudioPreparation"], "whileCharging")
        XCTAssertEqual(entries["trailing:"], "x")
        XCTAssertEqual(entries[marginKey], "starred")
        XCTAssertNil(entries["a:b"], "any other suffix is treated as an id")
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
