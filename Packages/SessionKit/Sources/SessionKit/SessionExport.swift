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
    /// Where a source Margin's anchor starts in the item's text. A text item has no media clock, so
    /// this orders its Margins within a percent (#1439).
    public var sourceCharOffset: Int? = nil
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
    /// without Spoken Margins (#491). The notes-folder writer rewrites its own unedited
    /// notes when this body changes, and edited ones never.
    public static func renderMargin(_ export: SessionExport, createdAt: Date) -> String {
        guard let note = export.interjections.first, export.interjections.count == 1 else { return "" }
        let onSource = note.targetType == InterjectionTargetType.item.rawValue
        let created = ISO8601DateFormatter().string(from: createdAt)
        var lines = MarginNoteFrontmatter(export: export, margin: note, created: created).lines
        lines += ["# " + export.item.title, "", "Created: " + created]
        if let reference = export.item.externalReference { lines += ["Source: " + reference] }
        lines += ["Target: \(note.targetType) / \(note.targetId)", "Session: \(note.sessionId)", "Margin: \(note.id)"]
        // A Margin on an AI reply sits in the reply, not in the source (#112).
        let position = note.mediaTimeMs.map(MarginDeepLink.clockPosition(ms:)) ?? "\(note.roughPercent)%"
        lines += [(onSource ? "Position: " : "Position in AI reply: ") + position]
        // The way back to the moment (#171).
        let link = MarginDeepLink(sessionId: note.sessionId, marginId: note.id).url.absoluteString
        lines += ["[Open this Margin in Spoken Margins](\(link))", ""]
        lines += [note.captureKind == .written ? "## Written Margin" : "## Listener Margin", "", marginText(note), ""]
        // Context captured from an item imported before #560 can hold link titles; the
        // stored anchor keeps them, the note shows the text as read.
        let before = SpeechTextNormalizer.removingLinkTitleRemnants(from: note.anchorBefore)
        let after = SpeechTextNormalizer.removingLinkTitleRemnants(from: note.anchorAfter)
        if !before.isEmpty { lines += ["## Context before", "", before, ""] }
        if !after.isEmpty { lines += ["## Context after", "", after, ""] }
        return lines.joined(separator: "\n")
    }

    public static let transcriptNotAvailableYet = "Transcript not available yet."

    /// Whether a Margin gets a note in the notes folder (#171). A spoken Margin always does, so a failed or
    /// unfinished transcription still reaches the folder; its note is rewritten when the transcript arrives.
    /// A written Margin with no words has nothing to say.
    public static func writesMarginNote(captureKind: InterjectionCaptureKind?, text: String?) -> Bool {
        captureKind != .written || !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func marginText(_ note: ExportInterjection) -> String {
        let text = note.transcript ?? ""
        guard note.captureKind != .written, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        return transcriptNotAvailableYet
    }

    /// `includesSessionProgress: false` leaves out the session's status and completion, for a note that must not
    /// change while the listener plays the item again (#587).
    public static func render(_ export: SessionExport, includesSessionProgress: Bool = true) -> String {
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
        if includesSessionProgress {
            lines.append("## Session")
            lines.append("")
            lines.append("Status: \(export.session.status)")
            lines.append("Completion: \(export.session.completionPercent)%")
            lines.append("")
        }
        // A map with chapters but no overview (every podcast scene map) still lists its chapters (#2121).
        if let map = export.listeningMap {
            let overview = map.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !overview.isEmpty || !map.chapters.isEmpty {
                lines.append("## Listening Map")
                lines.append("")
            }
            if !overview.isEmpty {
                lines.append(overview)
                lines.append("")
            }
            for chapter in map.chapters {
                lines.append("- \(chapter.title) (\(chapter.percent)%)")
            }
            if !map.chapters.isEmpty {
                lines.append("")
            }
        }

        let interjectionsById = Dictionary(uniqueKeysWithValues: export.interjections.map { ($0.id, $0) })
        let turnsById = Dictionary(uniqueKeysWithValues: export.turns.map { ($0.id, $0) })
        let contextualSourceInterjections = inSourceOrder(export.timeline.compactMap { entry -> ExportInterjection? in
            guard entry.type == "interjection",
                  let id = entry.interjectionId,
                  let interjection = interjectionsById[id],
                  interjection.targetType == InterjectionTargetType.item.rawValue else {
                return nil
            }
            return interjection
        })
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
            let sourceInterjections = inSourceOrder(
                export.interjections.filter { $0.targetType == InterjectionTargetType.item.rawValue }
            )
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
            targetTitle = ConversationTurnTitle.marginSummary
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

    /// Source Margins as they sit in the source. Audio and video Margins all carry a media time and
    /// go by it. A text item's don't, and a missing time used to count as zero, which put a Margin
    /// from the middle of the text first (#1439); those go by where the anchor starts in the text,
    /// or by percent when an older export has no offset. Margins that tie keep their given order.
    static func inSourceOrder(_ interjections: [ExportInterjection]) -> [ExportInterjection] {
        let timed = interjections.allSatisfy { $0.mediaTimeMs != nil }
        let located = interjections.allSatisfy { $0.sourceCharOffset != nil }
        func key(_ margin: ExportInterjection, _ index: Int) -> [Int] {
            if timed { return [margin.mediaTimeMs ?? 0, margin.sourceCharOffset ?? 0, index] }
            if located { return [margin.sourceCharOffset ?? 0, margin.roughPercent, index] }
            return [margin.roughPercent, margin.sourceCharOffset ?? 0, margin.mediaTimeMs ?? 0, index]
        }
        return interjections.enumerated()
            .sorted { key($0.element, $0.offset).lexicographicallyPrecedes(key($1.element, $1.offset)) }
            .map(\.element)
    }

    private static let minimumSharedTokens = 4
    /// A repeated run shorter than this is taken for the author's own repeat (a refrain, a sponsor
    /// line), not for the same passage twice, and is printed again.
    private static let minimumRepeatedTokens = 8

    /// The source passages printed so far in one block. Margins close together carry context windows
    /// that overlap, so a window is printed only for the words not already above it (#1439).
    private struct PrintedPassages {
        private var printed: [[String]] = []

        /// The part of `passage` not yet printed, or nil when all of it is. `passage` counts as
        /// printed afterwards, because what was cut was printed before.
        mutating func unprinted(_ passage: String) -> String? {
            let ranges = SessionExportMarkdownRenderer.tokenRanges(passage)
            guard !ranges.isEmpty else { return nil }
            let compared = ranges.map { SessionExportMarkdownRenderer.comparisonToken(String(passage[$0])) }
            // The passage is kept as written (line breaks and all) unless some of it is cut.
            var result: String? = passage
            if compared.count >= SessionExportMarkdownRenderer.minimumRepeatedTokens {
                if printed.contains(where: { Self.contains($0, compared) }) {
                    result = nil
                } else {
                    let overlap = printed.map {
                        Self.overlap(ending: $0, starting: compared, atLeast: SessionExportMarkdownRenderer.minimumRepeatedTokens)
                    }.max() ?? 0
                    if overlap > 0 {
                        result = overlap == ranges.count ? nil : String(passage[ranges[overlap].lowerBound...])
                    }
                }
            }
            printed.append(compared)
            return result
        }

        fileprivate static func contains(_ whole: [String], _ part: [String]) -> Bool {
            guard part.count <= whole.count else { return false }
            return (0...(whole.count - part.count)).contains { whole[$0..<($0 + part.count)].elementsEqual(part) }
        }

        /// The most words that end `earlier` and start `later` (at least `minimum`), or 0.
        fileprivate static func overlap(ending earlier: [String], starting later: [String], atLeast minimum: Int) -> Int {
            let most = min(earlier.count, later.count)
            guard most >= minimum else { return 0 }
            for count in stride(from: most, through: minimum, by: -1)
            where earlier.suffix(count).elementsEqual(later.prefix(count)) {
                return count
            }
            return 0
        }
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
        var printed = PrintedPassages()
        func appendPassage(_ label: String, _ passage: String) {
            guard let fresh = printed.unprinted(passage) else { return }
            lines.append(label)
            lines.append(fresh)
            lines.append("")
        }
        lines.append("### \(heading)")
        lines.append("")
        if !first.anchorBefore.isEmpty {
            appendPassage(initialContextLabel, first.anchorBefore)
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
                    appendPassage(continuationLabel, shared)
                }
            } else if !sameMoment {
                if let gap = sourceBetweenOverlappingWindows(previous.anchorAfter, current.anchorAfter) {
                    if !gap.isEmpty {
                        appendPassage(continuationLabel, gap)
                    }
                } else {
                    if !previous.anchorAfter.isEmpty {
                        appendPassage(continuationLabel, previous.anchorAfter)
                    }
                    if !current.anchorBefore.isEmpty {
                        appendPassage(laterContextLabel, current.anchorBefore)
                    }
                }
            }
            appendInterjectionMarker(current, to: &lines)
            previous = current
        }

        if !previous.anchorAfter.isEmpty {
            appendPassage(continuationLabel, previous.anchorAfter)
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
        guard maximum >= minimumSharedTokens else { return nil }
        for count in stride(from: maximum, through: minimumSharedTokens, by: -1) {
            let afterCandidate = afterTokens.prefix(count).map(comparisonToken)
            let beforeCandidate = beforeTokens.suffix(count).map(comparisonToken)
            if afterCandidate == beforeCandidate {
                return afterTokens.prefix(count).joined(separator: " ")
            }
        }
        return nil
    }

    /// For two Margins so close that the passages after them overlap (the later one's passage starts
    /// inside the earlier one's): the source between them, which may be empty. Nil when the passages
    /// don't overlap. The overlap itself is printed once, as the passage after the last Margin.
    private static func sourceBetweenOverlappingWindows(_ earlier: String, _ later: String) -> String? {
        let earlierRanges = tokenRanges(earlier)
        let earlierTokens = earlierRanges.map { comparisonToken(String(earlier[$0])) }
        let laterTokens = tokenRanges(later).map { comparisonToken(String(later[$0])) }
        let overlap = PrintedPassages.overlap(ending: earlierTokens, starting: laterTokens, atLeast: minimumSharedTokens)
        guard overlap > 0 else { return nil }
        let gapTokens = earlierRanges.count - overlap
        guard gapTokens > 0 else { return "" }
        return String(earlier[earlierRanges[0].lowerBound..<earlierRanges[gapTokens - 1].upperBound])
    }

    private static func tokenRanges(_ source: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = source.startIndex
        while index < source.endIndex {
            if source[index].isWhitespace {
                if let begin = start {
                    ranges.append(begin..<index)
                    start = nil
                }
            } else if start == nil {
                start = index
            }
            index = source.index(after: index)
        }
        if let begin = start { ranges.append(begin..<source.endIndex) }
        return ranges
    }

    private static func whitespaceTokens(_ source: String) -> [String] {
        source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func comparisonToken(_ source: String) -> String {
        source.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func title(for turn: ConversationTurn) -> String {
        ConversationTurnTitle.plain(turnType: turn.turnType)
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
