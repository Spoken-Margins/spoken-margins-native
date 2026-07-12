import Foundation
import SessionKit

#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

struct Gate2NowPlayingCommandAvailability: Equatable {
    var canPlay: Bool
    var canPause: Bool
    var canTogglePlayPause: Bool
    var canSkipBack: Bool
    var canSkipForward: Bool
    var canStop: Bool
    var canSeek: Bool
    var canSetPlaybackRate: Bool

    init(snapshot: CompactControlSnapshot) {
        let canSendPlay = snapshot.availableCommands.contains(.play) || snapshot.availableCommands.contains(.togglePlayPause)
        let canSendPause = snapshot.availableCommands.contains(.pause) || snapshot.availableCommands.contains(.togglePlayPause)
        canPlay = !snapshot.status.isPlaybackActive && canSendPlay
        canPause = snapshot.status.isPlaybackActive && canSendPause
        canTogglePlayPause = canSendPlay || canSendPause
        canSkipBack = snapshot.availableCommands.contains(.skipBack)
        canSkipForward = snapshot.availableCommands.contains(.skipForward)
        canStop = snapshot.status.isPlaybackActive && canSendPause
        canSeek = snapshot.availableCommands.contains(.seekToMediaTime)
        canSetPlaybackRate = snapshot.availableCommands.contains(.setPlaybackRate)
    }
}

@MainActor
final class Gate2CompactControlController {
    private var dispatcher: CompactControlDispatcher?
    private var queuedCommandHandler: (@MainActor (CompactControlCommand, String, Int?, Double?) -> Void)?
    private let nowPlaying = Gate2NowPlayingController()
    private(set) var lastCommand: CompactControlCommand?
    private(set) var lastCommandOrigin = "none"
    private(set) var lastApplicationCommand = "none"
    private(set) var lastResult = "none"

    var snapshot: CompactControlSnapshot? {
        dispatcher?.snapshot()
    }

    func configure(
        canonicalRuntime: SessionEngine,
        surfaceProfile: RuntimeCapabilityProfile,
        skipUnit: String,
        commandHandler: @escaping @MainActor (CompactControlCommand, String, Int?, Double?) -> Void
    ) {
        dispatcher = CompactControlDispatcher(
            surfaceProfile: surfaceProfile,
            canonicalRuntime: canonicalRuntime,
            defaultSkipUnit: skipUnit
        )
        queuedCommandHandler = commandHandler
        nowPlaying.installRemoteCommandHandlers { [weak self] command, mediaTimeMs, playbackRate in
            self?.queuedCommandHandler?(command, "now_playing", mediaTimeMs, playbackRate)
        }
        publishCurrentSnapshot()
        lastResult = "configured"
    }

    func update(snapshot: SessionSnapshot) {
        guard dispatcher != nil else { return }
        publishCurrentSnapshot()
    }

    @discardableResult
    func dispatch(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) throws -> CompactControlResult {
        guard let dispatcher else {
            throw SessionKitError.invalidCommandForState("compact_control_unconfigured")
        }
        let result = try dispatcher.dispatch(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate)
        lastCommand = command
        lastCommandOrigin = origin
        lastResult = result.delegatedToCanonicalRuntime ? "delegated" : (result.rejectedReason ?? "rejected")
        return result
    }

    func diagnostics() -> [String: String] {
        let snapshot = snapshot
        return [
            "gate2CompactSurface": snapshot?.compactSurfaceReady == true ? "ready" : "not_ready",
            "gate2SurfaceProfile": snapshot?.surfaceProfileId ?? "none",
            "gate2NowPlaying": nowPlaying.isConfigured ? "configured" : "unavailable",
            "gate2LastRemoteCommand": nowPlaying.lastRemoteCommand,
            "gate2LastRemoteCommandDetail": nowPlaying.lastRemoteCommandDetail,
            "gate2LastCommand": lastCommand?.rawValue ?? "none",
            "gate2LastCommandOrigin": lastCommandOrigin,
            "gate2LastApplicationCommand": lastApplicationCommand,
            "gate2LastResult": lastResult,
            "gate2ExposedCommands": snapshot?.exposedCommands.map(\.rawValue).joined(separator: ",") ?? "none",
            "gate2Recording": snapshot?.isRecording == true ? "true" : "false"
        ]
    }

    private func publishCurrentSnapshot() {
        guard let snapshot = dispatcher?.snapshot() else { return }
        nowPlaying.publish(snapshot)
    }
}

@MainActor
private final class Gate2NowPlayingController {
    private(set) var isConfigured = false
    private(set) var lastRemoteCommand = "none"
    private(set) var lastRemoteCommandDetail = "none"

    func publish(_ snapshot: CompactControlSnapshot) {
        #if canImport(MediaPlayer)
        guard snapshot.compactSurfaceReady, snapshot.sessionId != nil else {
            let infoCenter = MPNowPlayingInfoCenter.default()
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
            let center = MPRemoteCommandCenter.shared()
            center.playCommand.isEnabled = false
            center.pauseCommand.isEnabled = false
            center.togglePlayPauseCommand.isEnabled = false
            center.skipBackwardCommand.isEnabled = false
            center.skipForwardCommand.isEnabled = false
            center.changePlaybackPositionCommand.isEnabled = false
            center.changePlaybackRateCommand.isEnabled = false
            return
        }
        if snapshot.status.isPlaybackActive {
            #if canImport(AVFoundation) && os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            #if canImport(UIKit)
            UIApplication.shared.beginReceivingRemoteControlEvents()
            #endif
        }
        let durationSeconds = snapshot.currentPlaybackDurationMs.map { max(0, Double($0) / 1000) }
        let elapsedSeconds = snapshot.currentMediaTimeMs.map { max(0, Double($0) / 1000) }
        let fallbackDuration = 100.0
        let fallbackElapsed = Double(max(0, min(100, snapshot.currentPlaybackProgressPercent)))
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title ?? "Spoken Margins",
            MPMediaItemPropertyAlbumTitle: snapshot.chapterTitle ?? "Session",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds ?? fallbackElapsed,
            MPMediaItemPropertyPlaybackDuration: durationSeconds ?? fallbackDuration,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.status == .playing ? snapshot.playbackRate : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = snapshot.playbackRate
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        if let targetId = snapshot.targetId, let url = URL(string: targetId), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            info[MPNowPlayingInfoPropertyAssetURL] = url
        }
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = info
        switch snapshot.status {
        case .starting, .playing:
            infoCenter.playbackState = .playing
        case .paused, .recording:
            infoCenter.playbackState = .paused
        case .idle, .failed:
            infoCenter.playbackState = .stopped
        }
        let center = MPRemoteCommandCenter.shared()
        let availability = Gate2NowPlayingCommandAvailability(snapshot: snapshot)
        center.playCommand.isEnabled = availability.canPlay
        center.pauseCommand.isEnabled = availability.canPause
        center.togglePlayPauseCommand.isEnabled = availability.canTogglePlayPause
        center.skipBackwardCommand.isEnabled = availability.canSkipBack
        center.previousTrackCommand.isEnabled = availability.canSkipBack
        center.skipForwardCommand.isEnabled = availability.canSkipForward
        center.nextTrackCommand.isEnabled = availability.canSkipForward
        center.stopCommand.isEnabled = availability.canStop
        center.changePlaybackPositionCommand.isEnabled = availability.canSeek
        center.changePlaybackRateCommand.isEnabled = availability.canSetPlaybackRate
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5, 2.0]
        #endif
    }

    func installRemoteCommandHandlers(commandHandler: @escaping @MainActor (CompactControlCommand, Int?, Double?) -> Void) {
        #if canImport(MediaPlayer)
        #if canImport(UIKit)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.changePlaybackRateCommand.removeTarget(nil)

        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.stopCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.changePlaybackRateCommand.isEnabled = false
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1.0, 1.25, 1.5, 2.0]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.preferredIntervals = [15]

        center.playCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "play"
                self?.lastRemoteCommandDetail = "none"
                commandHandler(.play, nil, nil)
            }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "pause"
                self?.lastRemoteCommandDetail = "none"
                commandHandler(.pause, nil, nil)
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "togglePlayPause"
                self?.lastRemoteCommandDetail = "none"
                commandHandler(.togglePlayPause, nil, nil)
            }
            return .success
        }
        center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "skipBack"
                self?.lastRemoteCommandDetail = "15s"
                commandHandler(.skipBack, nil, nil)
            }
            return .success
        }
        center.skipForwardCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "skipForward"
                self?.lastRemoteCommandDetail = "15s"
                commandHandler(.skipForward, nil, nil)
            }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "previousTrack"
                self?.lastRemoteCommandDetail = "previous"
                commandHandler(.skipBack, nil, nil)
            }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "nextTrack"
                self?.lastRemoteCommandDetail = "next"
                commandHandler(.skipForward, nil, nil)
            }
            return .success
        }
        center.stopCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "stop"
                self?.lastRemoteCommandDetail = "none"
                commandHandler(.pause, nil, nil)
            }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let mediaTimeMs = max(0, Int((event.positionTime * 1000).rounded()))
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "changePlaybackPosition"
                self?.lastRemoteCommandDetail = "\(mediaTimeMs)"
                commandHandler(.seekToMediaTime, mediaTimeMs, nil)
            }
            return .success
        }
        center.changePlaybackRateCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            let rate = Double(event.playbackRate)
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "changePlaybackRate"
                self?.lastRemoteCommandDetail = String(format: "%.2f", rate)
                commandHandler(.setPlaybackRate, nil, rate)
            }
            return .success
        }
        isConfigured = true
        #else
        isConfigured = false
        #endif
    }
}
