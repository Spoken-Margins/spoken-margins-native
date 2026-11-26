import Foundation

/// The AI Handoff Markdown section for a spoken note in note mode (#4782): the note's words with each Margin as its own
/// paragraph after the sentence it was made on, and the Margins that sit on no sentence listed after the words. It sits
/// where "## Source Text" sits for an article.
enum SpokenNoteMarkdownSection {
    static let heading = "## Spoken Note Transcript"
    static let headingWithMargins = "## Spoken Note Transcript with Margins"
    static let noWordsForNote = "No words written down yet for this note."
    static let noWordsForRecording = "No words written down yet for this recording."
    static let unplacedHeading = "### Margins not placed in the note"
    static let fallbackLine = "Recording details unavailable. These are the words from this note's last playback."
    static let unreadable = "This note's words couldn't be read."

    static func incompleteLine(missing: Int, of total: Int) -> String {
        "Transcript incomplete: \(missing) of \(total) recordings \(missing == 1 ? "has" : "have") no words written down yet. Only the words that exist are below."
    }

    static func append(_ transcript: ExportNoteTranscript, interjections: [ExportInterjection], to lines: inout [String]) {
        let recordings = transcript.recordings ?? []
        // The note's Margins, in the order the export gives them (the order they were made).
        let noteMargins = interjections.filter { $0.targetType == InterjectionTargetType.item.rawValue }
        let segmentIds = Set(recordings.flatMap(\.sentences).compactMap(\.segmentId))
        var marginsBySegment: [String: [ExportInterjection]] = [:]
        var unplaced: [ExportInterjection] = []
        for margin in noteMargins {
            if let id = margin.sourceSegmentId, segmentIds.contains(id) {
                marginsBySegment[id, default: []].append(margin)
            } else {
                unplaced.append(margin)
            }
        }
        let hasWords = recordings.contains { $0.hasWords && !$0.sentences.isEmpty }

        lines.append(marginsBySegment.isEmpty ? heading : headingWithMargins)
        lines.append("")
        if !hasWords {
            lines.append(transcript.isFallback ? unreadable : noWordsForNote)
            lines.append("")
        } else {
            if transcript.isFallback {
                lines.append(fallbackLine)
                lines.append("")
            } else {
                let missing = recordings.filter { !$0.hasWords }.count
                if missing > 0 {
                    lines.append(incompleteLine(missing: missing, of: recordings.count))
                    lines.append("")
                }
            }
            let showsHeadings = !transcript.isFallback && recordings.count > 1
            for recording in recordings {
                if showsHeadings {
                    lines.append("### Recording \(recording.number)")
                    lines.append("")
                }
                guard recording.hasWords, !recording.sentences.isEmpty else {
                    lines.append(noWordsForRecording)
                    lines.append("")
                    continue
                }
                var paragraph: [String] = []
                func flush() {
                    let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    paragraph = []
                    guard !text.isEmpty else { return }
                    lines.append(text)
                    lines.append("")
                }
                for sentence in recording.sentences {
                    paragraph.append(sentence.text)
                    guard let id = sentence.segmentId, let margins = marginsBySegment[id] else { continue }
                    flush()
                    for margin in margins { SessionExportMarkdownRenderer.appendInterjectionMarker(margin, to: &lines) }
                }
                flush()
            }
        }
        if !unplaced.isEmpty {
            lines.append(unplacedHeading)
            lines.append("")
            for margin in unplaced { SessionExportMarkdownRenderer.appendInterjectionMarker(margin, to: &lines) }
        }
    }
}
