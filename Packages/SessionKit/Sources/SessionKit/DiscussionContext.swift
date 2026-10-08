import Foundation

/// What Discuss and the Margin summary tell the AI provider about the current item, and which Margins the
/// current conversation change is about.
///
/// The provider receives `contextJSON` as text, so a changed key, value or order changes what it sees. The schema
/// versions are `session-export.v1` (no follow-up yet) and `conversation-context.v2` (a follow-up is being asked).
/// The model reads its live state (selected item, playback target) and passes it in; nothing here reads an engine.
public enum DiscussionContext {
    /// The Margins on whatever is playing now: a summary turn, an AI response turn, or the item itself.
    public static func currentTargetInterjections(
        interjections: [Interjection],
        currentTargetType: String,
        currentTargetId: String?,
        itemId: String
    ) -> [Interjection] {
        switch currentTargetType {
        case TargetType.summaryTurnTTS.rawValue:
            return interjections.filter { $0.targetType == .summaryTurn && $0.targetId == currentTargetId }
        case TargetType.assistantTurnTTS.rawValue:
            return interjections.filter { $0.targetType == .assistantTurn && $0.targetId == currentTargetId }
        default:
            return interjections.filter { $0.targetType == .item && $0.targetId == itemId }
        }
    }

    public static func primaryRequest(explicitFollowUp: String, currentInterjections: [Interjection]) -> String {
        let trimmed = explicitFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let transcripts = currentInterjections
            .map { ($0.cleanedTranscript ?? $0.transcript ?? $0.displayText ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !transcripts.isEmpty else {
            return "Continue the discussion from the latest change in the conversation."
        }
        return (["Respond to the current conversation change expressed in these interjections."] +
            transcripts.map { "- \($0)" }).joined(separator: "\n")
    }

    public static func primaryIntentSource(explicitFollowUp: String, currentInterjections: [Interjection]) -> String {
        if !explicitFollowUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "typed_follow_up"
        }
        return currentInterjections.isEmpty ? "conversation_continuation" : "target_interjections"
    }

    /// The pretty-printed, key-sorted JSON the provider prompts embed. `currentFollowUp` nil builds the summary
    /// context; a value builds the conversation context with a `primaryUserIntent`.
    public static func contextJSON(
        itemTitle: String,
        itemText: String,
        overview: String,
        chapters: [Chapter],
        turns: [ConversationTurn],
        currentTargetType: String,
        currentTargetId: String?,
        interjections: [Interjection],
        currentFollowUp: String?,
        explicitFollowUp: String? = nil,
        primaryInterjections: [Interjection] = []
    ) -> String {
        let map: [String: Any] = [
            "schemaVersion": currentFollowUp == nil ? "session-export.v1" : "conversation-context.v2",
            "item": [
                "title": itemTitle,
                "text": itemText
            ],
            "listeningMap": [
                "overview": overview,
                "chapters": chapters.map { chapter in
                    [
                        "title": chapter.title,
                        "startChar": chapter.startChar,
                        "endChar": chapter.endChar
                    ]
                }
            ],
            "interjections": interjections.map(interjectionRecord),
            "primaryUserIntent": currentFollowUp.map { followUp in
                [
                    "source": primaryIntentSource(
                        explicitFollowUp: explicitFollowUp ?? "",
                        currentInterjections: primaryInterjections
                    ),
                    "request": followUp,
                    "targetType": currentTargetType,
                    "target": targetContext(
                        currentTargetType: currentTargetType,
                        currentTargetId: currentTargetId,
                        turns: turns,
                        itemTitle: itemTitle,
                        overview: overview
                    ),
                    "interjections": primaryInterjections.map(interjectionRecord)
                ] as [String: Any]
            } ?? NSNull(),
            "recentTurns": turns.suffix(6).map { turn in
                [
                    "role": turn.role,
                    "turnType": turn.turnType,
                    "text": turn.summary ?? turn.text ?? turn.rawText ?? ""
                ]
            },
            "currentFollowUp": currentFollowUp.map { $0 as Any } ?? NSNull()
        ]
        // A serialization error gives empty data and so an empty string; "{}" is only the UTF-8 decoding fallback.
        // The map holds only strings, integers, arrays and null, so neither branch is reachable today. Kept as it was.
        let data = (try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Retain the candidate extraction's public argument order while using the landed implementation.
    public static func targetContext(
        itemTitle: String,
        overview: String,
        turns: [ConversationTurn],
        currentTargetType: String,
        currentTargetId: String?
    ) -> [String: Any] {
        targetContext(
            currentTargetType: currentTargetType,
            currentTargetId: currentTargetId,
            turns: turns,
            itemTitle: itemTitle,
            overview: overview
        )
    }

    /// What the provider is told is being discussed right now: the summary or response turn when one is playing
    /// and still in the conversation, otherwise the item itself.
    static func targetContext(
        currentTargetType: String,
        currentTargetId: String?,
        turns: [ConversationTurn],
        itemTitle: String,
        overview: String
    ) -> [String: Any] {
        let targetId = currentTargetId ?? ""
        switch currentTargetType {
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            if let turn = turns.first(where: { $0.id == targetId }) {
                return [
                    "targetType": currentTargetType,
                    "role": turn.role,
                    "turnType": turn.turnType,
                    "summary": turn.summary ?? "",
                    "text": turn.text ?? turn.rawText ?? ""
                ]
            }
        default:
            break
        }
        return [
            "targetType": TargetType.itemTextTTS.rawValue,
            "title": itemTitle,
            "overview": overview
        ]
    }

    private static func interjectionRecord(_ interjection: Interjection) -> [String: String] {
        [
            "targetType": interjection.targetType.rawValue,
            "anchorBefore": interjection.anchor.anchorBefore,
            "anchorAfter": interjection.anchor.anchorAfter,
            "transcriptionStatus": interjection.transcriptionStatus,
            "transcript": interjection.cleanedTranscript ?? interjection.transcript ?? "pending"
        ]
    }
}
