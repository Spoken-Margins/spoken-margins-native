import Foundation
import SessionKit
import SessionKitSpeechFrontEnd

/// What Settings › Voices shows and does (#1819). The rules (catalog, agreement, install, Storage row) are in
/// SessionKit's VoiceCatalogCoordinator; this keeps the screen's state and outlives the screen, so a
/// download keeps its progress when the listener goes elsewhere in the app or leaves it.
@MainActor
final class VoiceDownloadsModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case downloading(bytes: Int64, total: Int64)
        /// Every file is in; the voice's one-time preparation runs (Core ML compile, #2700).
        case preparing
        case removing
        case failed(String)
    }

    /// Voices this build can play once downloaded: Supertonic, plus each downloaded voice whose slice registered a
    /// renderer (`DownloadedVoiceRegistry`, #2700). Pocket TTS is in the catalog but has no player here yet.
    static let playableVoiceIds: Set<String> = Set([SupertonicAssetResolver.catalogVoiceId])
        .union(DownloadedVoiceRegistry.playableVoiceIds)
    /// No signed catalog is fetched yet: downloads come straight from the publishers on Hugging Face, and the
    /// owner's server is never asked (owner, 2026-10-19; #2055 audit 2). The snapshot bundled with the app is the
    /// catalog until the signed one has a home off that server.
    static let catalogURL: URL? = nil
    /// The one-time preparation each runtime needs after download (#2700). ONNX Runtime needs none; the
    /// Kokoro (#2705) and Phonon (#2704) slices register theirs in their own `…VoiceEngine.swift`.
    static let preparers: VoiceModelPreparers = DownloadedVoiceRegistry.preparers(adding: .standard)

    @Published private(set) var rows: [VoiceCatalogRow] = []
    @Published private(set) var activity: [String: Activity] = [:]
    @Published private(set) var source: VoiceCatalogSource = .none

    let coordinator: VoiceCatalogCoordinator
    /// Starts a new listener's Phonon download (#2858); created by `Gate1AppModel.startFirstRunVoiceDownloadIfDue()`.
    var firstRunDownloader: FirstRunVoiceDownloader?
    /// Runs after a voice is installed or removed: Storage and the voice picker read the disk again.
    var onInstalledVoicesChanged: (@MainActor () -> Void)?
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

    init(coordinator: VoiceCatalogCoordinator, defaults: UserDefaults = .standard) {
        self.coordinator = coordinator
        self.defaults = defaults
    }

    private var pending: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.pendingKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.pendingKey) }
    }

    private var automatic: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.automaticKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.automaticKey) }
    }

    /// Continues downloads the listener started that didn't finish. Never starts one they didn't tap.
    func resumePending() async {
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

    static func make(supportDirectory: URL, repository: (any OfflineStorageRepository & Sendable)?) -> VoiceDownloadsModel {
        let snapshot = Bundle.main.url(forResource: "catalog-snapshot", withExtension: "json", subdirectory: "VoiceCatalog")
            .flatMap { try? Data(contentsOf: $0) }
        let coordinator = VoiceCatalogCoordinator(
            supportDirectory: supportDirectory,
            configuration: .init(
                catalogURL: catalogURL,
                playableVoiceIds: playableVoiceIds,
                deviceChipGeneration: VoiceDeviceProbe.chipGeneration(),
                preparers: preparers,
                bundledSnapshot: snapshot
            ),
            transport: BackgroundVoiceModelTransport.shared,
            repository: repository
        )
        let model = VoiceDownloadsModel(coordinator: coordinator)
        BackgroundVoiceModelTransport.shared.onBytesWritten = { [weak model] url, written in
            Task { @MainActor in model?.fileProgress(url: url, written: written) }
        }
        return model
    }

    // MARK: Opening the screen

    /// Shows what's on the device at once, then asks for the signed catalog once per launch.
    func open() async {
        await reload()
        await resumePending()
        guard !refreshedThisLaunch else { return }
        refreshedThisLaunch = true
        _ = await coordinator.refresh()
        await reload()
    }

    func reload() async {
        rows = await coordinator.rows()
        source = await coordinator.catalogSource
    }

    // MARK: Download, cancel, remove

    func agreeAndDownload(_ row: VoiceCatalogRow) {
        Task {
            do {
                try await coordinator.agree(to: row.licensesNeedingAgreement)
            } catch {
                activity[row.id] = .failed("Couldn't save your agreement: \(error.localizedDescription)")
                return
            }
            await reload()
            download(row.id)
        }
    }

    /// `automatic` is for the download the app starts by itself: it waits for Wi-Fi and is restarted that way.
    func download(_ voiceId: String, automatic isAutomatic: Bool = false) {
        guard downloads[voiceId] == nil else { return }
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
                await self?.finish(voiceId, failure: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    /// Stops the download and keeps the files that finished, so Download continues from there.
    func cancel(_ voiceId: String) {
        // The listener said no: a new listener's Phonon is not started again at the next launch (#2858).
        if voiceId == ReadingVoiceChoice.phononVoiceId { defaults.removeObject(forKey: FirstRunVoiceDefault.downloadDueKey) }
        downloads[voiceId]?.cancel()
    }

    func remove(_ voiceId: String) {
        activity[voiceId] = .removing
        Task {
            do {
                try await coordinator.remove(voiceId: voiceId)
                activity[voiceId] = .idle
            } catch {
                activity[voiceId] = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
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

    private func fileProgress(url: URL, written: Int64) {
        guard let voiceId = rows.first(where: { row in row.entry.files.contains { $0.sources.contains(url.absoluteString) } })?.id,
              case .downloading(_, let total) = activity[voiceId] else { return }
        activity[voiceId] = .downloading(bytes: min(total, (progressBase[voiceId] ?? 0) + written), total: total)
    }
}
