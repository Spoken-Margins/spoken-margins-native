import Foundation

/// Turns the provider's reply to the assistant-chapter prompt into chapters (#998, P2 of the Gate1AppModel split).
///
/// This throws on a bad chapter. `SessionEngine.extractAssistantChapters` is a different reader that drops a bad
/// chapter instead; do not merge them.
public enum AssistantChapterParser {
    /// Reads the provider's reply to `ProviderPrompts.assistantChapters`. Anything off about the reply or a chapter's
    /// anchor throws, and a good reply becomes chapters whose offsets count Characters in `responseText`.
    public static func chapters(from raw: String, responseText: String) throws -> [Chapter] {
        let data = Data(raw.utf8)
        let envelope = try JSONDecoder().decode(AssistantChapterEnvelope.self, from: data)
        guard envelope.schemaVersion == "assistant-response-map.v1" else {
            throw SessionKitError.persistenceFailed("assistant_chapter_schema")
        }
        var seen = Set<String>()
        return try envelope.chapters.map { candidate in
            guard !candidate.id.isEmpty,
                  !candidate.title.isEmpty,
                  seen.insert(candidate.id).inserted,
                  let range = responseText.range(of: candidate.anchor) else {
                throw SessionKitError.persistenceFailed("assistant_chapter_anchor")
            }
            let start = responseText.distance(from: responseText.startIndex, to: range.lowerBound)
            let end = responseText.distance(from: responseText.startIndex, to: range.upperBound)
            return Chapter(
                id: candidate.id,
                title: candidate.title,
                startChar: start,
                endChar: end,
                percent: responseText.isEmpty ? 0 : Int((Double(start) / Double(responseText.count) * 100).rounded())
            )
        }
    }
}

private struct AssistantChapterEnvelope: Decodable {
    struct Candidate: Decodable {
        var id: String
        var title: String
        var anchor: String
    }

    var schemaVersion: String
    var chapters: [Candidate]
}
