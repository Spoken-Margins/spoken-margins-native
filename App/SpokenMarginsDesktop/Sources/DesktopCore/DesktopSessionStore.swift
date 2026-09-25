import Foundation
import SessionKit
import SessionKitPersistence

/// The small, persistence-focused surface used by the macOS companion UI.
///
/// SessionEngine remains the canonical implementation for exports and can be
/// given the host's audio clients. The desktop data path intentionally writes
/// the local text records directly: creating a text item or editing a saved
/// Margin does not require an audio device or an active playback transport.
public final class DesktopSessionStore {
    public let repository: SQLiteSessionStore
    public let engine: SessionEngine

    private let now: () -> Date

    public init(
        databaseURL: URL,
        profile: RuntimeCapabilityProfile = RuntimeCapabilityProfile(
            id: "desktop",
            displayName: "Spoken Margins Desktop",
            capabilities: ["sync": ["canonical_persistence", "browser_session_handoff"], "ai": ["generate_listening_map"]]
        ),
        audio: AudioPlaybackClient = NoopAudioPlaybackClient(),
        recorder: RecordingClient = NoopRecordingClient(),
        transcriber: TranscriptionClient = DeferredTranscriptionClient(),
        now: @escaping () -> Date = Date.init
    ) throws {
        self.repository = try SQLiteSessionStore(path: databaseURL.path)
        self.engine = SessionEngine(
            profile: profile,
            repository: repository,
            audio: audio,
            recorder: recorder,
            transcriber: transcriber,
            now: now
        )
        self.now = now
    }

    /// Creates or resumes the newest unfinished text session for an item.
    @discardableResult
    public func loadOrCreateTextSession(
        title: String,
        text: String,
        itemID: String? = nil
    ) throws -> DesktopSession {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, !normalizedText.isEmpty else {
            throw SessionKitError.invalidCommandForState("createTextSession")
        }

        let resolvedItemID = itemID ?? "desktop-item-\(UUID().uuidString)"
        let item: Item
        if let existing = try? repository.loadItem(id: resolvedItemID) {
            var updated = existing
            updated.title = normalizedTitle
            updated.text = normalizedText
            updated.mediaType = TargetType.itemTextTTS.rawValue
            updated.media = nil
            updated.status = "ready"
            try repository.saveItem(updated)
            item = updated
        } else {
            let created = Item(
                id: resolvedItemID,
                title: normalizedTitle,
                mediaType: TargetType.itemTextTTS.rawValue,
                text: normalizedText,
                externalReference: nil,
                status: "ready",
                createdAt: now()
            )
            try repository.saveItem(created)
            item = created
        }

        if let existing = try repository.loadSessions(itemId: item.id).first(where: { session in
            session.status != "finished" && session.phase != .finished && session.status != "abandoned"
        }) {
            return try loadSession(id: existing.id)
        }

        let timestamp = now()
        let session = Session(
            id: "desktop-session-\(item.id)-\(UUID().uuidString)",
            itemId: item.id,
            createdAt: timestamp,
            updatedAt: timestamp,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .itemTextTTS,
            currentTargetId: item.id,
            position: Position(charOffset: 0),
            completionPercent: 0,
            playbackRate: 1
        )
        try repository.saveSession(session)
        return try loadSession(id: session.id)
    }

    /// Imports a browser capture through SessionKit's edition-aware importer.
    /// Opening its session never rewrites the imported item or an earlier anchor.
    @discardableResult
    public func importBrowserPage(_ handoff: BrowserTextHandoff) throws -> DesktopSession {
        guard handoff.schemaVersion == "browser-text-handoff.v1",
              handoff.itemId == nil,
              let sourceURL = URL(string: handoff.source.url),
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? ""),
              handoff.text.count <= 100_000 else {
            throw SessionKitError.invalidCommandForState("importBrowserPage")
        }
        let item = try engine.importBrowserTextInBackground(handoff)
        if let existing = try repository.loadSessions(itemId: item.id).first(where: {
            $0.status != "finished" && $0.phase != .finished && $0.status != "abandoned"
        }) {
            return try loadSession(id: existing.id)
        }
        let timestamp = now()
        let session = Session(
            id: "desktop-session-\(item.id)-\(UUID().uuidString)",
            itemId: item.id,
            createdAt: timestamp,
            updatedAt: timestamp,
            status: "in_progress",
            phase: .itemPlayback,
            currentTargetType: .itemTextTTS,
            currentTargetId: item.id,
            position: Position(charOffset: 0),
            completionPercent: 0,
            playbackRate: 1
        )
        try repository.saveSession(session)
        return try loadSession(id: session.id)
    }

    /// Returns the most recently updated session whose item is still present.
    public func recoverLatestSession() throws -> DesktopSession? {
        for session in try repository.loadSessions() {
            if (try? repository.loadItem(id: session.itemId)) != nil {
                return try loadSession(id: session.id)
            }
        }
        return nil
    }

    public func recentSessions(limit: Int = 10) throws -> [DesktopSession] {
        let count = max(0, min(limit, 50))
        return try repository.loadSessions().prefix(count).compactMap { session in
            guard (try? repository.loadItem(id: session.itemId)) != nil else { return nil }
            return try loadSession(id: session.id)
        }
    }

    public func loadSession(id: String) throws -> DesktopSession {
        guard let session = try repository.loadSession(id: id) else {
            throw SessionKitError.invalidCommandForState("loadSession")
        }
        let item = try repository.loadItem(id: session.itemId)
        // This is the same deterministic local text map used by the iOS app.
        // It creates chapters without contacting or invoking an AI model.
        if try repository.loadListeningMap(itemId: item.id) == nil {
            _ = try engine.generateListeningMap(itemId: item.id)
        }
        let listeningMap = try repository.loadListeningMap(itemId: item.id)
        let margins = try repository.loadInterjections(sessionId: session.id)
            .filter { $0.status != "deleted" }
            .sorted { $0.createdAt < $1.createdAt }
        let transcript = try repository.loadTranscriptTimeline(itemId: item.id)?.timeline
        return DesktopSession(item: item, session: session, margins: margins, transcript: transcript,
                              listeningMap: listeningMap)
    }

    /// Saves the text cursor and keeps the durable session status intact.
    @discardableResult
    public func storePlaybackOffset(
        sessionID: String,
        charOffset: Int,
        mediaTimeMs: Int? = nil
    ) throws -> DesktopSession {
        guard var session = try repository.loadSession(id: sessionID) else {
            throw SessionKitError.invalidCommandForState("storePlaybackOffset")
        }
        let item = try repository.loadItem(id: session.itemId)
        let limit = item.text?.count ?? Int.max
        session.position.charOffset = max(0, min(charOffset, limit))
        if let mediaTimeMs {
            session.position.mediaTimeMs = max(0, mediaTimeMs)
        }
        session.completionPercent = completionPercent(offset: session.position.charOffset, text: item.text)
        session.updatedAt = now()
        try repository.saveSession(session)
        return try loadSession(id: session.id)
    }

    /// Builds a bounded, Unicode-safe text anchor from the current source.
    /// `charOffset` follows Swift's `String.count`/`Character` indexing used by
    /// SessionKit, so emoji and composed characters remain one source unit.
    public func sourceAnchor(
        sessionID: String,
        charOffset: Int,
        contextRadius: Int = 80
    ) throws -> Anchor {
        guard let session = try repository.loadSession(id: sessionID) else {
            throw SessionKitError.invalidCommandForState("sourceAnchor")
        }
        let item = try repository.loadItem(id: session.itemId)
        let characters = Array(item.text ?? "")
        let offset = max(0, min(charOffset, characters.count))
        let radius = max(0, contextRadius)
        let beforeStart = max(0, offset - radius)
        let afterEnd = min(characters.count, offset + radius)
        let end = min(characters.count, offset + 1)
        return Anchor(
            anchorType: .text,
            startChar: offset,
            endChar: end,
            anchorBefore: String(characters[beforeStart..<offset]),
            anchorAfter: String(characters[offset..<afterEnd])
        )
    }

    /// Adds a durable item Margin at the source position supplied by the host.
    @discardableResult
    public func addMargin(
        sessionID: String,
        anchor: Anchor,
        transcript: String? = nil,
        captureKind: InterjectionCaptureKind = .written,
        audioPath: String? = nil
    ) throws -> Interjection {
        guard let session = try repository.loadSession(id: sessionID) else {
            throw SessionKitError.invalidCommandForState("addMargin")
        }
        let item = try repository.loadItem(id: session.itemId)
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTranscript = !(text?.isEmpty ?? true)
        let margin = Interjection(
            id: "desktop-margin-\(UUID().uuidString)",
            itemId: item.id,
            sessionId: session.id,
            targetType: .item,
            targetId: item.id,
            createdAt: now(),
            roughPercent: completionPercent(offset: anchor.startChar, text: item.text),
            anchor: anchor,
            audioPath: audioPath,
            audioStatus: audioPath == nil ? "discarded" : "saved",
            transcriptionStatus: hasTranscript ? "transcribed" : "pending",
            transcript: hasTranscript ? text : nil,
            cleanedTranscript: nil,
            displayText: hasTranscript ? text : nil,
            status: "active",
            anchorContextStatus: .ready,
            captureKind: captureKind
        )
        try repository.saveInterjection(margin)
        return margin
    }

    @discardableResult
    public func updateMarginTranscript(
        sessionID: String,
        marginID: String,
        transcript: String
    ) throws -> Interjection {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SessionKitError.invalidCommandForState("updateMarginTranscript")
        }
        guard var margin = try repository.loadInterjections(sessionId: sessionID)
            .first(where: { $0.id == marginID && $0.status != "deleted" }) else {
            throw SessionKitError.invalidCommandForState("updateMarginTranscript")
        }
        margin.transcript = normalized
        margin.cleanedTranscript = nil
        margin.displayText = normalized
        margin.transcriptionStatus = "transcribed"
        try repository.saveInterjection(margin)
        return margin
    }

    public func exportMarkdown(sessionID: String) throws -> String {
        _ = try engine.inspectSession(sessionId: sessionID)
        let export = try engine.buildExport(options: ExportOptions(
            sessionId: sessionID,
            includeFullText: false,
            includeReference: true,
            includeListeningMap: false,
            includeInterjections: true,
            includeTurns: false
        ))
        return SessionExportMarkdownRenderer.render(export)
    }

    private func completionPercent(offset: Int, text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        let bounded = max(0, min(offset, text.count))
        return max(0, min(100, Int((Double(bounded) / Double(text.count) * 100).rounded())))
    }
}

public struct DesktopSession: Codable, Equatable, Sendable {
    public let item: Item
    public let session: Session
    public let margins: [Interjection]
    public let transcript: TranscriptTimeline?
    public let listeningMap: ListeningMap?

    public init(item: Item, session: Session, margins: [Interjection], transcript: TranscriptTimeline?, listeningMap: ListeningMap? = nil) {
        self.item = item
        self.session = session
        self.margins = margins
        self.transcript = transcript
        self.listeningMap = listeningMap
    }

    public var title: String { item.title }
    public var sourceText: String { item.text ?? "" }
    public var currentOffset: Int { session.position.charOffset }
}
