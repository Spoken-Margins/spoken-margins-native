import Foundation
import SessionKit

struct MarginRow: Identifiable, Equatable, Sendable {
    let interjection: Interjection
    let itemTitle: String
    let sessionDate: Date?
    /// The chapter the Margin was made in and, for text, its paragraph number (#777). nil when the item has no
    /// chapters or the position isn't a paragraph.
    var place: MarginPlaces.Place? = nil

    var id: String { "\(interjection.sessionId)::\(interjection.id)" }
    var isWritten: Bool { interjection.captureKind == .written }
    var fullText: String {
        [interjection.displayText, interjection.cleanedTranscript, interjection.transcript]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? preview
    }

    var preview: String {
        for value in [interjection.displayText, interjection.cleanedTranscript, interjection.transcript] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return needsAttention ? attentionDescription : "Audio Margin"
    }

    var needsAttention: Bool {
        if isWritten { return false }
        let transcriptReady = ["transcribed", "complete"].contains(interjection.transcriptionStatus)
        let contextFailed = interjection.anchorContextStatus == .unavailable
        return !transcriptReady || contextFailed || interjection.audioStatus == "missing"
    }

    var canPlayRecording: Bool { !isWritten && interjection.audioPath != nil }
    var canRetryTranscription: Bool { !isWritten && !["transcribed", "complete"].contains(interjection.transcriptionStatus) && interjection.audioPath != nil }

    /// A voice Margin whose transcript can't be made until Speech Recognition is back on (#268).
    var transcriptWaitsForSpeechRecognition: Bool {
        canRetryTranscription && interjection.transcriptionStatus == "failed" && SpeechRecognitionAccess.isOff
    }

    var attentionDescription: String {
        TranscriptionFailureWording.marginAttention(
            transcriptionStatus: interjection.transcriptionStatus,
            speechRecognitionOff: SpeechRecognitionAccess.isOff,
            speechRecognitionNotYetAsked: transcriptWaitsForAnswer,
            contextUnavailable: interjection.anchorContextStatus == .unavailable,
            recordingMissing: interjection.audioStatus == "missing"
        )
    }

    /// #4715: a spoken Margin held until the listener answers the Speech Recognition card. It reads "No transcript yet.".
    var transcriptWaitsForAnswer: Bool { !isWritten && SpeechAskController.marginIsWaitingForAnswer(id) }

    /// The row's second line: where the Margin was made, then the day (#777). Responses and summaries keep their label.
    func placeDescription(now: Date = Date()) -> String {
        guard interjection.targetType == .item else { return "\(targetDescription) · \(interjection.roughPercent)%" }
        return MarginRowWording.placeLine(
            placeName: place?.chapterName, mediaTimeMs: interjection.anchor.mediaTimeMs,
            meetingClockMs: place?.meetingClockMs,
            paragraph: place?.paragraph, roughPercent: interjection.roughPercent,
            hasPlace: interjection.hasPlace, createdAt: interjection.createdAt, now: now)
    }

    /// Set when a call, Siri, the headphones or a closed app ended this recording early, until the listener opens it (#1976).
    var cutShort: CutShortMark? {
        CutShortMargins.shared.mark(sessionId: interjection.sessionId, interjectionId: interjection.id)
    }

    /// The row's headline: what needs attention, else where it was made, led by "Cut short" or "Recovered" while that
    /// mark is on. A recovered Margin always waits on its transcript, so the mark can't be shown only when nothing does.
    func captionDescription(now: Date = Date()) -> String {
        [cutShort?.tag, needsAttention ? attentionDescription : placeDescription(now: now)].compactMap { $0 }.joined(separator: " · ")
    }

    var targetDescription: String {
        switch interjection.targetType {
        case .item: "Source"
        case .assistantTurn: "Assistant response"
        case .summaryTurn: "Margin summary"
        }
    }
}
