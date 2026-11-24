#if canImport(Combine)
import Combine
import Foundation

/// The sender's sent links and what the server said about them (#5275, Screen A). The Margins tab reads the
/// lines from it, and asks about due records once each time it appears: foreground only, no polling.
///
/// The file is read and written off the main thread. Until it is read, there is no line, so nothing flashes and
/// nothing reads "Opened" by mistake. A record seen opened is never asked about again.
@MainActor
public final class SentLinkStatus: ObservableObject {
    @Published public private(set) var records: [SentShareLink] = []
    @Published public private(set) var loaded = false

    public var client: ShareLinkOpenedClient
    private let file: SentShareLinkFile
    private let now: @Sendable () -> Date
    private var loading: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var checking = false

    public init(file: SentShareLinkFile, client: ShareLinkOpenedClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.file = file
        self.client = client
        self.now = now
    }

    /// The ids of every live link this app sent, so the app never signals its own link as opened.
    public var linkIDs: Set<String> { Set(records.map(\.id)) }

    /// Reads the file once, off the main thread. Records added before it finishes are kept.
    public func load() async {
        if let loading { return await loading.value }
        let file = file, now = now()
        let task = Task { @MainActor [weak self] in
            let fromDisk = await Task.detached(priority: .utility) { file.load(now: now) }.value
            guard let self else { return }
            let added = self.records.filter { record in !fromDisk.contains { $0.id == record.id } }
            self.records = fromDisk + added
            self.loaded = true
        }
        loading = task
        await task.value
    }

    /// Keeps the record for a link the share sheet reported sent.
    public func add(_ record: SentShareLink) {
        records.removeAll { $0.id == record.id }
        records.append(record)
        save()
    }

    /// The line under `itemID`'s heading, or nil before the file is read or with no live record.
    public func line(forItem itemID: String, receiptsOn: Bool) -> SentLinkLine? {
        guard loaded else { return nil }
        return SentLinkLine.make(records: records.filter { $0.itemID == itemID }, receiptsOn: receiptsOn, now: now())
    }

    /// Asks the server about the records that are due (``ShareLinkOpenedPolicy/checksToRun(_:receiptsOn:now:)``),
    /// one request each. A failure keeps the last known state; the next appearance tries again after ten minutes.
    public func runChecks(receiptsOn: Bool) async {
        await load()
        guard !checking else { return }
        let due = ShareLinkOpenedPolicy.checksToRun(records, receiptsOn: receiptsOn, now: now())
        guard !due.isEmpty else { return }
        checking = true
        defer { checking = false }
        let client = client
        for record in due {
            let answer = await client.isOpened(id: record.id, token: record.token)
            guard let index = records.firstIndex(where: { $0.id == record.id }) else { continue }
            records[index].lastCheckedAt = now()
            if answer == true { records[index].opened = true }
        }
        records.removeAll { !$0.isLive(at: now()) }
        save()
    }

    /// Writes the records in order, off the main thread.
    private func save() {
        let snapshot = records, file = file, previous = saving
        saving = Task {
            await previous?.value
            await Task.detached(priority: .utility) { try? file.save(snapshot) }.value
        }
    }

    /// Waits for writes already started, for tests.
    public func waitForSaves() async {
        await saving?.value
    }
}
#endif
