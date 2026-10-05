import Foundation

/// The title a conversation turn is shown under: in the session timeline, on the playback screen and
/// in Markdown export (#826). Display text only; the stored `turnType` values stay as Build 29 wrote
/// them, so a Notes summary is still `interjection_summary` in the database and in packets.
public enum ConversationTurnTitle {
    public static let marginSummary = "Margin Summary"

    /// "Margin Summary 2", "AI Response 3", "Follow-up". The number is the turn's sequence in its id.
    public static func numbered(_ turn: ConversationTurn) -> String {
        let number = sequenceNumber(turn.id)
        switch turn.turnType {
        case "interjection_summary":
            return "\(marginSummary) \(number ?? 1)"
        case "assistant_response":
            return number.map { "AI Response \($0)" } ?? "AI Response"
        default:
            return plain(turnType: turn.turnType)
        }
    }

    /// The title without a number, as Markdown export heads a turn.
    public static func plain(turnType: String) -> String {
        switch turnType {
        case "interjection_summary":
            return marginSummary
        case "assistant_response":
            return "AI Response"
        case "user_response":
            return "Follow-up"
        default:
            return turnType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The number at the end of a turn id such as "turn-002".
    public static func sequenceNumber(_ id: String) -> Int? {
        guard let raw = id.split(separator: "-").last else { return nil }
        return Int(raw)
    }
}
