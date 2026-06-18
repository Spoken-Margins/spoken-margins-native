import Foundation

public struct SessionExport: Codable, Equatable {
    public var schemaVersion: String = "session-export.v1"
    public var item: ExportItem
    public var session: ExportSession
    public var listeningMap: ListeningMap?
    public var turns: [ConversationTurn]
    public var timeline: [ExportTimelineEntry]
    public var interjections: [ExportInterjection]
}

public struct ExportItem: Codable, Equatable {
    public var id: String
    public var title: String
    public var externalReference: String?
    public var includedFullText: Bool
    public var text: String?
}

public struct ExportSession: Codable, Equatable {
    public var id: String
    public var status: String
    public var completionPercent: Int
}

public struct ExportTimelineEntry: Codable, Equatable {
    public var type: String
    public var interjectionId: String?
    public var turnId: String?
    public var targetType: String?
    public var targetId: String?
    public var percent: Int?
    public var chapterId: String?
}

public struct ExportInterjection: Codable, Equatable {
    public var id: String
    public var sessionId: String
    public var targetType: String
    public var targetId: String
    public var roughPercent: Int
    public var anchorBefore: String
    public var anchorAfter: String
    public var mediaTimeMs: Int?
    public var transcriptionStatus: String
    public var transcript: String?
    public var audioPath: String?
}

public struct ExportOptions: Equatable {
    public var sessionId: String?
    public var includeFullText: Bool
    public var includeReference: Bool
    public var includeListeningMap: Bool
    public var includeInterjections: Bool
    public var includeTurns: Bool
    public var scope: String
    public var targetType: String?
    public var targetId: String?
    public var interjectionIds: [String]?

    public init(
        sessionId: String? = nil,
        includeFullText: Bool,
        includeReference: Bool,
        includeListeningMap: Bool,
        includeInterjections: Bool,
        includeTurns: Bool = true,
        scope: String = "full_session",
        targetType: String? = nil,
        targetId: String? = nil,
        interjectionIds: [String]? = nil
    ) {
        self.sessionId = sessionId
        self.includeFullText = includeFullText
        self.includeReference = includeReference
        self.includeListeningMap = includeListeningMap
        self.includeInterjections = includeInterjections
        self.includeTurns = includeTurns
        self.scope = scope
        self.targetType = targetType
        self.targetId = targetId
        self.interjectionIds = interjectionIds
    }
}

public enum SessionExportMarkdownRenderer {
    public static func render(_ export: SessionExport) -> String {
        var lines: [String] = []
        lines.append("# Listening Session: \(export.item.title)")
        lines.append("")
        if let reference = export.item.externalReference, !reference.isEmpty {
            lines.append("Item: \(reference)")
            lines.append("")
        }
        if let text = export.item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            lines.append("## Source Text")
            lines.append("")
            lines.append(text)
            lines.append("")
        }
        lines.append("## Session")
        lines.append("")
        lines.append("Status: \(export.session.status)")
        lines.append("Completion: \(export.session.completionPercent)%")
        lines.append("")
        if let overview = export.listeningMap?.overview.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
            lines.append("## Listening Map")
            lines.append("")
            lines.append(overview)
            lines.append("")
        }

        let interjectionsById = Dictionary(uniqueKeysWithValues: export.interjections.map { ($0.id, $0) })
        let turnsById = Dictionary(uniqueKeysWithValues: export.turns.map { ($0.id, $0) })
        lines.append("## Timeline")
        lines.append("")
        for entry in export.timeline {
            switch entry.type {
            case "interjection":
                guard let id = entry.interjectionId, let interjection = interjectionsById[id] else { continue }
                append(interjection: interjection, to: &lines)
            case "ai_turn":
                guard let turnId = entry.turnId, let turn = turnsById[turnId] else { continue }
                append(turn: turn, to: &lines)
            case "ai_turn_chapter":
                guard let turnId = entry.turnId,
                      let turn = turnsById[turnId],
                      let chapterId = entry.chapterId,
                      let chapter = turn.chapters?.first(where: { $0.id == chapterId }) else { continue }
                lines.append("### \(chapter.percent)% - \(chapter.title)")
                lines.append("")
            default:
                continue
            }
        }
        if export.timeline.isEmpty, !export.interjections.isEmpty {
            for interjection in export.interjections {
                append(interjection: interjection, to: &lines)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func append(turn: ConversationTurn, to lines: inout [String]) {
        lines.append("### \(title(for: turn))")
        lines.append("")
        if let summary = turn.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("Summary:")
            lines.append(summary)
            lines.append("")
        }
        if let text = turn.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            lines.append(text)
            lines.append("")
        } else if let rawText = turn.rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !rawText.isEmpty {
            lines.append(rawText)
            lines.append("")
        }
    }

    private static func append(interjection: ExportInterjection, to lines: inout [String]) {
        let percent = interjection.roughPercent
        lines.append("### \(percent)% - Interjection")
        lines.append("")
        if !interjection.anchorBefore.isEmpty {
            lines.append("Anchor before:")
            lines.append(interjection.anchorBefore)
            lines.append("")
        }
        if !interjection.anchorAfter.isEmpty {
            lines.append("Anchor after:")
            lines.append(interjection.anchorAfter)
            lines.append("")
        }
        if let transcript = interjection.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
            lines.append("Transcript:")
            lines.append(transcript)
            lines.append("")
        } else {
            lines.append("Transcript: \(interjection.transcriptionStatus)")
            lines.append("")
        }
        if let audioPath = interjection.audioPath, !audioPath.isEmpty {
            lines.append("Audio:")
            lines.append(audioPath)
            lines.append("")
        }
    }

    private static func title(for turn: ConversationTurn) -> String {
        switch turn.turnType {
        case "interjection_summary":
            return "Interjection Summary"
        case "assistant_response":
            return "AI Response"
        case "user_response":
            return "Follow-up"
        default:
            return turn.turnType.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
