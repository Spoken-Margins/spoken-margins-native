import Foundation

public struct SessionExport: Codable, Equatable {
    public var schemaVersion: String = "spoken-margins.export.v1"
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
    public var sourceURL: String?
    public var mediaSourceType: String?
    public var includedFullText: Bool
    public var text: String?
    public var sourceTranscript: String? = nil
    public var author: String? = nil
    /// A paper's DOI or arXiv id, authors and year, when its PDF carried one (#206).
    public var bibliography: PDFBibliography? = nil
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
    /// Nil retains the legacy audio-recording interpretation for exports created
    /// before written Margins were introduced.
    public var captureKind: InterjectionCaptureKind? = nil
    /// The 1-based PDF page the Margin's anchor sits on, when the item's structured
    /// document knows it (#206).
    public var page: Int? = nil
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
    /// Stable single-note export: session progress must not rewrite a vault note
    /// every playback tick. The canonical export already scopes/bounds context.
    /// The YAML properties block lets Obsidian and other Markdown tools search the note
    /// without Spoken Margins (#491); the body below it is unchanged from Build 29, so
    /// the notes-folder writer rewrites its own unedited notes once and edited ones never.
    public static func renderMargin(_ export: SessionExport, createdAt: Date) -> String {
        guard let note = export.interjections.first, export.interjections.count == 1 else { return "" }
        let onSource = note.targetType == InterjectionTargetType.item.rawValue
        let created = ISO8601DateFormatter().string(from: createdAt)
        var lines = MarginNoteFrontmatter(export: export, margin: note, created: created).lines
        lines += ["# " + export.item.title, "", "Created: " + created]
        if let reference = export.item.externalReference { lines += ["Source: " + reference] }
        lines += ["Target: \(note.targetType) / \(note.targetId)", "Session: \(note.sessionId)", "Margin: \(note.id)"]
        // A Margin on an AI reply sits in the reply, not in the source (#112).
        let position = note.mediaTimeMs.map { "\($0) ms" } ?? "\(note.roughPercent)%"
        lines += [(onSource ? "Position: " : "Position in AI reply: ") + position, ""]
        lines += [note.captureKind == .written ? "## Written Margin" : "## Listener Margin", "", note.transcript ?? "", ""]
        // Context captured from an item imported before #560 can hold link titles; the
        // stored anchor keeps them, the note shows the text as read.
        let before = SpeechTextNormalizer.removingLinkTitleRemnants(from: note.anchorBefore)
        let after = SpeechTextNormalizer.removingLinkTitleRemnants(from: note.anchorAfter)
        if !before.isEmpty { lines += ["## Context before", "", before, ""] }
        if !after.isEmpty { lines += ["## Context after", "", after, ""] }
        return lines.joined(separator: "\n")
    }

    public static func render(_ export: SessionExport) -> String {
        var lines: [String] = []
        lines.append("# Spoken Margins AI Handoff: \(export.item.title)")
        lines.append("")
        if let reference = export.item.externalReference, !reference.isEmpty {
            lines.append("Item: \(reference)")
            lines.append("")
        }
        if let sourceURL = export.item.sourceURL, !sourceURL.isEmpty, sourceURL != export.item.externalReference {
            lines.append("Source URL: \(sourceURL)")
            lines.append("")
        }
        if let mediaSourceType = export.item.mediaSourceType, !mediaSourceType.isEmpty {
            lines.append("Source Type: \(mediaSourceType)")
            lines.append("")
        }
        if let text = export.item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            lines.append("## Source Text")
            lines.append("")
            lines.append(text)
            lines.append("")
        }
        if let transcript = export.item.sourceTranscript?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
            lines.append("## Source Transcript")
            lines.append("")
            lines.append(transcript)
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
            for chapter in export.listeningMap?.chapters ?? [] {
                lines.append("- \(chapter.title) (\(chapter.percent)%)")
            }
            if export.listeningMap?.chapters.isEmpty == false {
                lines.append("")
            }
        }

        let interjectionsById = Dictionary(uniqueKeysWithValues: export.interjections.map { ($0.id, $0) })
        let turnsById = Dictionary(uniqueKeysWithValues: export.turns.map { ($0.id, $0) })
        let contextualSourceInterjections = export.timeline.compactMap { entry -> ExportInterjection? in
            guard entry.type == "interjection",
                  let id = entry.interjectionId,
                  let interjection = interjectionsById[id],
                  interjection.targetType == InterjectionTargetType.item.rawValue else {
                return nil
            }
            return interjection
        }
        let contextualTurnInterjections = Dictionary(grouping: export.timeline.compactMap { entry -> ExportInterjection? in
            guard entry.type == "interjection",
                  let id = entry.interjectionId,
                  let interjection = interjectionsById[id],
                  interjection.targetType != InterjectionTargetType.item.rawValue else {
                return nil
            }
            return interjection
        }, by: \.targetId)
        lines.append("## Timeline")
        lines.append("")
        var renderedSourceContext = false
        var renderedTurnContexts: Set<String> = []
        for entry in export.timeline {
            switch entry.type {
            case "interjection":
                guard let id = entry.interjectionId, let interjection = interjectionsById[id] else { continue }
                if interjection.targetType == InterjectionTargetType.item.rawValue {
                    guard !renderedSourceContext else { continue }
                    appendContextualSourceInterjections(contextualSourceInterjections, to: &lines)
                    renderedSourceContext = true
                } else {
                    guard renderedTurnContexts.insert(interjection.targetId).inserted else { continue }
                    let turn = turnsById[interjection.targetId]
                    appendContextualTurnInterjections(
                        contextualTurnInterjections[interjection.targetId] ?? [interjection],
                        turn: turn,
                        to: &lines
                    )
                }
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
            let sourceInterjections = export.interjections
                .filter { $0.targetType == InterjectionTargetType.item.rawValue }
                .sorted { ($0.mediaTimeMs ?? 0) < ($1.mediaTimeMs ?? 0) }
            appendContextualSourceInterjections(sourceInterjections, to: &lines)
            let turnInterjections = Dictionary(
                grouping: export.interjections.filter { $0.targetType != InterjectionTargetType.item.rawValue },
                by: \.targetId
            )
            for targetId in turnInterjections.keys.sorted() {
                appendContextualTurnInterjections(
                    turnInterjections[targetId] ?? [],
                    turn: turnsById[targetId],
                    to: &lines
                )
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func append(turn: ConversationTurn, to lines: inout [String]) {
        lines.append("### \(title(for: turn))")
        lines.append("")
        if turn.status != "complete" {
            lines.append("Status: \(turn.status)")
            lines.append("")
        }
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

    private static func appendContextualSourceInterjections(
        _ interjections: [ExportInterjection],
        to lines: inout [String]
    ) {
        appendContextualInterjections(
            interjections,
            heading: "Source Context and Listener Interjections",
            initialContextLabel: "Source context:",
            continuationLabel: "Source continues:",
            laterContextLabel: "Later source context:",
            to: &lines
        )
    }

    private static func appendContextualTurnInterjections(
        _ interjections: [ExportInterjection],
        turn: ConversationTurn?,
        to lines: inout [String]
    ) {
        guard !interjections.isEmpty else { return }
        let targetTitle: String
        if let turn {
            targetTitle = title(for: turn)
        } else if interjections.first?.targetType == InterjectionTargetType.summaryTurn.rawValue {
            targetTitle = "Interjection Summary"
        } else {
            targetTitle = "AI Response"
        }
        appendContextualInterjections(
            interjections,
            heading: "\(targetTitle) Context and Listener Interjections",
            initialContextLabel: "Turn context:",
            continuationLabel: "Turn continues:",
            laterContextLabel: "Later turn context:",
            to: &lines
        )
    }

    private static func appendContextualInterjections(
        _ interjections: [ExportInterjection],
        heading: String,
        initialContextLabel: String,
        continuationLabel: String,
        laterContextLabel: String,
        to lines: inout [String]
    ) {
        guard let first = interjections.first else { return }
        lines.append("### \(heading)")
        lines.append("")
        if !first.anchorBefore.isEmpty {
            lines.append(initialContextLabel)
            lines.append(first.anchorBefore)
            lines.append("")
        }
        appendInterjectionMarker(first, to: &lines)

        var previous = first
        for current in interjections.dropFirst() {
            // Text-native interjections do not have a media clock. Treating two
            // missing timestamps as zero made every note in a text item look as
            // though it occurred at the same moment, suppressing all context
            // between the first and last notes in Markdown exports.
            let sameMoment = if let currentMediaTimeMs = current.mediaTimeMs,
                                let previousMediaTimeMs = previous.mediaTimeMs {
                abs(currentMediaTimeMs - previousMediaTimeMs) <= 1_000
            } else {
                false
            }
            if !sameMoment,
               let shared = sharedPassage(after: previous.anchorAfter, before: current.anchorBefore) {
                if !shared.isEmpty {
                    lines.append(continuationLabel)
                    lines.append(shared)
                    lines.append("")
                }
            } else if !sameMoment {
                if !previous.anchorAfter.isEmpty {
                    lines.append(continuationLabel)
                    lines.append(previous.anchorAfter)
                    lines.append("")
                }
                if !current.anchorBefore.isEmpty {
                    lines.append(laterContextLabel)
                    lines.append(current.anchorBefore)
                    lines.append("")
                }
            }
            appendInterjectionMarker(current, to: &lines)
            previous = current
        }

        if !previous.anchorAfter.isEmpty {
            lines.append(continuationLabel)
            lines.append(previous.anchorAfter)
            lines.append("")
        }
    }

    private static func appendInterjectionMarker(
        _ interjection: ExportInterjection,
        to lines: inout [String]
    ) {
        let position = interjection.mediaTimeMs.map(formattedMediaTime) ?? "\(interjection.roughPercent)%"
        lines.append("#### \(position) — Listener interjection")
        lines.append("")
        if let transcript = interjection.transcript,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if interjection.captureKind == .written {
                lines.append("Written Margin:")
            }
            lines.append(transcript)
        } else {
            lines.append("Transcript: \(interjection.transcriptionStatus)")
        }
        lines.append("")
    }

    /// For overlapping time windows, the source passage between two interjections is
    /// both a prefix of the earlier note's `after` context and a suffix of the later
    /// note's `before` context. Rendering that shared passage once keeps each listener
    /// note embedded in sequence without repeating minutes of source material.
    private static func sharedPassage(after: String, before: String) -> String? {
        let afterTokens = whitespaceTokens(after)
        let beforeTokens = whitespaceTokens(before)
        let maximum = min(afterTokens.count, beforeTokens.count)
        guard maximum >= 4 else { return nil }
        for count in stride(from: maximum, through: 4, by: -1) {
            let afterCandidate = afterTokens.prefix(count).map(comparisonToken)
            let beforeCandidate = beforeTokens.suffix(count).map(comparisonToken)
            if afterCandidate == beforeCandidate {
                return afterTokens.prefix(count).joined(separator: " ")
            }
        }
        return nil
    }

    private static func whitespaceTokens(_ source: String) -> [String] {
        source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func comparisonToken(_ source: String) -> String {
        source.lowercased().trimmingCharacters(in: .punctuationCharacters)
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

    private static func formattedMediaTime(_ mediaTimeMs: Int) -> String {
        let totalSeconds = max(0, mediaTimeMs / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
