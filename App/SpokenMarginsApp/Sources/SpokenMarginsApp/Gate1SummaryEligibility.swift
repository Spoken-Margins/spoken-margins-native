import Foundation
import SessionKit

struct Gate1SummaryEligibility {
    static func unsummarizedInterjections(
        turns: [ConversationTurn],
        interjections: [Interjection],
        currentTargetType: String,
        currentTargetId: String?
    ) -> [Interjection] {
        let summarized = Set(turns
            .filter { $0.turnType == "interjection_summary" && $0.status == "complete" }
            .flatMap(\.sourceInterjectionIds))
        return interjections.filter { interjection in
            guard !summarized.contains(interjection.id) else { return false }
            switch currentTargetType {
            case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
                return interjection.targetId == currentTargetId && interjection.targetType != .item
            default:
                return interjection.targetType == .item
            }
        }
    }
}
