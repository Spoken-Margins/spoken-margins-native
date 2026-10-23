import Foundation

/// The one place a live session's disk work runs (#2487, #2256): the stored session's JSON, the Watch Margin inbox
/// and moving received recordings into place. It is an actor, so none of it runs on the main thread and its reads
/// and writes happen one at a time, in a fixed order. The app's screens keep the session in memory and publish what
/// comes back on the main actor. New live-session file work goes here, not on a `@MainActor` type.
public actor LiveSessionFileWorker {
    /// The app's worker, rooted at Application Support (where `Gate1AppModel.liveSessionDirectory` points).
    public static let shared = LiveSessionFileWorker(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    )

    /// A Watch Margin filed into the stored session, waiting for its transcript.
    public struct FiledMargin: Equatable, Sendable {
        public var marginId: String
        public var audioPath: String
    }

    /// Application Support: the stored session is `LiveSession/current.json` under it, and recording paths
    /// ("SpokenMargins/interjections/…") are relative to it.
    public nonisolated let root: URL?
    /// The newest screen save written. A save the screen made earlier that arrives later is dropped, so an older
    /// copy never overwrites a newer one.
    private var writtenGeneration = 0
    /// What this worker filed into the stored session that the screen's copy may not have taken in yet: Watch
    /// Margins and transcripts, by Margin id. A screen save that lacks them puts them back, so a save racing the
    /// screen's reconcile never drops a Margin or its words. Each entry is cleared once a screen save carries it.
    private var unseenMargins: [String: LiveSessionMargin] = [:]
    private var unseenTranscripts: [String: String] = [:]
    private var unseenSessionId: String?

    public init(root: URL?) {
        self.root = root
    }

    public nonisolated var inboxDirectory: URL? {
        root?
            .appending(path: "LiveSession", directoryHint: .isDirectory)
            .appending(path: "WatchInbox", directoryHint: .isDirectory)
    }

    /// The Application Support location of a recorder-style path ("SpokenMargins/interjections/…").
    public nonisolated func recordingURL(for audioPath: String) -> URL? {
        root?.appending(path: audioPath)
    }

    public func load() -> LiveSession? {
        guard let root else { return nil }
        return LiveSessionStore.load(from: root)
    }

    /// Writes the screen's copy of the session. `generation` rises with each screen save or discard; a lower one
    /// than already written is stale and is skipped (returns false).
    @discardableResult
    public func save(_ session: LiveSession, generation: Int) throws -> Bool {
        guard let root, generation > writtenGeneration else { return false }
        writtenGeneration = generation
        try LiveSessionStore.save(keepingUnseen(in: session), in: root)
        return true
    }

    /// Forgets the stored session, unless a newer screen save already replaced it.
    public func remove(generation: Int) {
        guard let root, generation > writtenGeneration else { return }
        writtenGeneration = generation
        forgetUnseen()
        LiveSessionStore.remove(from: root)
    }

    /// Loads the stored session, lets `body` change it, and saves it when `body` returns true. Returns the saved
    /// session, or nil when nothing was stored, nothing changed or the save failed.
    @discardableResult
    public func update(_ body: @Sendable (inout LiveSession) -> Bool) -> LiveSession? {
        guard let root, let before = LiveSessionStore.load(from: root) else { return nil }
        var session = before
        guard body(&session) else { return nil }
        noteUnseen(from: before, to: session)
        do {
            try LiveSessionStore.save(session, in: root)
        } catch {
            return nil
        }
        return session
    }

    /// Files each waiting Watch Margin that belongs to the stored session into it, moving its recording into place.
    /// Returns the Margins newly filed. A Margin with no matching session, or whose recording couldn't be moved,
    /// stays in the inbox for the next pass; a repeat of one already filed is cleared.
    public func fileWatchInbox() -> [FiledMargin] {
        guard let root, let inbox = inboxDirectory, let before = LiveSessionStore.load(from: root) else { return [] }
        var session = before
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        var filed: [FiledMargin] = []
        for metadataURL in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where metadataURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: metadataURL),
                  let transfer = try? JSONDecoder().decode(WatchMarginTransfer.self, from: data) else {
                try? fileManager.removeItem(at: metadataURL)
                continue
            }
            let audioURL = metadataURL.deletingPathExtension().appendingPathExtension("m4a")
            guard LiveSessionWatchMatch.sessionId(for: transfer.wallStart, among: [session.span]) == session.id,
                  let destination = recordingURL(for: transfer.audioPath) else { continue }
            if !session.margins.contains(where: { $0.id == transfer.marginId }) {
                do {
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                    try fileManager.moveItem(at: audioURL, to: destination)
                } catch {
                    continue // the recording stays in the inbox for the next try
                }
                session.attach(transfer)
                filed.append(FiledMargin(marginId: transfer.marginId, audioPath: transfer.audioPath))
            }
            try? fileManager.removeItem(at: audioURL)
            try? fileManager.removeItem(at: metadataURL)
        }
        if !filed.isEmpty {
            noteUnseen(from: before, to: session)
            try? LiveSessionStore.save(session, in: root)
        }
        return filed
    }

    private func noteUnseen(from before: LiveSession, to after: LiveSession) {
        if unseenSessionId != after.id { forgetUnseen() }
        unseenSessionId = after.id
        let old = Dictionary(before.margins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for margin in after.margins {
            if let earlier = old[margin.id] {
                if earlier.text != margin.text, !margin.text.isEmpty { unseenTranscripts[margin.id] = margin.text }
            } else {
                unseenMargins[margin.id] = margin
            }
        }
    }

    private func forgetUnseen() {
        unseenMargins = [:]
        unseenTranscripts = [:]
        unseenSessionId = nil
    }

    /// The screen's copy with anything this worker filed that it hasn't taken in yet.
    private func keepingUnseen(in session: LiveSession) -> LiveSession {
        guard session.id == unseenSessionId else { return session }
        var merged = session
        for (id, margin) in unseenMargins {
            if merged.margins.contains(where: { $0.id == id }) {
                unseenMargins[id] = nil
            } else {
                merged.margins.append(margin)
            }
        }
        for (id, text) in unseenTranscripts {
            guard let index = merged.margins.firstIndex(where: { $0.id == id }) else { continue }
            if merged.margins[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                merged.setTranscript(text, forMarginId: id)
            } else {
                unseenTranscripts[id] = nil // the screen has words for it: its own or these
            }
        }
        merged.margins.sort { $0.markedAt < $1.markedAt }
        return merged
    }

    /// Moves a received file into the inbox, with its metadata beside it. Runs on WatchConnectivity's delegate queue,
    /// before iOS deletes the file when the delegate call returns, so it can't wait for the actor.
    public nonisolated func storeIncoming(fileAt url: URL, transfer: WatchMarginTransfer) throws {
        guard let inbox = inboxDirectory else { return }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stem = URL(fileURLWithPath: transfer.audioPath).deletingPathExtension().lastPathComponent
        let audio = inbox.appending(path: "\(stem).m4a")
        if fileManager.fileExists(atPath: audio.path) { try fileManager.removeItem(at: audio) }
        try fileManager.moveItem(at: url, to: audio)
        try JSONEncoder().encode(transfer).write(to: inbox.appending(path: "\(stem).json"), options: .atomic)
    }
}
