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

    /// Reads the file once, off the main thread. Records added before it finishes are kept, and win over the disk copy
    /// of the same link, because they are newer. Every write waits for this read (``save()``), so a link sent before the
    /// file was read never overwrites the records already on disk.
    public func load() async {
        if let loading { return await loading.value }
        let file = file, now = now()
        let task = Task { @MainActor [weak self] in
            let fromDisk = await Task.detached(priority: .utility) { file.load(now: now) }.value
            guard let self else { return }
            let added = self.records
            self.records = fromDisk.filter { record in !added.contains { $0.id == record.id } } + added
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

    /// The listener's own sent links, or nil until the file is read: a caller that must not mistake their own link for
    /// a friend's waits for it.
    public var knownLinkIDs: Set<String>? { loaded ? linkIDs : nil }

    /// Asks the server about the records that are due (``ShareLinkOpenedPolicy/checksToRun(_:receiptsOn:now:)``),
    /// one request each. The switch is read before every request, so turning it off stops a run already going. A
    /// failure keeps the last known state; the next appearance tries again after ten minutes.
    public func runChecks(defaults: UserDefaults = .standard) async {
        await load()
        guard !checking else { return }
        let due = ShareLinkOpenedPolicy.checksToRun(records, receiptsOn: ShareLinkOpenedPolicy.isOn(defaults), now: now())
        guard !due.isEmpty else { return }
        checking = true
        defer { checking = false }
        let client = client
        for record in due {
            guard ShareLinkOpenedPolicy.isOn(defaults) else { break }
            let answer = await client.isOpened(id: record.id, token: record.token)
            guard let index = records.firstIndex(where: { $0.id == record.id }) else { continue }
            records[index].lastCheckedAt = now()
            if answer == true { records[index].opened = true }
        }
        records.removeAll { !$0.isLive(at: now()) }
        save()
    }

    /// Writes the records in order, off the main thread. Each write first waits for the file to be read, then takes its
    /// snapshot, so the write holds what was on disk plus what changed since. A snapshot taken before the read would
    /// write only the new records over the older ones (#5275 audit on 749d23f).
    private func save() {
        let file = file, previous = saving
        saving = Task { @MainActor [self] in
            await previous?.value
            await self.load()
            let snapshot = self.records
            await Task.detached(priority: .utility) { try? file.save(snapshot) }.value
        }
    }

    /// Waits for writes already started, for tests.
    public func waitForSaves() async {
        await saving?.value
    }
}
#endif
