import Foundation
import SessionKit
#if canImport(MediaPlayer) && os(iOS)
import MediaPlayer
#endif
#if canImport(AVFoundation) && os(iOS)
import AVFoundation
#endif

/// Watches a spoken Margin's recording for the headphone events that could mean "end it", and logs every one
/// (#3650).
///
/// Three kinds of event reach the Diagnostics export while a Margin records, each with the audio route and a
/// timestamp: every system remote command (`headphone.remote_command`: play, pause, togglePlayPause, stop,
/// skipBackward, previousTrack, skipForward, nextTrack), every input mute state change
/// (`headphone.mute_state`, from `AVAudioApplication.inputMuteStateChangeNotification`, which iOS 17 and later post
/// while a record session is active), and every audio route change (`headphone.route_change`). With the microphone
/// open, a Bluetooth headset is in call mode and a press may arrive as a mute change instead of a command. The log
/// is how the owner's phone tells which.
///
/// This type observes. The only thing it can do is the one `HeadphoneMuteGestureDetector` allows: a real mute change,
/// outside the start-up and route-change windows, asks the model to end and save the Margin (owner, 2026-11-07; not
/// tied to the double-press setting, because it only acts on a Margin that is already recording and its words are
/// kept). `AVAudioApplication.setInputMuteStateChangeHandler` is macOS-only, so there is no handler to register on
/// iOS and nothing here changes how iOS answers a press. Every line also carries the recorder's level now, so the
/// log shows whether the recording went silent after a press.
///
/// Local only: port types, never device names. The model owns the one instance and starts and stops it with the
/// capture watch.
@MainActor
final class HeadphoneEndGestureMonitor {
    typealias Log = (_ kind: String, _ fields: [String: String]) -> Void

    private let log: Log
    private let recordingMs: () -> Int
    private let sinceRouteChangeMs: () -> Int?
    private let endMargin: () -> Void
    private let captureLevel: () -> [String: String]
    private let notificationCenter: NotificationCenter
    private let nowMs: () -> Int
    private var detector: HeadphoneMuteGestureDetector?
    private var observers: [NSObjectProtocol] = []
    private var beganAtMs = 0
    private var lastEventAtMs: Int?

    var isWatching: Bool { detector != nil }

    init(
        log: @escaping Log,
        recordingMs: @escaping () -> Int,
        sinceRouteChangeMs: @escaping () -> Int?,
        endMargin: @escaping () -> Void,
        captureLevel: @escaping () -> [String: String] = { [:] },
        notificationCenter: NotificationCenter = .default,
        nowMs: @escaping () -> Int = { Int((ProcessInfo.processInfo.systemUptime * 1_000).rounded()) }
    ) {
        self.log = log
        self.recordingMs = recordingMs
        self.sinceRouteChangeMs = sinceRouteChangeMs
        self.endMargin = endMargin
        self.captureLevel = captureLevel
        self.notificationCenter = notificationCenter
        self.nowMs = nowMs
    }

    /// A Margin has started recording.
    func begin() {
        stop()
        beganAtMs = nowMs()
        lastEventAtMs = nil
        var mutedAtStart = false
        #if canImport(AVFoundation) && os(iOS)
        mutedAtStart = AVAudioApplication.shared.isInputMuted
        observers.append(notificationCenter.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let muted = (note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber)?.boolValue
            MainActor.assumeIsolated { self?.muteStateChanged(muted) }
        })
        observers.append(notificationCenter.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            MainActor.assumeIsolated { self?.routeChanged(reasonRaw: raw) }
        })
        #endif
        detector = HeadphoneMuteGestureDetector(initiallyMuted: mutedAtStart)
        log("headphone.recording_begin", baseFields().merging(["mutedAtStart": String(mutedAtStart)]) { $1 })
    }

    /// The recording ended (saved, cancelled or interrupted).
    func stop() {
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
        guard detector != nil else { return }
        detector = nil
        log("headphone.recording_end", baseFields())
    }

    /// A system remote command arrived from Now Playing, by name. Logged only while a Margin records.
    func noteRemoteCommand(_ name: String) {
        guard isWatching else { return }
        log("headphone.remote_command", baseFields().merging(["command": name]) { $1 })
    }

    private func muteStateChanged(_ muted: Bool?) {
        guard var current = detector else { return }
        guard let muted else {
            log("headphone.mute_state", baseFields().merging(["muted": "unreadable"]) { $1 })
            return
        }
        let verdict = current.observe(muted: muted, recordingMs: recordingMs(), sinceRouteChangeMs: sinceRouteChangeMs())
        detector = current
        log("headphone.mute_state", baseFields().merging(["muted": String(muted), "verdict": Self.describe(verdict)]) { $1 })
        if verdict == .endMargin { endMargin() }
    }

    private func routeChanged(reasonRaw: UInt?) {
        guard isWatching else { return }
        log("headphone.route_change", baseFields().merging(["reason": reasonRaw.map(Self.describeRouteChange) ?? "unknown"]) { $1 })
    }

    /// The fields every line carries: how far into the recording, how long since the line before, and the route.
    private func baseFields() -> [String: String] {
        let now = nowMs()
        let sincePrevious = lastEventAtMs.map { String(max(0, now - $0)) } ?? "first"
        lastEventAtMs = now
        return [
            "recordingMs": String(max(0, now - beganAtMs)),
            "sincePreviousEventMs": sincePrevious,
            "route": Self.routeSummary(),
            "commandsEnabled": Self.commandAvailability(),
            "setting": HeadphoneDoublePressAction(
                storedValue: UserDefaults.standard.string(forKey: HeadphoneDoublePressAction.storageKey)
            ).rawValue,
        ].merging(captureLevel()) { current, _ in current }
    }

    static func describe(_ verdict: HeadphoneMuteGestureDetector.Verdict) -> String {
        switch verdict {
        case .endMargin: return "end_margin"
        case .ignore(let reason): return "ignored:" + reason.rawValue
        }
    }

    /// Whether each system remote command is enabled right now ("next:1" is `nextTrackCommand.isEnabled`). iOS
    /// delivers a headset's double press only to an enabled command, so this tells "never delivered because
    /// disabled" from "delivered and the app ignored it" (#3650).
    static func commandAvailability() -> String {
        #if canImport(MediaPlayer) && os(iOS)
        let center = MPRemoteCommandCenter.shared()
        let pairs: [(String, MPRemoteCommand)] = [
            ("next", center.nextTrackCommand), ("prev", center.previousTrackCommand),
            ("play", center.playCommand), ("pause", center.pauseCommand), ("toggle", center.togglePlayPauseCommand),
            ("skipF", center.skipForwardCommand), ("skipB", center.skipBackwardCommand), ("stop", center.stopCommand),
        ]
        return pairs.map { "\($0.0):\($0.1.isEnabled ? 1 : 0)" }.joined(separator: ",")
        #else
        return "unavailable"
        #endif
    }

    /// What the handler answered iOS for a command that arrived (success, noSuchContent, ...). A `noSuchContent`
    /// for next track would make iOS treat the press as unhandled (#3650).
    func noteRemoteCommandAnswer(_ name: String, answer: String) {
        guard isWatching else { return }
        log("headphone.remote_command_answer", baseFields().merging(["command": name, "answer": answer]) { $1 })
    }

    static func routeSummary() -> String {
        #if canImport(AVFoundation) && os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "in=\(inputs.isEmpty ? "none" : inputs) out=\(outputs.isEmpty ? "none" : outputs)"
        #else
        return "unavailable"
        #endif
    }

    #if canImport(AVFoundation) && os(iOS)
    static func describeRouteChange(_ raw: UInt) -> String {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return "raw\(raw)" }
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "raw\(raw)"
        }
    }
    #else
    static func describeRouteChange(_ raw: UInt) -> String { "raw\(raw)" }
    #endif
}
