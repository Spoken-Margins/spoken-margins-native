import Foundation
import SessionKit

#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class Gate2CompactControlController {
    private var dispatcher: CompactControlDispatcher?
    private var queuedCommandTask: Task<Void, Never>?
    private var queuedCommandHandler: (@MainActor (CompactControlCommand, String) -> Void)?
    private var queuedApplicationCommandHandler: (@MainActor (String) -> Bool)?
    private let nowPlaying = Gate2NowPlayingController()
    private let liveActivity = Gate2LiveActivityController()
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
        commandHandler: @escaping @MainActor (CompactControlCommand, String) -> Void,
        applicationCommandHandler: @escaping @MainActor (String) -> Bool = { _ in false }
    ) {
        dispatcher = CompactControlDispatcher(
            surfaceProfile: surfaceProfile,
            canonicalRuntime: canonicalRuntime,
            defaultSkipUnit: skipUnit
        )
        queuedCommandHandler = commandHandler
        queuedApplicationCommandHandler = applicationCommandHandler
        nowPlaying.installRemoteCommandHandlers { command in
            commandHandler(command, "now_playing")
        }
        installQueuedWidgetCommandProcessor()
        publishCurrentSnapshot()
        lastResult = "configured"
    }

    func update(snapshot: SessionSnapshot) {
        guard dispatcher != nil else { return }
        let drainedCommand = drainQueuedWidgetCommands()
        if !drainedCommand {
            publishCurrentSnapshot()
        }
    }

    @discardableResult
    func dispatch(_ command: CompactControlCommand, chapterId: String? = nil, origin: String = "app_ui") throws -> CompactControlResult {
        guard let dispatcher else {
            throw SessionKitError.invalidCommandForState("compact_control_unconfigured")
        }
        let result = try dispatcher.dispatch(command, chapterId: chapterId)
        lastCommand = command
        lastCommandOrigin = origin
        lastResult = result.delegatedToCanonicalRuntime ? "delegated" : (result.rejectedReason ?? "rejected")
        nowPlaying.publish(result.snapshot)
        return result
    }

    func diagnostics() -> [String: String] {
        let snapshot = snapshot
        return [
            "gate2CompactSurface": snapshot?.compactSurfaceReady == true ? "ready" : "not_ready",
            "gate2SurfaceProfile": snapshot?.surfaceProfileId ?? "none",
            "gate2NowPlaying": nowPlaying.isConfigured ? "configured" : "not_configured",
            "gate2LastRemoteCommand": nowPlaying.lastRemoteCommand,
            "gate2LiveActivity": liveActivity.status,
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
        liveActivity.publish(snapshot)
    }

    private func installQueuedWidgetCommandProcessor() {
        queuedCommandTask?.cancel()
        queuedCommandTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.drainQueuedWidgetCommands()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    @discardableResult
    private func drainQueuedWidgetCommands() -> Bool {
        guard let queuedCommandHandler else { return false }
        let queuedCommands = Gate2CompactCommandQueue.drain()
        guard !queuedCommands.isEmpty else { return false }
        for queuedCommand in queuedCommands {
            if let command = CompactControlCommand(rawValue: queuedCommand.command) {
                queuedCommandHandler(command, "widget_or_live_activity_queue")
            } else if queuedApplicationCommandHandler?(queuedCommand.command) == true {
                lastApplicationCommand = queuedCommand.command
            }
        }
        return true
    }
}

@MainActor
private final class Gate2LiveActivityController {
    private var activityId: String?
    private(set) var status = "not_started"

    func publish(_ snapshot: CompactControlSnapshot) {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "disabled"
            return
        }
        guard snapshot.compactSurfaceReady, let sessionId = snapshot.sessionId else {
            status = "not_ready"
            return
        }
        let state = Gate2LiveActivityAttributes.ContentState(
            title: snapshot.title ?? "Spoken Margins",
            chapterTitle: snapshot.chapterTitle ?? "Session",
            status: snapshot.status.rawValue,
            phase: snapshot.phase.rawValue,
            progressPercent: snapshot.currentPlaybackProgressPercent,
            isRecording: snapshot.isRecording
        )
        let currentActivityId = activityId
        Task {
            let result = await Self.publishActivity(sessionId: sessionId, state: state, activityId: currentActivityId)
            activityId = result.activityId
            status = result.status
        }
        #else
        status = "unavailable"
        #endif
    }

    #if canImport(ActivityKit)
    private nonisolated static func publishActivity(
        sessionId: String,
        state: Gate2LiveActivityAttributes.ContentState,
        activityId: String?
    ) async -> (activityId: String?, status: String) {
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity = Activity<Gate2LiveActivityAttributes>.activities.first(where: { $0.id == activityId || $0.attributes.sessionId == sessionId }) {
            await activity.update(content)
            return (activity.id, "updated")
        }
        do {
            let activity = try Activity<Gate2LiveActivityAttributes>.request(
                attributes: Gate2LiveActivityAttributes(sessionId: sessionId),
                content: content,
                pushType: nil
            )
            return (activity.id, "started")
        } catch {
            return (nil, "failed:\(error.localizedDescription)")
        }
    }
    #endif
}

@MainActor
private final class Gate2NowPlayingController {
    private(set) var isConfigured = false
    private(set) var lastRemoteCommand = "none"

    func publish(_ snapshot: CompactControlSnapshot) {
        #if canImport(MediaPlayer)
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        let center = MPRemoteCommandCenter.shared()
        let canPlay = snapshot.availableCommands.contains(.play) || snapshot.availableCommands.contains(.togglePlayPause)
        let canPause = snapshot.availableCommands.contains(.pause) || snapshot.availableCommands.contains(.togglePlayPause)
        let canSkipBack = snapshot.availableCommands.contains(.skipBack)
        let canSkipForward = snapshot.availableCommands.contains(.skipForward)
        center.playCommand.isEnabled = snapshot.status != .playing && canPlay
        center.pauseCommand.isEnabled = snapshot.status == .playing && canPause
        center.togglePlayPauseCommand.isEnabled = canPlay || canPause
        center.skipBackwardCommand.isEnabled = canSkipBack
        center.previousTrackCommand.isEnabled = canSkipBack
        center.skipForwardCommand.isEnabled = canSkipForward
        center.nextTrackCommand.isEnabled = canSkipForward
        center.stopCommand.isEnabled = snapshot.status == .playing && canPause
        #endif
    }

    func installRemoteCommandHandlers(commandHandler: @escaping @MainActor (CompactControlCommand) -> Void) {
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

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.preferredIntervals = [15]

        center.playCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "play"
                commandHandler(.play)
            }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "pause"
                commandHandler(.pause)
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "togglePlayPause"
                commandHandler(.togglePlayPause)
            }
            return .success
        }
        center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "skipBack"
                commandHandler(.skipBack)
            }
            return .success
        }
        center.skipForwardCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "skipForward"
                commandHandler(.skipForward)
            }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "previousTrack"
                commandHandler(.skipBack)
            }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "nextTrack"
                commandHandler(.skipForward)
            }
            return .success
        }
        center.stopCommand.addTarget { _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "stop"
                commandHandler(.pause)
            }
            return .success
        }
        isConfigured = true
        #else
        isConfigured = false
        #endif
    }
}
