import Foundation
import XCTest
@testable import SessionKit

/// #2708: a photo of the page is a small, bounded, local reference on a live-session Margin.
final class LiveSessionPhotoTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-03-04T10:00:00Z")!
    private let good = "SpokenMargins/live-photos/s1/a.jpg"

    func testAcceptsAPathUnderTheFolderWithinTheCaps() {
        XCTAssertNotNil(LiveSessionPhoto(path: good, widthPx: 2_048, heightPx: 1_536, byteCount: 1_500_000))
        XCTAssertNotNil(LiveSessionPhoto(path: "SpokenMargins/live-photos/s1/a.HEIC", widthPx: 1, heightPx: 1, byteCount: 1))
    }

    func testRefusesPathsThatEscapeOrAreNotPhotos() {
        let bad = [
            "/SpokenMargins/live-photos/s1/a.jpg", "SpokenMargins/live-photos/../x.jpg", "SpokenMargins/live-photos/s1/../../x.jpg",
            "SpokenMargins/live-photos//a.jpg", "SpokenMargins/live-photos/./s1/a.jpg", "SpokenMargins/live-photos/a.jpg",
            "SpokenMargins/interjections/s1/a.jpg", "SpokenMargins/live-photos-x/s1/a.jpg", "live-photos/s1/a.jpg",
            "SpokenMargins/live-photos/s1/a.png", "SpokenMargins/live-photos/s1/a", "SpokenMargins/live-photos/s1/",
            "SpokenMargins\\live-photos\\s1\\a.jpg", "SpokenMargins/live-photos/s1/a\0.jpg", "", "file:///etc/passwd",
            "https://example.com/SpokenMargins/live-photos/s1/a.jpg"
        ]
        for path in bad {
            XCTAssertFalse(LiveSessionPhoto.isValid(path: path), path)
            XCTAssertNil(LiveSessionPhoto(path: path, widthPx: 10, heightPx: 10, byteCount: 10), path)
        }
    }

    func testRefusesOversizeOrEmptyPhotos() {
        XCTAssertNil(LiveSessionPhoto(path: good, widthPx: 2_049, heightPx: 100, byteCount: 10))
        XCTAssertNil(LiveSessionPhoto(path: good, widthPx: 100, heightPx: 2_049, byteCount: 10))
        XCTAssertNil(LiveSessionPhoto(path: good, widthPx: 100, heightPx: 100, byteCount: 1_500_001))
        XCTAssertNil(LiveSessionPhoto(path: good, widthPx: 0, heightPx: 100, byteCount: 10))
        XCTAssertNil(LiveSessionPhoto(path: good, widthPx: 100, heightPx: -1, byteCount: 10))
        XCTAssertNil(LiveSessionPhoto(path: good, widthPx: 100, heightPx: 100, byteCount: 0))
    }

    func testFittedScalesDownOnlyAndKeepsTheShape() {
        XCTAssertEqual(LiveSessionPhoto.fitted(width: 4_032, height: 3_024).map { [$0.width, $0.height] }, [2_048, 1_536])
        XCTAssertEqual(LiveSessionPhoto.fitted(width: 3_024, height: 4_032).map { [$0.width, $0.height] }, [1_536, 2_048])
        XCTAssertEqual(LiveSessionPhoto.fitted(width: 2_048, height: 1_000).map { [$0.width, $0.height] }, [2_048, 1_000])
        XCTAssertEqual(LiveSessionPhoto.fitted(width: 640, height: 480).map { [$0.width, $0.height] }, [640, 480])
        // A very thin strip never rounds to zero.
        XCTAssertEqual(LiveSessionPhoto.fitted(width: 40_000, height: 3).map { [$0.width, $0.height] }, [2_048, 1])
        XCTAssertNil(LiveSessionPhoto.fitted(width: 0, height: 100))
        XCTAssertNil(LiveSessionPhoto.fitted(width: 100, height: -5))
        for (w, h) in [(4_032, 3_024), (12_000, 9_000), (5, 9_999), (2_049, 2_049)] {
            let size = LiveSessionPhoto.fitted(width: w, height: h)!
            XCTAssertNotNil(LiveSessionPhoto(path: good, widthPx: size.width, heightPx: size.height, byteCount: 1), "\(w)x\(h)")
        }
    }

    func testTextAlternativePrefersWordsThenPlaceThenNote() {
        let page = LiveSessionPlace(unit: .page, value: 118)
        XCTAssertEqual(LiveSessionPhoto.altText(text: "  The budget paragraph ", whereNote: "ch 5", place: page), "Photo with Margin: The budget paragraph")
        XCTAssertEqual(LiveSessionPhoto.altText(text: "", whereNote: "ch 5", place: page), "Photo of the page at page 118")
        XCTAssertEqual(LiveSessionPhoto.altText(text: " ", whereNote: " chapter 5 ", place: nil), "Photo of the page at chapter 5")
        XCTAssertEqual(LiveSessionPhoto.altText(text: "", whereNote: nil, place: nil), "Photo of the page")
        XCTAssertEqual(LiveSessionPhoto.altText(text: "", whereNote: "  ", place: nil), "Photo of the page")
    }

    func testEveryPhotoMarginHasAnAlternativeAndOthersHaveNone() {
        var live = LiveSession(id: "s1", kind: .paper, title: "Book", startedAt: start, endedAt: nil, startPositionMs: 0)
        var margin = live.margin(id: "a", text: "", markedAt: start.addingTimeInterval(5))
        XCTAssertNil(margin.photoAltText)
        margin.photo = LiveSessionPhoto(path: good, widthPx: 800, heightPx: 600, byteCount: 90_000)
        XCTAssertEqual(margin.photoAltText, "Photo of the page")
        XCTAssertEqual(live.margins.count, 0)
    }

    func testControlCharactersAndPercentEscapesAreRefused() {
        for path in ["SpokenMargins/live-photos/s1/a\n.jpg", "SpokenMargins/live-photos/s1/a\r.jpg", "SpokenMargins/live-photos/s1/\u{202E}a.jpg",
                     "SpokenMargins/live-photos/%2e%2e/a.jpg", "SpokenMargins/live-photos/s1/a%00.jpg"] {
            XCTAssertFalse(LiveSessionPhoto.isValid(path: path), path)
        }
    }

    func testTheAlternativeIsOneShortLine() {
        let long = String(repeating: "word ", count: 100)
        let alt = LiveSessionPhoto.altText(text: "first line\nsecond\r\nthird " + long, whereNote: nil, place: nil)
        XCTAssertFalse(alt.contains("\n") || alt.contains("\r"))
        XCTAssertLessThanOrEqual(alt.count, "Photo with Margin: ".count + 121)
        XCTAssertTrue(alt.hasPrefix("Photo with Margin: first line second third word"))
    }

    func testAHandEditedPhotoThatBreaksTheRulesLoadsButIsNotUsedOrExported() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var live = LiveSession(id: "s1", kind: .paper, title: "Book", startedAt: start, endedAt: start.addingTimeInterval(60), startPositionMs: 0)
        var margin = live.margin(id: "a", text: "budget", markedAt: start.addingTimeInterval(5))
        margin.photo = LiveSessionPhoto(path: good, widthPx: 800, heightPx: 600, byteCount: 90_000)
        live.margins = [margin]
        try LiveSessionStore.save(live, in: directory)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: LiveSessionStore.url(in: directory))) as? [String: Any])
        var margins = try XCTUnwrap(object["margins"] as? [[String: Any]])
        margins[0]["photo"] = ["path": "SpokenMargins/live-photos/../../x.jpg", "widthPx": 800, "heightPx": 600, "byteCount": 99_000_000] as [String: Any]
        object["margins"] = margins
        try JSONSerialization.data(withJSONObject: object).write(to: LiveSessionStore.url(in: directory), options: .atomic)
        let loaded = try XCTUnwrap(LiveSessionStore.load(from: directory))
        XCTAssertEqual(loaded.margins.first?.text, "budget")
        XCTAssertNil(loaded.margins.first?.validPhoto)
        XCTAssertNil(loaded.margins.first?.photoAltText)
        let markdown = LiveSessionMarkdown.render(LiveSessionRecord(itemId: "i", session: loaded, transcript: nil, placed: []), includeTranscript: false)
        XCTAssertFalse(markdown.contains("Photo:"), markdown)
    }

    func testASessionWithAPhotoRoundTripsAndAnOldSessionStillReads() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "photo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var live = LiveSession(id: "s1", kind: .paper, title: "Book", startedAt: start, endedAt: nil, startPositionMs: 0)
        var withPhoto = live.margin(id: "a", text: "page about budgets", markedAt: start.addingTimeInterval(5))
        withPhoto.photo = LiveSessionPhoto(path: good, widthPx: 800, heightPx: 600, byteCount: 90_000)
        let plain = live.margin(id: "b", text: "no photo", markedAt: start.addingTimeInterval(9))
        live.margins = [withPhoto, plain]
        try LiveSessionStore.save(live, in: directory)
        XCTAssertEqual(LiveSessionStore.load(from: directory), live)

        // A Margin without a photo writes no `photo` key, so a session saved by this build reads in an earlier one.
        let json = try String(contentsOf: LiveSessionStore.url(in: directory), encoding: .utf8)
        XCTAssertEqual(json.components(separatedBy: "\"photo\"").count - 1, 1)

        // A session saved before photos existed reads, with no photo.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: LiveSessionStore.url(in: directory))) as? [String: Any])
        object["margins"] = try XCTUnwrap(object["margins"] as? [[String: Any]]).map { $0.filter { $0.key != "photo" } }
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("\"photo\""), "fixture edit failed")
        try old.write(to: LiveSessionStore.url(in: directory), options: .atomic)
        XCTAssertNil(LiveSessionStore.load(from: directory)?.margins.first?.photo)
        XCTAssertEqual(LiveSessionStore.load(from: directory)?.margins.first?.text, "page about budgets")
    }

    func testTheMarkdownExportNamesThePhotoAndSaysItStaysOnThePhone() {
        var live = LiveSession(id: "s1", kind: .paper, title: "Book", startedAt: start, endedAt: start.addingTimeInterval(60), startPositionMs: 0)
        var margin = live.margin(id: "a", text: "budget paragraph", markedAt: start.addingTimeInterval(5))
        margin.photo = LiveSessionPhoto(path: good, widthPx: 800, heightPx: 600, byteCount: 90_000)
        live.margins = [margin, live.margin(id: "b", text: "plain", markedAt: start.addingTimeInterval(30))]
        let record = LiveSessionRecord(itemId: "item", session: live, transcript: nil, placed: [])
        let markdown = LiveSessionMarkdown.render(record, includeTranscript: false, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(markdown.components(separatedBy: "Photo: ").count - 1, 1)
        XCTAssertTrue(markdown.contains("Photo: \(good) (Photo with Margin: budget paragraph; stays on this phone)"), markdown)
    }

    /// A photo never travels in a packet or share link. If the sharing module ever names the type, this fails and the
    /// change needs the explicit step the issue asks for, with the listener's say-so.
    func testTheSharingModuleNeverMentionsPhotos() throws {
        let sharing = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/SessionKitSharing")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sharing, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            checked += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("LiveSessionPhoto"), file.lastPathComponent)
            XCTAssertFalse(text.contains("photoAltText"), file.lastPathComponent)
        }
        XCTAssertGreaterThan(checked, 0, "found no sharing sources to check")
    }
}
