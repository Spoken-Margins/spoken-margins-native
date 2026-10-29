import Foundation
import SessionKit

/// Starts Phonon's download for a listener who was given it as their first voice (#2858). The rules are
/// `FirstRunVoiceDefault.downloadAction`; this reads the app's state for them and acts on the answer. It starts the
/// same download as the Download button in Settings › Voices (`VoiceDownloadsModel.download`), so progress, Cancel and
/// Remove behave as they do there, and a download iOS ended in the background carries on from the files that finished.
@MainActor
final class FirstRunVoiceDownloader {
    private let defaults: UserDefaults
    private weak var voices: VoiceDownloadsModel? // the model owns this downloader
    private let connectivity: ConnectivityMonitor
    /// The Terms state and the voice the listener chose, or the one waiting on the Terms.
    private let context: () -> (termsAccepted: Bool, choice: ReadingVoiceChoice)
    private var observer: UUID?
    private var triedThisLaunch = false

    init(
        defaults: UserDefaults = .standard,
        voices: VoiceDownloadsModel,
        connectivity: ConnectivityMonitor,
        context: @escaping () -> (termsAccepted: Bool, choice: ReadingVoiceChoice)
    ) {
        self.defaults = defaults
        self.voices = voices
        self.connectivity = connectivity
        self.context = context
    }

    var isDue: Bool { defaults.bool(forKey: FirstRunVoiceDefault.downloadDueKey) }

    /// Asks the rules what to do now. Called at launch, when the Terms are accepted, when a voice finishes
    /// installing, and when the network changes while a download waits for Wi-Fi.
    func evaluate() async {
        guard isDue else { return stopWatching() }
        guard let voices else { return }
        let (termsAccepted, choice) = context()
        await voices.reload()
        let row = voices.rows.first { $0.id == ReadingVoiceChoice.phononVoiceId }
        if FirstRunVoiceDefault.isSettled(choice: choice, state: row?.state) {
            defaults.removeObject(forKey: FirstRunVoiceDefault.downloadDueKey)
            return stopWatching()
        }
        connectivity.start()
        // The first path update has not arrived, or there is no network: wait for a change, never act on a guess.
        guard connectivity.hasReported, !connectivity.isOffline else { return watch() }
        let action = FirstRunVoiceDefault.downloadAction(
            isDue: true,
            termsAccepted: termsAccepted,
            choice: choice,
            state: row?.state,
            isOffered: row.map { $0.isOffered && $0.licensesNeedingAgreement.isEmpty } ?? false,
            triedThisLaunch: triedThisLaunch,
            isExpensive: connectivity.isExpensive,
            isConstrained: connectivity.isConstrained)
        switch action {
        case .none:
            stopWatching()
        case .waitForWiFi:
            watch()
        case .start:
            triedThisLaunch = true
            stopWatching()
            voices.download(ReadingVoiceChoice.phononVoiceId)
        }
    }

    private func watch() {
        guard observer == nil else { return }
        observer = connectivity.addObserver { [weak self] _ in
            Task { @MainActor [weak self] in await self?.evaluate() }
        }
    }

    private func stopWatching() {
        guard let observer else { return }
        connectivity.removeObserver(observer)
        self.observer = nil
    }
}
