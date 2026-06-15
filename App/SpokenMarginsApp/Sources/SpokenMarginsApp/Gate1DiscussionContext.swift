import Foundation
import SessionKit

struct Gate1DiscussionContext {
    static func currentTargetInterjections(
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

    static func primaryRequest(explicitFollowUp: String, currentInterjections: [Interjection]) -> String {
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

    static func primaryIntentSource(explicitFollowUp: String, currentInterjections: [Interjection]) -> String {
        if !explicitFollowUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "typed_follow_up"
        }
        return currentInterjections.isEmpty ? "conversation_continuation" : "target_interjections"
    }
}
