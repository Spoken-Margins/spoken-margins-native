import Foundation
import XCTest
@testable import SessionKit

/// #3344: a toast leaves a timestamped event in the export, and never its words.
final class FeedbackShownEventTests: XCTestCase {
    private func fields(
        _ message: String,
        kind: FeedbackBannerPolicy.Kind = .error,
        fileID: String = "SpokenMarginsApp/Gate1AppModel+Imports.swift",
        line: Int = 42,
        hasAction: Bool = false,
        replaced: Bool = false,
        suppressed: Bool = false
    ) -> [String: String] {
        FeedbackShownEvent.fields(kind: kind, fileID: fileID, line: line, message: message,
                                  hasAction: hasAction, replaced: replaced, suppressed: suppressed)
    }

    func testTheFiveFieldsArePresent() {
        let f = fields("Added", kind: .success, hasAction: true, replaced: true)
        XCTAssertEqual(f["kind"], "success")
        XCTAssertEqual(f["site"], "Gate1AppModel+Imports.swift:42")
        XCTAssertEqual(f["textToken"], DiagnosticsExport.token("Added"))
        XCTAssertEqual(f["hasAction"], "true")
        XCTAssertEqual(f["replaced"], "true")
        XCTAssertEqual(f["suppressed"], "false")
    }

    /// Neighbouring messages: none may appear, whole or in part, in any key or value.
    func testNoMessageTextOrTitleReachesTheFields() {
        let title = "My Secret Plans"
        let messages = [
            "Could not import \(title)",
            "\(title) was added to your Library",
            "",
            "   ",
            "Café ☕️ 日本語 — “quoted” \(title) 👩🏽‍💻",
            "e\u{301} \(title) e\u{301}",
            String(repeating: "\(title) ", count: 5_000),
            "https://example.com/My-Secret-Plans",
        ]
        for message in messages {
            for suppressed in [false, true] {
                let f = fields(message, suppressed: suppressed)
                let everything = f.keys.joined(separator: "|") + "|" + f.values.joined(separator: "|")
                XCTAssertFalse(everything.contains("Secret"), "title leaked for \(message.prefix(30))")
                XCTAssertFalse(everything.contains("Plans"))
                XCTAssertFalse(everything.contains("Could not"))
                XCTAssertFalse(everything.contains("Café"))
                XCTAssertFalse(everything.contains("example.com"))
                XCTAssertLessThan(everything.count, 200, "fields must not grow with the message")
                XCTAssertNotNil(f["textToken"]?.range(of: "^[0-9a-f]{12}$", options: .regularExpression))
            }
        }
    }

    func testIdenticalMessagesShareATokenAndDifferentOnesDoNot() {
        XCTAssertEqual(fields("Could not import My Secret Plans")["textToken"],
                       fields("Could not import My Secret Plans")["textToken"])
        XCTAssertNotEqual(fields("A")["textToken"], fields("B")["textToken"])
    }

    func testSiteNamesTheCallerNotTheWrapper() {
        XCTAssertEqual(FeedbackShownEvent.site(fileID: "SpokenMarginsApp/Gate1AppModel+Audio.swift", line: 7),
                       "Gate1AppModel+Audio.swift:7")
        XCTAssertEqual(fields("x", fileID: "SpokenMarginsApp/Caller.swift", line: 9)["site"], "Caller.swift:9")
    }

    func testASiteThatIsNotAFileNameBecomesUnknown() {
        let long = "Mod/" + String(repeating: "a", count: 200) + ".swift"
        for bad in ["", "/", "Could not import My Secret Plans", "Mod/My Secret Plans.swift", long, "Mod/Ünï.swift"] {
            XCTAssertEqual(FeedbackShownEvent.site(fileID: bad, line: 1), "unknown", bad)
        }
        XCTAssertEqual(FeedbackShownEvent.site(fileID: "A/B.swift", line: -3), "B.swift:0")
    }

    func testASuppressedToastIsNotLoggedAsShown() {
        XCTAssertEqual(FeedbackShownEvent.kind(suppressed: false), "feedback.shown")
        XCTAssertEqual(FeedbackShownEvent.kind(suppressed: true), "feedback.suppressed")
        let f = fields("x", replaced: true, suppressed: true)
        XCTAssertEqual(f["suppressed"], "true")
        XCTAssertEqual(f["replaced"], "false")
    }

    func testTheEventSurvivesTheExportWithoutTheTitle() throws {
        let f = fields("Could not import My Secret Plans", fileID: "SpokenMarginsApp/X.swift")
        let event: [String: Any] = ["time": "t", "elapsedMs": 1, "kind": FeedbackShownEvent.shownKind, "fields": f]
        let json = String(data: try JSONSerialization.data(withJSONObject: ["events": [event]]), encoding: .utf8)!
        let fixed = DiagnosticsExport.Fixed(
            developerBuild: "b", developerRecording: nil, playbackEvents: json,
            exportedAt: Date(timeIntervalSince1970: 0), playbackStatus: "paused", sessionPhase: "p",
            targetType: nil, pendingAIJobs: 0)
        let live = ["lastStatus": "Could not import My Secret Plans", "recentFailure": "Could not import My Secret Plans"]
        let entries = DiagnosticsExport.entries(live: live, stored: [:], fixed: fixed)
        let text = try DiagnosticsExport.jsonText(entries)
        XCTAssertTrue(text.contains("feedback.shown"))
        XCTAssertFalse(text.contains("Secret"))
        XCTAssertFalse(text.contains("Plans"))
        XCTAssertNil(entries["lastStatus"])
    }
}
