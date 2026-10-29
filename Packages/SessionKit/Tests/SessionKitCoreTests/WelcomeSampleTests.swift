import XCTest
@testable import SessionKit

/// #959: the welcome sample every new Library starts with. The text is pinned in full: a changed
/// text with the same seed version (2) would never reach an existing Library, and a bumped
/// version would reseed it, so the text only changes together with that decision.
final class WelcomeSampleTests: XCTestCase {
    private let itemId = "item-spoken-margins-overview"

    private let aiParagraph = "Summarize Notes synthesizes the Margins in this session with Apple’s on-device model when available. Remote discussion and third-party API keys are disabled; you can copy your notes to another chatbot and paste its response back into Spoken Margins."

    /// The Markdown with the optional-AI paragraph left as a marker.
    private let markdownTemplate = """
        # Welcome to Spoken Margins

        Spoken Margins is a structured listening workspace. It restores the headings, progress, margin notes, and easy navigation that ordinary audio loses, so reading can become an active listening session.

        ## Start with the Listening Map

        Tap Start Listening on this source. The overview plays first, and the Timeline shows the chapters below. Tap any chapter to jump directly to it while keeping your place in the source.

        ## Move forward and backward

        On Now Playing, use the backward and forward buttons around Play to move by paragraph. The progress slider can move farther through the source. Open More to change the speech rate.

        ## Interject while you listen

        This is your practice cue. Tap Add a Margin, say one thing you want to remember about this tour, then save. Spoken Margins anchors your thought near the passage you were hearing and resumes without losing your place. Prefer typing? Tap the writing button beside Record. Open Margins to find, star, and review your note, or choose Play this moment to hear its source again.

        ## Load your own sources

        Return to Library and tap Add. Choose Paste Text or Link or Podcast, then Add to Library. You can also choose a document, PDF, DRM-free EPUB, or an MP3, M4A, M4B, or audio-bearing MP4 audiobook. Adding a source keeps your current listening session in place; choose the new item when you are ready to listen. In Safari, enable Spoken Margins Text under Manage Extensions to capture selected text or a readable article, or run the Add Article to Spoken Margins Shortcut from Safari’s Share menu. You can also share a PDF, Markdown file, or text file directly to Spoken Margins.

        ## Keep what matters

        {{AI}} Listening, interjections, the Timeline, and export work without AI. Export the useful context for another writing or thinking tool. The goal is not passive playback; it is to help you retain and develop the ideas that mattered.
        """

    private var expectedMarkdown: String {
        markdownTemplate.replacingOccurrences(of: "{{AI}}", with: aiParagraph)
    }

    func testTheWelcomeMarkdownIsPinnedInFull() {
        XCTAssertEqual(WelcomeSample.markdown(), expectedMarkdown)
        XCTAssertEqual(WelcomeSample.fileName, "Welcome to Spoken Margins.md")
    }

    func testTheOptionalAIParagraphNamesOnlyOnDeviceAI() {
        let text = WelcomeSample.markdown()
        XCTAssertTrue(text.contains(aiParagraph))
        // The curly apostrophes are part of the text.
        XCTAssertTrue(text.contains("Apple\u{2019}s on-device model"))
        XCTAssertTrue(text.contains("Safari\u{2019}s Share menu"))
    }

    func testTheSampleItemKeepsItsStoredFields() throws {
        let (item, _) = try WelcomeSample.make(itemId: itemId)
        XCTAssertEqual(item.id, "item-spoken-margins-overview")
        XCTAssertEqual(item.title, "Welcome to Spoken Margins")
        XCTAssertEqual(item.mediaType, "text")
        XCTAssertEqual(item.externalReference, "")
        XCTAssertEqual(item.status, "ready")
        XCTAssertNil(item.externalReferenceType)
        XCTAssertNil(item.createdAt)
        XCTAssertTrue(try XCTUnwrap(item.text).hasPrefix("Welcome to Spoken Margins\n\nSpoken Margins is a structured listening workspace. It restores"))
        XCTAssertEqual(item.text?.count, 2150)
    }

    func testTheSampleMapIsTheDeterministicMapWithTheTourOverview() throws {
        let (_, map) = try WelcomeSample.make(itemId: itemId)
        XCTAssertEqual(map.itemId, itemId)
        XCTAssertEqual(map.id, "map-item-spoken-margins-overview-markdown")
        XCTAssertEqual(
            map.overview,
            "Take a guided tour of the Listening Map, playback navigation, spoken Margins, and the three ways to add your own sources."
        )
        // The welcome text's `#` title heads its opening paragraph, so it is the first chapter (#1435).
        XCTAssertEqual(map.chapters.map(\.title), [
            "Welcome to Spoken Margins", "Start with the Listening Map", "Move forward and backward", "Interject while you listen",
            "Load your own sources", "Keep what matters"
        ])
        XCTAssertEqual(map.chapters.map(\.id), [
            "ch-markdown-01-welcome-to-spoken-margins", "ch-markdown-02-start-with-the-listening-map",
            "ch-markdown-03-move-forward-and-backward", "ch-markdown-04-interject-while-you-listen",
            "ch-markdown-05-load-your-own-sources", "ch-markdown-06-keep-what-matters"
        ])
        XCTAssertEqual(map.chapters.map(\.percent), [0, 10, 20, 30, 49, 76])
        XCTAssertEqual(map.chapters.map(\.startChar), [0, 228, 443, 652, 1054, 1654])
        XCTAssertEqual(map.chapters.last?.endChar, 2150)
    }

    func testATextWithNoChaptersThrowsTheStoredErrorCode() {
        XCTAssertThrowsError(try WelcomeSample.build(itemId: itemId, contents: "Only words here, with no headings at all.")) { error in
            XCTAssertEqual(error as? SessionKitError, .persistenceFailed("welcome_sample_listening_map_missing"))
        }
        // The error code is what the app records when seeding fails, so the real sample must not trip it.
        XCTAssertNoThrow(try WelcomeSample.build(itemId: itemId, contents: WelcomeSample.markdown()))
    }

    func testTheItemIdIsWhateverTheCallerSupplies() throws {
        let (item, map) = try WelcomeSample.make(itemId: "another-id")
        XCTAssertEqual(item.id, "another-id")
        XCTAssertEqual(map.itemId, "another-id")
    }
}
