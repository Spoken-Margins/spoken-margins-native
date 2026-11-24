import Foundation
@testable import SessionKit

/// A spoken note for the export tests (#4782): three recordings, the middle one with no words yet.
///
/// - "take-a-1" (a take id with hyphens): "One." 0–1 s, "Two." 2–3 s, "Three." 3–4 s; 5 s long, joined at 0.
/// - "take-b": no words yet; 2 s long, joined at 5 s.
/// - "take-c": "Four." 0–0.5 s, "Five." 1–2 s; 3 s long, joined at 7 s.
///
/// The note's text is "One. Two. Three. Four. Five.", so the sentences start at characters 0, 5, 10, 17 and 23, and
/// on the joined clock at 0, 2000, 3000, 7000 and 8000 ms.
enum SpokenNoteExportFixtures {
    static let noteId = "n-1"
    static let itemId = SpokenNoteItem.itemId(forNoteId: noteId)
    static let sessionId = "session-note"

    static let takeA = SpokenNoteTake(
        id: "take-a-1", audioFileName: "take-a-1.m4a", durationMs: 5_000, createdAt: Date(timeIntervalSince1970: 10),
        sentences: [
            SpokenNoteSentence(text: "One.", startMs: 0, endMs: 1_000),
            SpokenNoteSentence(text: "Two.", startMs: 2_000, endMs: 3_000),
            SpokenNoteSentence(text: "Three.", startMs: 3_000, endMs: 4_000),
        ]
    )
    static let takeB = SpokenNoteTake(id: "take-b", audioFileName: "take-b.m4a", durationMs: 2_000, createdAt: Date(timeIntervalSince1970: 20))
    static let takeC = SpokenNoteTake(
        id: "take-c", audioFileName: "take-c.m4a", durationMs: 3_000, createdAt: Date(timeIntervalSince1970: 30),
        sentences: [
            SpokenNoteSentence(text: "Four.", startMs: 0, endMs: 500),
            SpokenNoteSentence(text: "Five.", startMs: 1_000, endMs: 2_000),
        ]
    )

    static func note(_ takes: [SpokenNoteTake] = [takeA, takeB, takeC]) -> SpokenNote {
        SpokenNote(id: noteId, takes: takes)
    }

    static func layout(for takes: [SpokenNoteTake] = [takeA, takeB, takeC]) -> SpokenNoteWholeAudioLayout {
        var start = 0
        var placed: [SpokenNoteWholeAudioLayout.Placed] = []
        for take in takes {
            placed.append(.init(takeId: take.id, startMs: start, durationMs: take.durationMs))
            start += take.durationMs
        }
        return SpokenNoteWholeAudioLayout(
            requested: takes.map { .init(id: $0.id, audioFileName: $0.audioFileName, durationMs: $0.durationMs) },
            placed: placed, durationMs: start
        )
    }

    static func whole(_ takes: [SpokenNoteTake] = [takeA, takeB, takeC]) -> SpokenNoteWholeTimeline {
        SpokenNoteWholeTimeline(note: note(takes), layout: layout(for: takes))
    }

    static func input(note: SpokenNote = note(), whole: SpokenNoteWholeTimeline? = whole()) -> SpokenNoteExportInput {
        SpokenNoteExportInput(note: note, wholeTimeline: whole)
    }

    /// The row as `attachPlayback` leaves it after the note was played: native audio, with the joined timeline stored.
    static func item(text: String = note().text) -> Item {
        var item = SpokenNoteItem.makeItem(note: note(), title: "Nov 20 · Thinking", createdAt: Date(timeIntervalSince1970: 5))
        item.text = text
        item.media = ItemMedia(sourceType: .nativeMediaFile, url: "file:///notes/n-1/whole-note.m4a", durationMs: 10_000,
                               nativeMediaId: "spoken-note-audio-\(itemId)")
        item.transcriptId = "transcript-\(itemId)"
        return item
    }

    static func storedTimeline(_ whole: SpokenNoteWholeTimeline = whole()) -> TranscriptTimeline {
        whole.mediaTimeline
    }

    static func segmentId(_ take: SpokenNoteTake, _ index: Int) -> String {
        SpokenNoteMargins.segmentId(takeId: take.id, sentenceIndex: index)
    }

    static func margin(
        _ id: String,
        at createdAt: TimeInterval,
        mediaTimeMs: Int? = nil,
        segmentId: String? = nil,
        startChar: Int = 0,
        written: Bool = false,
        noPlace: Bool = false,
        anchorBefore: String = "",
        anchorAfter: String = "",
        targetType: InterjectionTargetType = .item,
        targetId: String = itemId,
        transcript: String? = nil
    ) -> Interjection {
        var margin = Interjection(
            id: id, itemId: itemId, sessionId: sessionId, targetType: targetType, targetId: targetId,
            createdAt: Date(timeIntervalSince1970: 1_000 + createdAt), roughPercent: noPlace ? 0 : 40,
            anchor: Anchor(anchorType: .media, startChar: startChar, endChar: startChar, anchorBefore: anchorBefore,
                           anchorAfter: anchorAfter, mediaTimeMs: noPlace ? 0 : mediaTimeMs, transcriptSegmentId: segmentId),
            audioPath: written ? nil : "SpokenMargins/interjections/\(id).m4a", audioStatus: written ? "none" : "recorded",
            transcriptionStatus: "transcribed", transcript: transcript ?? "Margin \(id).", cleanedTranscript: nil,
            displayText: nil, status: "active", captureKind: written ? .written : .audio
        )
        if noPlace {
            margin.movedOrigin = MovedMarginOrigin(
                marginId: id, itemId: itemId, sessionId: sessionId, liveMarginId: "live-\(id)", fromLiveSessionId: "live",
                fromLiveSessionTitle: "Walk", sessionPlaceLabel: nil, markedAt: margin.createdAt,
                movedAt: margin.createdAt.addingTimeInterval(60), placeKnown: false)
        }
        return margin
    }
}
