import Foundation

/// The voice a new listener starts on (#2858). Owner, 2026-10-28: "start new listeners on Phonon." Until Phonon has
/// downloaded, the app's backup voice reads (`OnDeviceVoiceEngines` hands every passage over while the voice's
/// folder is missing), and a plain line says Phonon is on its way.
///
/// Only a fresh install changes. A listener who already has a saved voice keeps it, and so does one whose phone is
/// below Phonon's chip or memory floor, who starts on James as every build before this one did.
public enum FirstRunVoiceDefault {
    /// Set when a fresh install was given Phonon, and cleared when Phonon is installed or the listener picks another
    /// voice. While it is set, the app starts Phonon's download once the Terms are accepted and the phone is on Wi-Fi.
    public static let downloadDueKey = "firstRunVoice.phononDownloadDue"

    /// The voice the one-time pre-1.0 settings migration picks.
    /// - Parameters:
    ///   - hadSavedSelection: a voice was saved by an earlier build, so this is not a fresh install.
    ///   - phononFitsDevice: this phone may run Phonon (`VoiceDeviceFit.canRender` on its catalog entry).
    public static func migrationChoice(hadSavedSelection: Bool, phononFitsDevice: Bool) -> ReadingVoiceChoice {
        hadSavedSelection || !phononFitsDevice ? .james : .phonon
    }

    public enum DownloadAction: Equatable, Sendable {
        /// Nothing to do now: not due, not agreed, already there, already going, or tried this launch.
        case none
        /// Due, but on mobile data or Low Data Mode: wait for Wi-Fi (137 MB is not the listener's to spend unasked).
        case waitForWiFi
        case start
    }

    /// - Parameters:
    ///   - isDue: `downloadDueKey` is set.
    ///   - termsAccepted: the listener accepted the Terms. Phonon's files come from GitHub and Hugging Face, so the
    ///     download waits for the first Play's Terms screen, the moment they agree to an on-device voice.
    ///   - choice: the voice the listener chose, or the one waiting on the Terms.
    ///   - state: Phonon's row in Settings › Voices; nil until the catalog has loaded.
    ///   - isOffered: the row may be downloaded on this phone.
    ///   - triedThisLaunch: a download started, or failed, since the app opened. A failure waits for the next launch
    ///     or the listener's own tap in Voices, so a bad network never loops.
    public static func downloadAction(
        isDue: Bool,
        termsAccepted: Bool,
        choice: ReadingVoiceChoice,
        state: VoiceCatalogRowState?,
        isOffered: Bool,
        triedThisLaunch: Bool,
        isExpensive: Bool,
        isConstrained: Bool
    ) -> DownloadAction {
        guard isDue, termsAccepted, choice == .phonon, isOffered, !triedThisLaunch,
              case .notInstalled? = state else { return .none }
        return isExpensive || isConstrained ? .waitForWiFi : .start
    }

    /// Whether the download is no longer due: Phonon is installed, or the listener chose another voice.
    public static func isSettled(choice: ReadingVoiceChoice, state: VoiceCatalogRowState?) -> Bool {
        if choice != .phonon { return true }
        if case .installed? = state { return true }
        return false
    }

    /// What Settings says under the voice while Phonon is chosen but not installed; nil when nothing needs saying.
    public enum Progress: Equatable, Sendable {
        case downloading(fraction: Double?)
        case waitingForWiFi
        case failed
        case notDownloaded
    }

    public static func statusLine(choice: ReadingVoiceChoice, state: VoiceCatalogRowState?, progress: Progress) -> String? {
        guard choice == .phonon, case .notInstalled? = state else { return nil }
        switch progress {
        case .downloading(let fraction):
            let percent = fraction.map { " (\(Int(max(0, min(1, $0)) * 100))%)" } ?? ""
            return "Phonon is downloading\(percent). Until it finishes, the app’s backup voice reads to you."
        case .waitingForWiFi:
            return "Phonon will download when you’re on Wi‑Fi. Until then, the app’s backup voice reads to you."
        case .failed:
            return "Phonon didn’t finish downloading. The app’s backup voice reads to you. Try again in Settings › Voices."
        case .notDownloaded:
            return "Phonon isn’t downloaded yet. The app’s backup voice reads to you. Get Phonon in Settings › Voices."
        }
    }
}
