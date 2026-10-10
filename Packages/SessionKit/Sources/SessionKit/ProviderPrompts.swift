import Foundation

/// The text sent to the remote provider for the optional AI features (#998, P2 of the Gate1AppModel split).
///
/// These words reach a third party, so a changed word is a behaviour change. Tests pin each prompt in full.
public enum ProviderPrompts {
    /// The prompt that asks the provider for navigation chapters of one spoken response.
    public static func assistantChapters(responseText: String) -> String {
        """
        Create 2 to 5 navigation chapters for the spoken response below. If it has fewer than two meaningful sections, return an empty chapters array.
        Return exactly {"schemaVersion":"assistant-response-map.v1","chapters":[{"id":"ch-1","title":"Short title","anchor":"exact phrase copied from RESPONSE"}]}.
        Every anchor must be an exact contiguous phrase from RESPONSE and identify the start of its section.
        RESPONSE:
        <<<
        \(responseText)
        >>>
        """
    }

    /// The prompt that asks the provider for a Listening Map of an item's text.
    public static func listeningMap(sourceText: String) -> String {
        """
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
        \(sourceText)
        >>>
        """
    }

    /// The prompt that asks the provider to fix a Listening Map the parser rejected. `error` is the parser's own description of the problem.
    public static func listeningMapRepair(sourceText: String, invalidResponse: String, error: String) -> String {
        """
        Repair the Listening Map JSON below. Return only strict JSON with schemaVersion "listening-map.v1".

        Parser/validator error:
        \(error)

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
        \(invalidResponse)
        >>>

        ITEM CONTENT:
        <<<
        \(sourceText)
        >>>
        """
    }
}
