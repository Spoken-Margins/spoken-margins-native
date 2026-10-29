import Foundation

/// The welcome Item and Listening Map every new Library starts with (#959). Moved out of
/// Gate1AppModel so the text and the stored fields are pinned by tests that run on Linux. The text
/// must not change while ``Gate1AppModel``'s seed version stays 2: existing Libraries do not reseed.
public enum WelcomeSample {
    public static let fileName = "Welcome to Spoken Margins.md"
    public static let listeningMapOverview = "Take a guided tour of the Listening Map, playback navigation, spoken Margins, and the three ways to add your own sources."

    /// The sample's Markdown.
    public static func markdown() -> String {
        let optionalAIOverview = "Summarize Notes synthesizes the Margins in this session with Apple’s on-device model when available. Remote discussion and third-party API keys are disabled; you can copy your notes to another chatbot and paste its response back into Spoken Margins."
        return """
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

        \(optionalAIOverview) Listening, interjections, the Timeline, and export work without AI. Export the useful context for another writing or thinking tool. The goal is not passive playback; it is to help you retain and develop the ideas that mattered.
        """
    }

    /// The welcome Item (id `itemId`) and its deterministic Listening Map.
    public static func make(itemId: String) throws -> (Item, ListeningMap) {
        try build(itemId: itemId, contents: markdown())
    }

    /// `make` for any Markdown, so a test can reach the error for a text with no chapters.
    static func build(itemId: String, contents: String) throws -> (Item, ListeningMap) {
        let parsed = try ObsidianMarkdownParser.parse(fileName: fileName, contents: contents)
        let item = Item(
            id: itemId,
            title: parsed.title,
            mediaType: "text",
            text: parsed.text,
            externalReference: "",
            status: "ready"
        )
        guard var map = parsed.deterministicListeningMap(itemId: itemId) else {
            throw SessionKitError.persistenceFailed("welcome_sample_listening_map_missing")
        }
        map.overview = listeningMapOverview
        return (item, map)
    }
}
