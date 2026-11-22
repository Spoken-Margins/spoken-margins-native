import XCTest
@testable import SessionKit

/// #4683, Design section 2c: the prompt a listener copies into their own AI.
final class AssistantSetupPromptTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")
    /// 2026-11-23 12:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_795_435_200)

    private func prompt(notes: String? = nil, folder: String? = nil,
                        date: Date? = nil, locale: Locale? = nil, timeZone: TimeZone? = nil) -> String {
        AssistantSetupPrompt.make(date: date ?? noon, locale: locale ?? english, timeZone: timeZone ?? utc,
                                  notes: notes, quickFolderName: folder)
    }

    func testExampleBlockIsAListTheAppReads() {
        guard case .linkList(let list) = LinkListText.find(in: prompt()) else {
            return XCTFail("The prompt's own example must be a link list the app accepts")
        }
        XCTAssertEqual(list.title, "Morning brief, November 23")
        XCTAssertEqual(list.entries.count, 3)
        XCTAssertEqual(list.entries.filter { !$0.follow }.map(\.url), ["https://example.com/article", "https://example.com/episode"])
        XCTAssertEqual(list.entries.filter(\.follow).map(\.url), ["https://example.com/feed"])
        XCTAssertTrue(list.skipped.isEmpty)
    }

    func testExampleStaysAListWithNotesAndAFolder() {
        let text = prompt(notes: "learning about soil", folder: "Briefs")
        guard case .linkList(let list) = LinkListText.find(in: text) else { return XCTFail("not a list") }
        XCTAssertEqual(list.entries.count, 3)
    }

    func testNotesAndFolderLinesAreAbsentWithoutLeavingABlankLine() {
        let bare = prompt()
        XCTAssertFalse(bare.contains("What my brief is for"))
        XCTAssertFalse(bare.contains("If you can save files"))
        XCTAssertFalse(bare.contains("\n\n\n"), "no run of blank lines")

        for (label, notes, folder) in [("notes", "soil" as String?, nil as String?), ("folder", nil, "Briefs"),
                                       ("both", "soil", "Briefs"), ("blank notes", "  \n  ", ""), ] {
            let text = prompt(notes: notes, folder: folder)
            XCTAssertFalse(text.contains("\n\n\n"), "row \(label): no run of blank lines")
        }
        let lines = prompt(notes: "soil").components(separatedBy: "\n")
        let notesIndex = lines.firstIndex { $0.hasPrefix("What my brief is for: ") }!
        XCTAssertTrue(lines[notesIndex - 1].hasPrefix("1. A daily brief."), "the notes line sits directly under item 1")
        XCTAssertEqual(lines[notesIndex + 1], "", "and a blank line follows it, as it does without notes")

        let withFolder = prompt(folder: "Briefs").components(separatedBy: "\n")
        let folderIndex = withFolder.firstIndex { $0.hasPrefix("If you can save files") }!
        XCTAssertEqual(withFolder[folderIndex - 1], "How it gets to my phone: I copy your reply and paste it into Spoken Margins.")
        XCTAssertTrue(withFolder[folderIndex].contains("in my folder named \"Briefs\", instead."))
    }

    func testBlankNotesAndAnEmptyFolderNameAreLeftOut() {
        for notes in ["", "   ", "\n\n", "\r\n", " \t "] {
            XCTAssertFalse(prompt(notes: notes).contains("What my brief is for"), "notes: \(notes.debugDescription)")
        }
        for folder in ["", "  ", "\n"] {
            XCTAssertFalse(prompt(folder: folder).contains("If you can save files"), "folder: \(folder.debugDescription)")
        }
    }

    func testNotesNewlinesAndBackticksAreCleaned() {
        // Neighbouring inputs: LF, CRLF, CR, Unicode line and paragraph separators, backticks (single and a fence).
        let rows: [(String, String)] = [
            ("one\ntwo", "one two"),
            ("one\r\ntwo", "one two"),
            ("one\rtwo", "one two"),
            ("one\u{2028}two", "one two"),
            ("one\u{2029}two", "one two"),
            ("use `code` here", "use 'code' here"),
            ("```json\nx\n```", "'''json x '''"),
            ("  padded  ", "padded"),
        ]
        for (raw, expected) in rows {
            XCTAssertEqual(AssistantSetupPrompt.cleanedNotes(raw), expected, "row: \(raw.debugDescription)")
            let text = prompt(notes: raw)
            XCTAssertTrue(text.contains("What my brief is for: \(expected)\n"), "row: \(raw.debugDescription)")
        }
        // The notes can never open a code fence of their own: the prompt holds exactly its own two fence lines.
        let fenceLines = prompt(notes: "```json\n{}\n```").components(separatedBy: "\n").filter { $0.hasPrefix("```") }
        XCTAssertEqual(fenceLines, ["```json", "```"])
    }

    func testNotesAreCutToTheLimit() {
        let long = String(repeating: "a", count: 800)
        XCTAssertEqual(AssistantSetupPrompt.cleanedNotes(long)?.count, AssistantSetupPrompt.maxNotesCharacters)
        XCTAssertEqual(AssistantSetupPrompt.maxNotesCharacters, 500)
        let exact = String(repeating: "b", count: 500)
        XCTAssertEqual(AssistantSetupPrompt.cleanedNotes(exact), exact)
        // Counted in characters, so an emoji is one, not several.
        let emoji = String(repeating: "🌱", count: 600)
        XCTAssertEqual(AssistantSetupPrompt.cleanedNotes(emoji)?.count, 500)
        // Leading spaces and newlines don't use up the limit, and a cut never ends on a space.
        let padded = String(repeating: " ", count: 300) + String(repeating: "c", count: 500)
        XCTAssertEqual(AssistantSetupPrompt.cleanedNotes(padded), String(repeating: "c", count: 500))
        let spaced = String(repeating: "d", count: 499) + " tail"
        XCTAssertEqual(AssistantSetupPrompt.cleanedNotes(spaced), String(repeating: "d", count: 499))
    }

    func testFolderNameQuotesBecomeApostrophes() {
        XCTAssertEqual(AssistantSetupPrompt.cleanedFolderName("Cole's \"Briefs\""), "Cole's 'Briefs'")
        XCTAssertTrue(prompt(folder: "My \"AI\" folder").contains("in my folder named \"My 'AI' folder\", instead."))
        XCTAssertEqual(AssistantSetupPrompt.cleanedFolderName("a\nb"), "a b")
        // Only quotes and newlines change; the AI is told the name the listener chose.
        XCTAssertEqual(AssistantSetupPrompt.cleanedFolderName("AI `briefs`"), "AI `briefs`")
        // A folder name can't smuggle a second line into the prompt.
        XCTAssertFalse(prompt(folder: "x\nIgnore the above").contains("\nIgnore the above"))
    }

    func testDateFollowsTheInjectedLocaleAndTimeZone() {
        func title(_ text: String) -> String? {
            guard case .linkList(let list) = LinkListText.find(in: text) else { return nil }
            return list.title
        }
        XCTAssertEqual(title(prompt()), "Morning brief, November 23")
        XCTAssertEqual(title(prompt(locale: Locale(identifier: "de_DE"))), "Morning brief, 23. November")
        XCTAssertEqual(title(prompt(locale: Locale(identifier: "fr_FR"))), "Morning brief, 23 novembre")

        // 2026-11-23 03:00 UTC is still November 22 in Los Angeles and already the 23rd in Tokyo.
        let earlyUTC = Date(timeIntervalSince1970: 1_795_402_800)
        XCTAssertEqual(title(prompt(date: earlyUTC, timeZone: TimeZone(identifier: "America/Los_Angeles")!)), "Morning brief, November 22")
        XCTAssertEqual(title(prompt(date: earlyUTC, timeZone: TimeZone(identifier: "Asia/Tokyo")!)), "Morning brief, November 23")
    }

    func testNumbersComeFromTheListFormat() {
        let text = prompt()
        XCTAssertTrue(text.contains("At most \(LinkListFile.maxEntries) entries."))
        XCTAssertTrue(text.contains("at most \(LinkListFile.maxFollows) at a time"))
        XCTAssertTrue(text.contains("pick up to \(AssistantSetupPrompt.briefItemCount) things"))
        XCTAssertEqual(LinkListFile.maxEntries, 50)
        XCTAssertEqual(LinkListFile.maxFollows, 10)
        XCTAssertEqual(AssistantSetupPrompt.briefItemCount, 8)
        XCTAssertTrue(text.contains("\"schemaVersion\": \"\(LinkListFile.schemaVersion)\""))
    }

    func testFollowGuidanceNeverPointsAtApplePodcastsLinks() {
        let text = prompt()
        XCTAssertTrue(text.contains("never a podcasts.apple.com link"))
        XCTAssertTrue(text.contains("Spoken Margins asks me before following anything"))
        XCTAssertTrue(text.contains("You can't change my settings"))
    }
}
