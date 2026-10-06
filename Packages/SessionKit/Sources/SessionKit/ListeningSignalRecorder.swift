import Foundation

/// Appends I4 rows (see `ListeningSignal`) to a JSON Lines file (#483).
///
/// Every public call returns at once: rows are buffered and written on a private utility queue,
/// never on the caller's thread. Playback reports listening on every progress tick; the recorder
/// coalesces those ticks into intervals and writes one `listened` row per interval, closed by a
/// pause, a switch to another item, a gap between ticks, or `maximumInterval` of continuous
/// listening (so a crash loses at most that much). A closed interval is written at once, because
/// a pause from the Lock Screen can be followed by suspension before a delayed write runs.
public final class ListeningSignalRecorder: @unchecked Sendable {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "SessionKit.ListeningSignalRecorder", qos: .utility)
    private let now: @Sendable () -> Date
    private let flushDelay: TimeInterval
    private let listeningGap: TimeInterval
    private let maximumInterval: TimeInterval

    // Confined to `queue`.
    private var pending: [ListeningSignal] = []
    private var flushScheduled = false
    private var openInterval: OpenInterval?
    private var exportedPacketIds: Set<String>?
    private var publishedKeys: Set<String>?
    private var lastWriteError: String?

    private struct OpenInterval {
        var source: ListeningSignalSource
        var item: ListeningSignalItem
        var start: Date
        var last: Date
    }

    public init(
        fileURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        flushDelay: TimeInterval = 2,
        listeningGap: TimeInterval = 5,
        maximumInterval: TimeInterval = 300
    ) {
        self.fileURL = fileURL
        self.now = now
        self.flushDelay = flushDelay
        self.listeningGap = listeningGap
        self.maximumInterval = maximumInterval
    }

    public static func defaultFileURL(applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("SpokenMargins", isDirectory: true)
            .appendingPathComponent("ListeningSignals", isDirectory: true)
            .appendingPathComponent("i4-engagement.jsonl")
    }

    public func record(_ event: ListeningSignalEvent, source: ListeningSignalSource, item: ListeningSignalItem?, at: Date? = nil) {
        let time = at ?? now()
        queue.async {
            if case .export(let packetId?, _) = event {
                self.exportedPacketIds?.insert(packetId)
            }
            // A re-followed feed lists entries the log already published (unfollowing deletes
            // its unimported entries, not the log); each entry is published once.
            if event == .itemPublished, !self.insertPublishedKey(source: source, item: item) { return }
            self.append(ListeningSignal(event: event, at: time, source: source, item: item))
        }
    }

    /// Records an import; `from_other` is false when this device's own log shows it exported the packet.
    public func recordPacketImport(packetId: String, marginCount: Int, source: ListeningSignalSource, item: ListeningSignalItem?, at: Date? = nil) {
        let time = at ?? now()
        queue.async {
            let fromOther = !self.loadExportedPacketIds().contains(packetId)
            self.append(ListeningSignal(
                event: .packetImport(packetId: packetId, fromOther: fromOther, marginCount: marginCount),
                at: time, source: source, item: item
            ))
        }
    }

    /// One playback progress tick while `item` plays.
    public func noteListening(source: ListeningSignalSource, item: ListeningSignalItem, at: Date? = nil) {
        let time = at ?? now()
        queue.async { self.extendInterval(source: source, item: item, at: time) }
    }

    /// Playback stopped: close the open interval at its last tick.
    public func endListening() {
        queue.async { self.closeOpenInterval() }
    }

    /// Writes everything buffered, including the open listening interval, and waits for it.
    public func flush() {
        queue.sync {
            closeOpenInterval()
            writePending()
        }
    }

    /// Flushes, then copies the log to `directory` for the share sheet. Nil when nothing is logged yet.
    public func exportCopy(to directory: URL, named name: String = "Spoken Margins listening signals.jsonl") throws -> URL? {
        try queue.sync {
            closeOpenInterval()
            writePending()
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: fileURL, to: destination)
            return destination
        }
    }

    /// The rows written so far, after a flush. Unreadable lines are skipped.
    public func signals() -> [ListeningSignal] {
        flush()
        return Self.read(fileURL)
    }

    public var writeError: String? {
        queue.sync { lastWriteError }
    }

    public static func read(_ url: URL) -> [ListeningSignal] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(ListeningSignal.self, from: Data($0))
        }
    }

    private func extendInterval(source: ListeningSignalSource, item: ListeningSignalItem, at time: Date) {
        if var open = openInterval {
            let sameItem = open.item.id == item.id && open.source.id == source.id
            let gap = time.timeIntervalSince(open.last)
            if sameItem, gap >= 0, gap <= listeningGap {
                open.last = time
                openInterval = open
                if time.timeIntervalSince(open.start) >= maximumInterval {
                    closeOpenInterval()
                    openInterval = OpenInterval(source: source, item: item, start: time, last: time)
                }
                return
            }
            closeOpenInterval()
        }
        openInterval = OpenInterval(source: source, item: item, start: time, last: time)
    }

    private func closeOpenInterval() {
        guard let open = openInterval else { return }
        openInterval = nil
        let seconds = (open.last.timeIntervalSince(open.start) * 10).rounded() / 10
        guard seconds >= 1 else { return }
        append(ListeningSignal(event: .listened(seconds: seconds), at: open.start, source: open.source, item: open.item))
        writePending()
    }

    private func append(_ signal: ListeningSignal) {
        pending.append(signal)
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + flushDelay) { self.writePending() }
    }

    private func writePending() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            var data = Data()
            for signal in pending {
                data.append(try encoder.encode(signal))
                data.append(UInt8(ascii: "\n"))
            }
            let manager = FileManager.default
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: fileURL.path) {
                guard manager.createFile(atPath: fileURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            pending.removeAll()
            lastWriteError = nil
        } catch {
            // Keep the rows for the next flush; bound the buffer if the disk stays unwritable.
            lastWriteError = String(describing: error)
            if pending.count > 10_000 { pending.removeFirst(pending.count - 10_000) }
        }
    }

    private func insertPublishedKey(source: ListeningSignalSource, item: ListeningSignalItem?) -> Bool {
        if publishedKeys == nil {
            publishedKeys = Set((Self.read(fileURL) + pending).filter { $0.event == .itemPublished }
                .map { Self.publishedKey(source: $0.source, item: $0.item) })
        }
        return publishedKeys!.insert(Self.publishedKey(source: source, item: item)).inserted
    }

    private static func publishedKey(source: ListeningSignalSource, item: ListeningSignalItem?) -> String {
        "\(source.id)\n\(item?.id ?? "")"
    }

    private func loadExportedPacketIds() -> Set<String> {
        if let exportedPacketIds { return exportedPacketIds }
        var ids = Set<String>()
        for signal in Self.read(fileURL) + pending {
            if case .export(let packetId?, _) = signal.event { ids.insert(packetId) }
        }
        exportedPacketIds = ids
        return ids
    }
}
