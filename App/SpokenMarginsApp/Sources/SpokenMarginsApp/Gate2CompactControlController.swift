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
    private let nowPlaying = Gate2NowPlayingController()
    private let liveActivity = Gate2LiveActivityController()
    private(set) var lastCommand: CompactControlCommand?
    private(set) var lastResult = "none"

    var snapshot: CompactControlSnapshot? {
        dispatcher?.snapshot()
    }

    func configure(
        canonicalRuntime: SessionEngine,
        surfaceProfile: RuntimeCapabilityProfile,
        skipUnit: String,
        commandHandler: @escaping @MainActor (CompactControlCommand) -> Void
    ) {
        dispatcher = CompactControlDispatcher(
            surfaceProfile: surfaceProfile,
            canonicalRuntime: canonicalRuntime,
            defaultSkipUnit: skipUnit
        )
        nowPlaying.installRemoteCommandHandlers(commandHandler: commandHandler)
        publishCurrentSnapshot()
        lastResult = "configured"
    }

    func update(snapshot: SessionSnapshot) {
        guard dispatcher != nil else { return }
        publishCurrentSnapshot()
    }

    @discardableResult
    func dispatch(_ command: CompactControlCommand, chapterId: String? = nil) throws -> CompactControlResult {
        guard let dispatcher else {
            throw SessionKitError.invalidCommandForState("compact_control_unconfigured")
        }
        let result = try dispatcher.dispatch(command, chapterId: chapterId)
        lastCommand = command
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
            "gate2LiveActivity": liveActivity.status,
            "gate2LastCommand": lastCommand?.rawValue ?? "none",
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

    func publish(_ snapshot: CompactControlSnapshot) {
        #if canImport(MediaPlayer)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title ?? "Spoken Margins",
            MPMediaItemPropertyAlbumTitle: snapshot.chapterTitle ?? "Session",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(snapshot.currentPlaybackProgressPercent),
            MPMediaItemPropertyPlaybackDuration: 100,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.status == .playing ? snapshot.playbackRate : 0
        ]
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = snapshot.playbackRate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
            Task { @MainActor in commandHandler(.togglePlayPause) }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in commandHandler(.togglePlayPause) }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in commandHandler(.togglePlayPause) }
            return .success
        }
        center.skipBackwardCommand.addTarget { _ in
            Task { @MainActor in commandHandler(.skipBack) }
            return .success
        }
        center.skipForwardCommand.addTarget { _ in
            Task { @MainActor in commandHandler(.skipForward) }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in commandHandler(.skipBack) }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in commandHandler(.skipForward) }
            return .success
        }
        center.stopCommand.addTarget { _ in
            Task { @MainActor in commandHandler(.togglePlayPause) }
            return .success
        }
        isConfigured = true
        #else
        isConfigured = false
        #endif
    }
}
