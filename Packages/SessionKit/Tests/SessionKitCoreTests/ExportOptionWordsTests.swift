import XCTest
import SessionKit

/// #4956: the Export screen named its choices "AI Handoff Markdown", "Full JSON Archive", "Scope" and "AI Turns" with
/// no caption, so a listener couldn't tell what their notes app reads or what a toggle adds, and a toggle the scope
/// overrode still showed on. These pin the words both export screens show and the rule that dims an overridden toggle.
final class ExportOptionWordsTests: XCTestCase {
    func testFormatWords() {
        XCTAssertEqual(ExportFormatChoice.heading, "Format")
        XCTAssertEqual(ExportFormatChoice.allCases.map(\.label), ["Markdown", "JSON"])
        XCTAssertEqual(ExportFormatChoice.allCases.map(\.rawValue), ["markdown", "json"])
        XCTAssertEqual(
            ExportFormatChoice.markdown.caption,
            "A text file with headings, for notes apps such as Obsidian, or to paste into an AI chat."
        )
        XCTAssertEqual(
            ExportFormatChoice.json.caption,
            "Structured data for scripts and developer tools. Spoken Margins can't import it back."
        )
        // JSON is not a backup: nothing imports it and no recording goes in it.
        XCTAssertTrue(ExportFormatChoice.json.caption.contains("can't import it back"))
        XCTAssertFalse(ExportFormatChoice.json.caption.lowercased().contains("backup"))
    }

    func testContentsWords() {
        XCTAssertEqual(ExportContents.heading, "Contents")
        XCTAssertEqual(ExportContents.allCases.map(\.label), ["No Margins", "My Margins", "Everything"])
        XCTAssertEqual(ExportContents.allCases.map(\.tag), ["original", "source_interjections", "full_session"])
        XCTAssertEqual(
            ExportContents.noMargins.caption,
            "The source's details, without your Margins or Reflect on this session."
        )
        XCTAssertEqual(
            ExportContents.myMargins.caption,
            "Your Margins on the source, each with what you were hearing. Leaves out Reflect on this session and Margins on it."
        )
        XCTAssertEqual(
            ExportContents.everything.caption,
            "Your Margins, plus summaries and AI replies from Reflect on this session, with any Margins on them."
        )
    }

    func testToggleWords() {
        let expected: [(ExportToggle, String, String)] = [
            (.sourceText, "Source Text", "The full text of the article, PDF or document."),
            (.spokenNoteText, "Spoken Note Text", "Your note's own words, from each recording."),
            (.sourceLink, "Source Link", "The web address, and a PDF's citation, so you can find the original."),
            (.listeningMap, "Listening Map", "The source's overview and chapters."),
            (.margins, "Margins", "What you said or wrote, each with what you were hearing."),
            (.reflections, "Summaries and AI Replies", "Summaries and pasted AI answers from Reflect on this session.")
        ]
        XCTAssertEqual(ExportToggle.allCases.count, expected.count)
        for (toggle, title, caption) in expected {
            XCTAssertEqual(toggle.title, title)
            XCTAssertEqual(toggle.caption, caption, title)
        }
        XCTAssertEqual(
            ExportToggle.sourceTextUnavailableCaption,
            "Podcasts and audio files don't export their full transcript. Each Margin still brings a short stretch of what you were hearing, when there is a transcript."
        )
        XCTAssertEqual(ExportScreenWords.batchHeading, "What to Include")
        XCTAssertEqual(ExportScreenWords.batchJumpHint, "Jumps to What to Include and the Export button.")
    }

    func testNoShownWordIsAnInternalName() {
        var shown: [String] = [ExportFormatChoice.heading, ExportContents.heading,
                               ExportToggle.sourceTextUnavailableCaption,
                               ExportScreenWords.batchHeading, ExportScreenWords.batchJumpHint]
        shown += ExportFormatChoice.allCases.flatMap { [$0.label, $0.caption] }
        shown += ExportContents.allCases.flatMap { [$0.label, $0.caption] }
        shown += ExportToggle.allCases.flatMap { toggle in
            [toggle.title, toggle.caption] + ExportContents.allCases.compactMap { toggle.overriddenCaption(by: $0) }
        }
        let banned = ["AI Handoff", "Archive", "Turns", "Interjection", "Native audio", "bounded", "Scope",
                      "Included Material"]
        for text in shown {
            for word in banned {
                XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\"\(text)\" says \"\(word)\"")
            }
        }
    }

    func testSavedValuesMapToWhatTheScreenShows() {
        let scopes: [(String, ExportContents)] = [
            ("original", .noMargins), ("source_only", .noMargins),
            ("source_interjections", .myMargins), ("original_with_interjections", .myMargins),
            ("full_session", .everything), ("", .everything), ("unknown", .everything)
        ]
        for (stored, shown) in scopes {
            XCTAssertEqual(ExportContents(storedScope: stored), shown, stored)
        }
        let formats: [(String, ExportFormatChoice)] = [
            ("markdown", .markdown), ("json", .json), ("", .markdown), ("unknown", .markdown)
        ]
        for (stored, shown) in formats {
            XCTAssertEqual(ExportFormatChoice(storedFormat: stored), shown, stored)
        }
    }

    func testAToggleTheContentsChoiceLeavesOutShowsOffAndSaysWhy() {
        for contents in ExportContents.allCases {
            for toggle in ExportToggle.allCases {
                let expectedCaption: String?
                switch (toggle, contents) {
                case (.margins, .noMargins): expectedCaption = "Left out by No Margins above."
                case (.reflections, .noMargins), (.reflections, .myMargins):
                    expectedCaption = "Only Everything includes these."
                default: expectedCaption = nil
                }
                let label = "\(toggle) under \(contents)"
                XCTAssertEqual(toggle.overriddenCaption(by: contents), expectedCaption, label)
                XCTAssertEqual(toggle.shownOn(stored: true, contents: contents), expectedCaption == nil, label)
                XCTAssertFalse(toggle.shownOn(stored: false, contents: contents), label)
            }
        }
        // First run: Everything, nothing overridden.
        XCTAssertEqual(ExportContents(storedScope: "full_session"), .everything)
        XCTAssertTrue(ExportToggle.allCases.allSatisfy { $0.overriddenCaption(by: .everything) == nil })
    }
}
