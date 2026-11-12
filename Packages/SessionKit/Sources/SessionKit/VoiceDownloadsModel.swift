// Apple platforms only: the screen state is an ObservableObject, and Combine is not in swift-corelibs. It is host-tested
// on the Mac with the rest of SessionKit; Linux builds SessionKit without it.
#if canImport(Combine)
import Combine
import Foundation

/// What Settings › Voices shows and does (#1819). The rules (catalog, agreement, install, Storage row) are in
/// SessionKit's VoiceCatalogCoordinator; this keeps the screen's state and outlives the screen, so a
/// download keeps its progress when the listener goes elsewhere in the app or leaves it.
@MainActor
public final class VoiceDownloadsModel: ObservableObject {
    public enum Activity: Equatable, Sendable {
        case idle
        case downloading(bytes: Int64, total: Int64)
        /// Every file is in; the voice's one-time preparation runs (Core ML compile, #2700).
        case preparing
        case removing
        case failed(String)
    }

    @Published public private(set) var rows: [VoiceCatalogRow] = []
    @Published public private(set) var activity: [String: Activity] = [:]
    @Published public private(set) var source: VoiceCatalogSource = .none

    public let coordinator: VoiceCatalogCoordinator
    /// Keeps the app's first-run download (#2858) alive for as long as the model: `Gate1AppModel.startFirstRunVoiceDownloadIfDue()`
    /// stores its `FirstRunVoiceDownloader` here. It is typed `AnyObject` because that class is app code.
    public var firstRunDownloader: AnyObject?
    /// Runs after a voice is installed or removed: Storage and the voice picker read the disk again.
    public var onInstalledVoicesChanged: (@MainActor () -> Void)?
    private var downloads: [String: Task<Void, Never>] = [:]
    private var progressBase: [String: Int64] = [:]
    private var refreshedThisLaunch = false
    /// Voices the listener started downloading and that haven't finished, cancelled or failed. Kept so a
    /// download iOS ended in the background carries on when the app is woken or Voices is opened again.
    private static let pendingKey = "voiceDownloads.pending"
    /// The pending voices the app started by itself (#2858). They are restarted Wi-Fi only; one the listener
    /// started in Voices is not, so a restart never spends more mobile data than the listener agreed to.
    private static let automaticKey = "voiceDownloads.automatic"
    private let defaults: UserDefaults

    public init(coordinator: VoiceCatalogCoordinator, defaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.defaults = defaults
    }

    private var pending: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.pendingKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.pendingKey) }
    }

    /// The app started this voice's pending download by itself (#2858), so it waits for Wi-Fi.
    public func isAutomatic(_ voiceId: String) -> Bool { automatic.contains(voiceId) }

    private var automatic: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.automaticKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.automaticKey) }
    }

    /// Continues downloads the listener started that didn't finish. Never starts one they didn't tap.
    public func resumePending() async {
        guard !pending.isEmpty else { return }
        await reload()
        for voiceId in pending where downloads[voiceId] == nil {
            guard let row = rows.first(where: { $0.id == voiceId }), row.isOffered, row.state == .notInstalled,
                  row.licensesNeedingAgreement.isEmpty else {
                pending.remove(voiceId)
                continue
            }
            download(voiceId, automatic: automatic.contains(voiceId))
        }
    }

    // MARK: Opening the screen

    /// Shows what's on the device at once, then asks for the signed catalog once per launch.
    public func open() async {
        await reload()
        await resumePending()
        guard !refreshedThisLaunch else { return }
        refreshedThisLaunch = true
        _ = await coordinator.refresh()
        await reload()
    }

    public func reload() async {
        rows = await coordinator.rows()
        source = await coordinator.catalogSource
    }

    // MARK: Download, cancel, remove

    public func agreeAndDownload(_ row: VoiceCatalogRow) {
        Task {
            do {
                try await coordinator.agree(to: row.licensesNeedingAgreement)
            } catch {
                activity[row.id] = .failed(ListenerErrorText.line(prefix: "Couldn't save your agreement:", error: error))
                return
            }
            await reload()
            download(row.id)
        }
    }

    /// `automatic` is for the download the app starts by itself: it waits for Wi-Fi and is restarted that way. It never
    /// takes over a pending download the listener started, which may be using mobile data by their own say-so; that one
    /// resumes as theirs when Voices opens.
    public func download(_ voiceId: String, automatic isAutomatic: Bool = false) {
        guard downloads[voiceId] == nil else { return }
        if isAutomatic, pending.contains(voiceId), !automatic.contains(voiceId) { return }
        if isAutomatic { automatic.insert(voiceId) } else { automatic.remove(voiceId) }
        let total = rows.first { $0.id == voiceId }.map { Int64($0.entry.downloadByteCount) } ?? 0
        activity[voiceId] = .downloading(bytes: 0, total: total)
        progressBase[voiceId] = 0
        pending.insert(voiceId)
        let report: @Sendable (VoiceModelInstallProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.installerProgress(voiceId: voiceId, progress) }
        }
        downloads[voiceId] = Task { [weak self, coordinator] in
            do {
                try await BackgroundVoiceModelTransport.$wifiOnly.withValue(isAutomatic) {
                    try await coordinator.install(voiceId: voiceId, progress: report)
                }
                await self?.finish(voiceId, failure: nil)
            } catch is CancellationError {
                await self?.finish(voiceId, failure: nil)
            } catch {
                await self?.finish(voiceId, failure: ListenerErrorText.message(for: error))
            }
        }
    }

    /// Stops the download and keeps the files that finished, so Download continues from there.
    public func cancel(_ voiceId: String) {
        // The listener said no: a new listener's Phonon is not started again at the next launch (#2858).
        if voiceId == ReadingVoiceChoice.phononVoiceId { defaults.removeObject(forKey: FirstRunVoiceDefault.downloadDueKey) }
        // Stop is the listener's no, now: the task's cancellation lands later, and until `finish` runs the voice would
        // still be pending, so a model made in that gap (a relaunch) would start it again (#2250). `finish` clears
        // the same keys again, which does nothing.
        pending.remove(voiceId)
        automatic.remove(voiceId)
        downloads[voiceId]?.cancel()
    }

    public func remove(_ voiceId: String) {
        activity[voiceId] = .removing
        Task {
            do {
                try await coordinator.remove(voiceId: voiceId)
                activity[voiceId] = .idle
            } catch {
                activity[voiceId] = .failed(ListenerErrorText.message(for: error))
            }
            await reload()
            onInstalledVoicesChanged?()
        }
    }

    private func finish(_ voiceId: String, failure: String?) async {
        downloads[voiceId] = nil
        pending.remove(voiceId)
        automatic.remove(voiceId)
        progressBase[voiceId] = nil
        activity[voiceId] = failure.map(Activity.failed) ?? .idle
        await reload()
        onInstalledVoicesChanged?()
    }

    // MARK: Progress

    /// Whole files the installer has in place. The file in flight is added by `fileProgress`.
    private func installerProgress(voiceId: String, _ progress: VoiceModelInstallProgress) {
        guard case .downloading = activity[voiceId] else { return }
        if progress.phase == .preparing {
            activity[voiceId] = .preparing
            return
        }
        progressBase[voiceId] = progress.bytesDownloaded
        activity[voiceId] = .downloading(bytes: progress.bytesDownloaded, total: progress.totalBytes)
    }

    /// Bytes of the file in flight, from `BackgroundVoiceModelTransport.onBytesWritten`.
    public func fileProgress(url: URL, written: Int64) {
        guard let voiceId = rows.first(where: { row in row.entry.files.contains { $0.sources.contains(url.absoluteString) } })?.id,
              case .downloading(_, let total) = activity[voiceId] else { return }
        activity[voiceId] = .downloading(bytes: min(total, (progressBase[voiceId] ?? 0) + written), total: total)
    }
}
#endif
