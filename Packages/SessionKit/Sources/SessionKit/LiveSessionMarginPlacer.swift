import Foundation

/// Writes a live session's Margins (#2481), already lined up by `LiveSessionAlignment`, onto the Library item
/// made from the listener's recording, each at its own time.
///
/// The item is an ordinary imported audio file, or a text item (a transcript or session notes) whose Margins
/// sit at character offsets. This gives it a session and writes ordinary written Margins
/// with a second engine (no audio, no recorder), the way `StoredSessionMargin` does for a shortcut: it moves the
/// saved place to each Margin's time, writes the Margin there, and leaves the place at the start. Packets,
/// exports and the player treat the result like any audio item's Margins, and no storage changes.
///
/// A spoken Margin (#2487: said on the phone or the Watch during the session) goes through the engine's own spoken
/// path, `beginInterjection` and `finishInterjection`, with a recorder that hands back the file already recorded.
/// It is stored like any spoken Margin, with its transcript when the session already has one; without one it waits
/// for the app's ordinary Margin transcription.
public enum LiveSessionMarginPlacer {
    public enum Failure: Error, Equatable {
        case itemNotFound
        case notAudio
    }

    @discardableResult
    public static func place(
        _ margins: [LiveSessionAlignment.Placed],
        itemId: String,
        repository: SessionRepository & StructuredDocumentRepository,
        now: @escaping () -> Date = Date.init
    ) throws -> [Interjection] {
        guard let item = try? repository.loadItem(id: itemId), item.deletedAt == nil else { throw Failure.itemNotFound }
        let media = item.media?.url == nil ? nil : item.media
        let textLength = item.text?.count ?? 0
        guard media != nil || textLength > 0 else { throw Failure.notAudio }
        let written = margins
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.charOffset ?? 0, $0.offsetMs) < ($1.charOffset ?? 0, $1.offsetMs) }
        let durationMs = media?.durationMs
        let startedAt = now()
        var session = Session(
            id: "session-\(itemId)-live-session",
            itemId: itemId,
            createdAt: startedAt,
            updatedAt: startedAt,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: media == nil ? .itemTextTTS : .transcriptBackedMedia,
            currentTargetId: media.map { $0.nativeMediaId ?? $0.url ?? itemId } ?? itemId,
            position: media == nil ? Position(charOffset: 0) : Position(charOffset: 0, mediaTimeMs: 0),
            completionPercent: 0,
            playbackRate: 1
        )
        try repository.saveSession(session)
        guard !written.isEmpty else { return [] }

        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(id: "live-session-margin", displayName: "Live session Margin", capabilities: [:]),
            repository: repository,
            now: now
        )
        let spokenEngine = written.contains { $0.audioPath != nil } ? PrerecordedMarginRecorder() : nil
        let spoken = spokenEngine.map { recorder in
            SessionEngine(
                profile: RuntimeCapabilityProfile(
                    id: "live-session-spoken-margin", displayName: "Live session spoken Margin",
                    capabilities: ["interjection": ["record_audio"]]
                ),
                repository: repository,
                recorder: recorder,
                now: now
            )
        }
        var saved: [Interjection] = []
        for margin in written {
            let time = durationMs.map { min(max(0, margin.offsetMs), max(0, $0 - 1)) } ?? max(0, margin.offsetMs)
            guard var current = try repository.loadSession(id: session.id) else { break }
            if media == nil {
                current.position = Position(charOffset: min(max(0, margin.charOffset ?? 0), max(0, textLength - 1)))
            } else {
                current.position = Position(charOffset: 0, mediaTimeMs: time)
            }
            try repository.saveSession(current)
            if let audioPath = margin.audioPath, let spoken, let recorder = spokenEngine {
                if let interjection = try placeSpoken(margin, audioPath: audioPath, sessionId: session.id, engine: spoken, recorder: recorder, repository: repository) {
                    saved.append(interjection)
                }
                continue
            }
            try engine.inspectSession(sessionId: session.id)
            let capture = try engine.beginWrittenInterjection()
            do {
                try engine.saveWrittenInterjection(captureId: capture.id, text: margin.text)
            } catch {
                _ = try? engine.cancelWrittenInterjection(captureId: capture.id)
                throw error
            }
            if let interjection = try repository.loadInterjections(sessionId: session.id).first(where: { $0.id == "ij-written-\(capture.id)" }) {
                saved.append(interjection)
            }
        }
        // Leave the saved place at the start, so opening the capture plays it from the beginning.
        if var current = try repository.loadSession(id: session.id) {
            current.position = media == nil ? Position(charOffset: 0) : Position(charOffset: 0, mediaTimeMs: 0)
            current.completionPercent = 0
            session = current
            try repository.saveSession(session)
        }
        return saved
    }

    private static func placeSpoken(
        _ margin: LiveSessionAlignment.Placed,
        audioPath: String,
        sessionId: String,
        engine: SessionEngine,
        recorder: PrerecordedMarginRecorder,
        repository: SessionRepository
    ) throws -> Interjection? {
        recorder.audioPath = audioPath
        try engine.inspectSession(sessionId: sessionId)
        let before = Set(try repository.loadInterjections(sessionId: sessionId).map(\.id))
        _ = try engine.beginInterjection()
        _ = try engine.finishInterjection(audioRef: audioPath, resumesSource: false)
        guard var interjection = try repository.loadInterjections(sessionId: sessionId)
            .first(where: { !before.contains($0.id) && $0.audioPath == audioPath }) else { return nil }
        if let transcript = margin.transcript {
            interjection.transcript = transcript
            interjection.displayText = transcript
            interjection.transcriptionStatus = "transcribed"
            try repository.saveInterjection(interjection)
        }
        return interjection
    }
}

/// The recorder for a spoken Margin that was recorded before it is placed: it records nothing and returns the
/// file it was given.
final class PrerecordedMarginRecorder: RecordingClient, @unchecked Sendable {
    var audioPath: String?

    func beginRecording() throws {
        guard audioPath != nil else { throw SessionKitError.invalidCommandForState("prerecorded_margin_missing") }
    }

    func finishRecording(audioRef: String?) throws -> String {
        guard let path = audioRef ?? audioPath else { throw SessionKitError.invalidCommandForState("prerecorded_margin_missing") }
        return path
    }

    func cancelRecording() throws {}
}
