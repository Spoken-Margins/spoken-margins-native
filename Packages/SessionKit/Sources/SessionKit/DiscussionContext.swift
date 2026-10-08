import Foundation

public enum DiscussionContext {
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

    public static func contextJSON(
        itemTitle: String, itemText: String, overview: String,
        chapters: [Chapter], turns: [ConversationTurn],
        currentTargetType: String, currentTargetId: String?,
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
            "interjections": interjections.map { interjection in
                [
                    "targetType": interjection.targetType.rawValue,
                    "anchorBefore": interjection.anchor.anchorBefore,
                    "anchorAfter": interjection.anchor.anchorAfter,
                    "transcriptionStatus": interjection.transcriptionStatus,
                    "transcript": interjection.cleanedTranscript ?? interjection.transcript ?? "pending"
                ]
            },
            "primaryUserIntent": currentFollowUp.map { followUp in
                [
                    "source": DiscussionContext.primaryIntentSource(
                        explicitFollowUp: explicitFollowUp ?? "",
                        currentInterjections: primaryInterjections
                    ),
                    "request": followUp,
                    "targetType": currentTargetType,
                    "target": targetContext(
                        itemTitle: itemTitle, overview: overview, turns: turns,
                        currentTargetType: currentTargetType, currentTargetId: currentTargetId
                    ),
                    "interjections": primaryInterjections.map { interjection in
                        [
                            "targetType": interjection.targetType.rawValue,
                            "anchorBefore": interjection.anchor.anchorBefore,
                            "anchorAfter": interjection.anchor.anchorAfter,
                            "transcriptionStatus": interjection.transcriptionStatus,
                            "transcript": interjection.cleanedTranscript ?? interjection.transcript ?? "pending"
                        ]
                    }
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
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    public static func targetContext(
        itemTitle: String, overview: String, turns: [ConversationTurn],
        currentTargetType: String, currentTargetId: String?
    ) -> [String: Any] {
        let targetType = currentTargetType
        let targetId = currentTargetId ?? ""
        switch targetType {
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            if let turn = turns.first(where: { $0.id == targetId }) {
                return [
                    "targetType": targetType,
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
}
