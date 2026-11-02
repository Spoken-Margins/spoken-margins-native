import Foundation

/// Files a spoken Margin that came from somewhere else (the Watch, #2542) onto the item our own player was playing, at
/// the media time it was taken, as an ordinary spoken Margin of that item's session (`docs/design/live-sessions/DESIGN.md`
/// section 2 point 12).
///
/// A Margin belongs to a session at a place, and the engine builds its anchor from the session's saved place. So this
/// moves the saved place to the Margin's time, writes the Margin through the engine's own spoken path with a recorder
/// that hands back the file already recorded (as `LiveSessionMarginPlacer` does), and then puts the whole session back
/// as it was, resume point and `updatedAt` included. Sessions are ordered by `updatedAt` and the app reopens the newest
/// resumable one, so the episode still resumes exactly where the listener left it. Whatever is wrong, the session is put
/// back before the error is thrown, and the caller files the Margin another way (`LiveSessionFileWorker.fileAsQuick`).
///
/// It only runs on an item whose session keeps a media clock (an episode, an audio file, a narrated article with a
/// transcript). Anything else throws `unsupportedTarget`. It must run where the player's own session writes run (the
/// main actor), so nothing saves the session between the move and the put-back.
public enum PlayerItemMargin {
    public enum Failure: Error, Equatable {
        case itemNotFound
        /// The listener has not started the item, so there is no session to write on.
        case noSession
        /// The session has no media clock, so a media time means nothing on it.
        case unsupportedTarget
        /// A Mark carries no recording; the caller files it another way.
        case noRecording
        case notWritten
    }

    /// Saves a spoken Margin whose recording is `audioPath`, taken at `markedAt`, at `mediaTimeMs` on `itemId`.
    @discardableResult
    public static func placeSpoken(
        audioPath: String?,
        atMediaTimeMs mediaTimeMs: Int,
        markedAt: Date,
        itemId: String,
        repository: SessionRepository & StructuredDocumentRepository
    ) throws -> Interjection {
        guard let audioPath, !audioPath.isEmpty else { throw Failure.noRecording }
        guard let item = try? repository.loadItem(id: itemId), item.deletedAt == nil else { throw Failure.itemNotFound }
        guard let original = StoredSessionMargin.targetSession(in: try repository.loadSessions(itemId: itemId)) else { throw Failure.noSession }
        guard original.currentTargetType == .transcriptBackedMedia || original.currentTargetType == .browserOwnedMedia else {
            throw Failure.unsupportedTarget
        }
        let durationMs = item.media?.durationMs
        let time = durationMs.map { min(max(0, mediaTimeMs), max(0, $0 - 1)) } ?? max(0, mediaTimeMs)

        let recorder = PrerecordedMarginRecorder()
        recorder.audioPath = audioPath
        let engine = SessionEngine(
            profile: RuntimeCapabilityProfile(
                id: "player-item-spoken-margin", displayName: "Player item spoken Margin",
                capabilities: ["interjection": ["record_audio"]]
            ),
            repository: repository,
            recorder: recorder,
            now: { markedAt }
        )
        var result: Result<Interjection, Error>
        do {
            var moved = original
            moved.position.mediaTimeMs = time
            try repository.saveSession(moved)
            try engine.inspectSession(sessionId: original.id)
            let before = Set(try repository.loadInterjections(sessionId: original.id).map(\.id))
            _ = try engine.beginInterjection()
            _ = try engine.finishInterjection(audioRef: audioPath, resumesSource: false)
            guard let saved = try repository.loadInterjections(sessionId: original.id)
                .first(where: { !before.contains($0.id) && $0.audioPath == audioPath }) else { throw Failure.notWritten }
            result = .success(saved)
        } catch {
            result = .failure(error)
        }
        // Put the session back whatever happened: the resume point, the percent, the phase and `updatedAt`.
        do {
            try repository.saveSession(original)
        } catch {
            if case .success = result { result = .failure(error) }
        }
        return try result.get()
    }
}
