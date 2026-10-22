import Foundation

/// Writes a live session's Margins (#2481), already lined up by `LiveSessionAlignment`, onto the Library item
/// made from the listener's recording, each at its own time.
///
/// The item is an ordinary imported audio file, so this gives it a session and writes ordinary written Margins
/// with a second engine (no audio, no recorder), the way `StoredSessionMargin` does for a shortcut: it moves the
/// saved place to each Margin's time, writes the Margin there, and leaves the place at the start. Packets,
/// exports and the player treat the result like any audio item's Margins, and no storage changes.
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
        guard let media = item.media, media.url != nil else { throw Failure.notAudio }
        let written = margins
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.offsetMs < $1.offsetMs }
        let durationMs = media.durationMs
        let startedAt = now()
        var session = Session(
            id: "session-\(itemId)-live-session",
            itemId: itemId,
            createdAt: startedAt,
            updatedAt: startedAt,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .transcriptBackedMedia,
            currentTargetId: media.nativeMediaId ?? media.url ?? itemId,
            position: Position(charOffset: 0, mediaTimeMs: 0),
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
        var saved: [Interjection] = []
        for margin in written {
            let time = durationMs.map { min(max(0, margin.offsetMs), max(0, $0 - 1)) } ?? max(0, margin.offsetMs)
            guard var current = try repository.loadSession(id: session.id) else { break }
            current.position = Position(charOffset: 0, mediaTimeMs: time)
            try repository.saveSession(current)
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
            current.position = Position(charOffset: 0, mediaTimeMs: 0)
            current.completionPercent = 0
            session = current
            try repository.saveSession(session)
        }
        return saved
    }
}
