import XCTest
@testable import SessionKit

/// #998: the text sent to the remote provider for the optional AI features. The words reach a
/// third party, so each prompt is pinned in full. The expected text below is what the code
/// produced in Gate1AppModel before it moved here.
final class ProviderPromptsTests: XCTestCase {
    private let source = "The harbour at Kettleness was built for herring boats."

    func testTheAssistantChapterPromptIsPinnedWordForWord() {
        XCTAssertEqual(ProviderPrompts.assistantChapters(responseText: "First idea. Second idea."), """
        Create 2 to 5 navigation chapters for the spoken response below. If it has fewer than two meaningful sections, return an empty chapters array.
        Return exactly {"schemaVersion":"assistant-response-map.v1","chapters":[{"id":"ch-1","title":"Short title","anchor":"exact phrase copied from RESPONSE"}]}.
        Every anchor must be an exact contiguous phrase from RESPONSE and identify the start of its section.
        RESPONSE:
        <<<
        First idea. Second idea.
        >>>
        """)
    }

    func testTheListeningMapPromptIsPinnedWordForWord() {
        XCTAssertEqual(ProviderPrompts.listeningMap(sourceText: source), """
        Create a Listening Map for the item content below.
        The user will listen to this content through text-to-speech, so the map must support quick navigation and situational awareness.
        Return only strict JSON. Use schemaVersion "listening-map.v1".
        Required object shape:
        {
          "schemaVersion": "listening-map.v1",
          "overview": "one or two sentence overview",
          "chapters": [
            {
              "id": "ch-1",
              "title": "short navigation title",
              "description": "what this chapter covers",
              "anchor": "exact contiguous phrase copied from ITEM CONTENT"
            }
          ]
        }
        Requirements: brief overview, navigable chapters, exact contiguous anchors copied from source, no invented anchors, no percent estimates, no start/end character offsets.
        JSON syntax rules: use ASCII double quotes for object keys and string delimiters. Preserve source punctuation, including curly quotes and apostrophes, only inside string values.
        Anchor quality rules: every anchor must be at least five words when possible; copy ordinary prose from the source, not headings; do not paraphrase; do not use ellipses.
        ITEM CONTENT:
        <<<
        The harbour at Kettleness was built for herring boats.
        >>>
        """)
    }

    func testTheListeningMapRepairPromptIsPinnedWordForWord() {
        let prompt = ProviderPrompts.listeningMapRepair(
            sourceText: source,
            invalidResponse: #"{"schemaVersion":"listening-map.v1","chapters":["#,
            error: "persistence_failed:listening_map_anchor"
        )
        XCTAssertEqual(prompt, """
        Repair the Listening Map JSON below. Return only strict JSON with schemaVersion "listening-map.v1".

        Parser/validator error:
        persistence_failed:listening_map_anchor

        Requirements:
        - Keep only JSON. No Markdown fences.
        - Use ASCII double quotes for JSON object keys and string delimiters.
        - Preserve source punctuation, including curly quotes and apostrophes, only inside string values.
        - Every chapter must have id, title, description, and anchor.
        - Every anchor must be an exact contiguous phrase copied from ITEM CONTENT, preferably at least five words.
        - Do not include percent estimates.
        - Prefer preserving the previous chapter intent if the anchor can be fixed.

        INVALID RESPONSE:
        <<<
        {"schemaVersion":"listening-map.v1","chapters":[
        >>>

        ITEM CONTENT:
        <<<
        The harbour at Kettleness was built for herring boats.
        >>>
        """)
    }

    /// The listener's text goes in as it is: no escaping, no trimming, between the markers the
    /// prompt tells the model to read.
    func testTheTextIsInsertedVerbatimBetweenTheMarkers() {
        let awkward = "Line one\n\"quoted\" \\ back\\slash \u{1F468}\u{200D}\u{1F469} {json: 1}\r\n<<< >>> RESPONSE:\n"
        XCTAssertTrue(ProviderPrompts.assistantChapters(responseText: awkward).contains("<<<\n\(awkward)\n>>>"))
        XCTAssertTrue(ProviderPrompts.listeningMap(sourceText: awkward).contains("<<<\n\(awkward)\n>>>"))

        let broken = "  BAD \"JSON\"  "
        let repair = ProviderPrompts.listeningMapRepair(sourceText: awkward, invalidResponse: broken, error: "the error")
        XCTAssertTrue(repair.contains("Parser/validator error:\nthe error\n"))
        XCTAssertTrue(repair.contains("INVALID RESPONSE:\n<<<\n\(broken)\n>>>"), "the broken reply is not trimmed")
        XCTAssertTrue(repair.contains("ITEM CONTENT:\n<<<\n\(awkward)\n>>>"))
        XCTAssertLessThan(
            repair.range(of: "INVALID RESPONSE:")!.lowerBound, repair.range(of: "ITEM CONTENT:")!.lowerBound,
            "the broken reply comes before the source"
        )
    }

    /// The schema names are the contract with the parsers that read the reply.
    func testThePromptsNameTheSchemasTheirParsersExpect() {
        XCTAssertTrue(ProviderPrompts.assistantChapters(responseText: "x").contains(#""schemaVersion":"assistant-response-map.v1""#))
        XCTAssertTrue(ProviderPrompts.listeningMap(sourceText: "x").contains(#"Use schemaVersion "listening-map.v1"."#))
        XCTAssertTrue(ProviderPrompts.listeningMapRepair(sourceText: "x", invalidResponse: "y", error: "z").contains(#"schemaVersion "listening-map.v1"."#))
    }
}
