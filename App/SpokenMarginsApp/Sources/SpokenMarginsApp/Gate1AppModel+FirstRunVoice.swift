import Foundation
import SessionKit

/// A new listener starts on Phonon and hears the app's backup voice until it has downloaded (#2858). The rules are
/// `FirstRunVoiceDefault` in SessionKit and the download is `FirstRunVoiceDownloader`; this is only the model's side.
extension Gate1AppModel {
    /// The voice for the one-time settings migration. A fresh install gets Phonon, and its download is owed (set here,
    /// kept until Phonon is installed or the listener picks another voice). A saved voice, or a phone below Phonon's
    /// floor or without a Phonon player in this build, gets James as before.
    func chooseFirstRunVoice(defaults: UserDefaults) -> ReadingVoiceChoice {
        let choice = FirstRunVoiceDefault.migrationChoice(
            hadSavedSelection: defaults.string(forKey: "ttsVoiceSelection") != nil,
            phononFitsDevice: phononFitsThisDevice())
        if choice == .phonon { defaults.set(true, forKey: FirstRunVoiceDefault.downloadDueKey) }
        return choice
    }

    func phononFitsThisDevice() -> Bool {
        guard VoiceDownloadsModel.playableVoiceIds.contains(ReadingVoiceChoice.phononVoiceId),
              let entry = BundledVoiceCatalog.entry(voiceId: ReadingVoiceChoice.phononVoiceId) else { return false }
        return VoiceDeviceFit.canRender(
            entry,
            deviceGeneration: VoiceDeviceProbe.chipGeneration(),
            physicalMemoryMegabytes: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576))
    }

    /// Starts Phonon's download when it is owed, the Terms are accepted and the phone is on Wi-Fi. Cheap when it isn't
    /// owed (one defaults read), which is every launch after the first minute.
    func startFirstRunVoiceDownloadIfDue() {
        guard UserDefaults.standard.bool(forKey: FirstRunVoiceDefault.downloadDueKey),
              !UITestingHooks.isActive, !Self.isRunningUnitTests else { return }
        let downloader = firstRunVoiceDownloader ?? FirstRunVoiceDownloader(
            voices: requireVoiceDownloads(),
            connectivity: connectivity,
            context: { [weak self] in
                guard let self else { return (false, .system) }
                return (self.hasAcceptedCurrentTerms, (self.pendingTermsVoiceSelection ?? self.ttsVoiceSelection).choice)
            })
        firstRunVoiceDownloader = downloader
        Task { await downloader.evaluate() }
    }

    /// What the Terms confirmation says. A listener who just accepted with Phonon chosen and not on the phone is told
    /// it is coming and who reads until then (#2858).
    func termsAcceptedMessage() -> String {
        let message = "Terms accepted. \(ttsVoiceSelection.displayName) is enabled."
        guard ttsVoiceSelection == .phonon, let support = try? applicationSupportDirectory(),
              VoiceCatalogCoordinator.installedFolder(voiceId: ReadingVoiceChoice.phononVoiceId, supportDirectory: support) == nil,
              let line = FirstRunVoiceDefault.statusLine(
                  choice: .phonon, state: .notInstalled,
                  progress: connectivity.isExpensive || connectivity.isConstrained ? .waitingForWiFi : .downloading(fraction: nil))
        else { return message }
        return "\(message) \(line)"
    }

    /// The plain line under the voice picker while Phonon is chosen and not yet on the phone.
    func phononStatusLine(voices: VoiceDownloadsModel) -> String? {
        let voiceId = ReadingVoiceChoice.phononVoiceId
        let progress: FirstRunVoiceDefault.Progress
        switch voices.activity[voiceId] ?? .idle {
        case .downloading(let bytes, let total):
            progress = .downloading(fraction: total > 0 ? Double(bytes) / Double(total) : nil)
        case .preparing:
            progress = .downloading(fraction: nil)
        case .failed:
            progress = .failed
        case .idle, .removing:
            let isDue = UserDefaults.standard.bool(forKey: FirstRunVoiceDefault.downloadDueKey)
            progress = isDue && (connectivity.isExpensive || connectivity.isConstrained) ? .waitingForWiFi : .notDownloaded
        }
        return FirstRunVoiceDefault.statusLine(
            choice: ttsVoiceSelection.choice, state: voices.rows.first { $0.id == voiceId }?.state, progress: progress)
    }
}
