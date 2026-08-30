import Foundation
import SessionKit

#if canImport(ActivityKit)
import ActivityKit
#endif
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
    var canPreviousTrack: Bool
    var canNextTrack: Bool

    init(snapshot: CompactControlSnapshot) {
        let canSendPlay = snapshot.availableCommands.contains(.play) || snapshot.availableCommands.contains(.togglePlayPause)
        let canSendPause = snapshot.availableCommands.contains(.pause) || snapshot.availableCommands.contains(.togglePlayPause)
        // Keep both native transport commands registered for the lifetime of the
        // playback session. The system chooses the visible play/pause state from
        // Now Playing metadata; disabling the currently hidden counterpart can
        // make the entire Lock Screen transport surface disappear on a handoff.
        canPlay = canSendPlay
        canPause = canSendPause
        canTogglePlayPause = canSendPlay || canSendPause
        canSkipBack = snapshot.availableCommands.contains(.skipBack)
        canSkipForward = snapshot.availableCommands.contains(.skipForward)
        canStop = canSendPause
        canSeek = snapshot.availableCommands.contains(.seekToMediaTime)
        canSetPlaybackRate = snapshot.availableCommands.contains(.setPlaybackRate)
        // Native text navigation is interval-based. Advertising track commands
        // lets iOS replace the intended skip controls with previous/next icons
        // and gives the commands semantics that the canonical session does not
        // own.
        canPreviousTrack = false
        canNextTrack = false
    }
}

struct Gate2NowPlayingTimelineMetadata: Equatable {
    var elapsedSeconds: Double?
    var durationSeconds: Double?
    var isLiveStream: Bool

    init(snapshot: CompactControlSnapshot) {
        // Live TTS owns a source-text position, not a complete media-time
        // timeline. Publishing a percentage as elapsed seconds with an invented
        // duration creates a misleading Lock Screen scrubber. Do not label live
        // TTS as an iOS live stream: that presentation can hide transport
        // controls. Prepared text audio uses the native-media target type and
        // reaches the media branch below with an authoritative duration.
        if Gate2LiveSpeechNowPlayingPolicy.isLiveSpeech(snapshot) {
            elapsedSeconds = nil
            durationSeconds = nil
            isLiveStream = false
            return
        }

        guard let durationMs = snapshot.currentPlaybackDurationMs,
              durationMs > 0,
              let mediaTimeMs = snapshot.currentMediaTimeMs else {
            elapsedSeconds = nil
            durationSeconds = nil
            isLiveStream = false
            return
        }
        let duration = Double(durationMs) / 1_000
        elapsedSeconds = min(duration, max(0, Double(mediaTimeMs) / 1_000))
        durationSeconds = duration
        isLiveStream = false
    }
}

enum Gate2LiveActivityPolicy {
    /// Live Activity intents cannot command the in-process player reliably when
    /// the app is suspended. Now Playing remains the authoritative transport
    /// surface; the Live Activity retains only actions that intentionally open or
    /// hand off to the app, chiefly Interject.
    static func availableCommands(from snapshot: CompactControlSnapshot) -> [CompactControlCommand] {
        snapshot.availableCommands.filter {
            switch $0 {
            case .beginInterjection, .finishInterjection:
                return true
            case .play, .pause, .togglePlayPause, .skipBack, .skipForward,
                 .seekToMediaTime, .setPlaybackRate, .jumpToChapter,
                 .cancelInterjection, .generateInterjectionSummary, .submitFollowup:
                return false
            }
        }
    }

    static func nextSourceChapter(from snapshot: CompactControlSnapshot) -> CompactTimelineEntry? {
        let sourceTargetTypes = [
            TargetType.itemTextTTS.rawValue,
            TargetType.transcriptBackedMedia.rawValue,
            TargetType.browserOwnedMedia.rawValue
        ]
        guard let targetType = snapshot.targetType, sourceTargetTypes.contains(targetType) else {
            return nil
        }
        let chapters = snapshot.timeline.filter { $0.kind == "source_chapter" && $0.chapterId != nil }
        guard chapters.count > 1 else { return nil }
        let currentIndex = chapters.firstIndex(where: \.isCurrent)
            ?? snapshot.chapterTitle.flatMap { title in
                chapters.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame })
            }
            ?? chapters.lastIndex(where: { ($0.percent ?? 0) <= snapshot.sourceProgressPercent })
        guard let currentIndex, chapters.indices.contains(currentIndex + 1) else { return nil }
        return chapters[currentIndex + 1]
    }

    static func isEligible(_ snapshot: CompactControlSnapshot) -> Bool {
        guard snapshot.compactSurfaceReady, snapshot.sessionId != nil else { return false }
        switch snapshot.phase {
        case .finished, .abandoned:
            return false
        default:
            return true
        }
    }

    static func shouldEnd(activitySessionId: String, currentSessionId: String?) -> Bool {
        guard let currentSessionId else { return true }
        return activitySessionId != currentSessionId
    }

    static func shouldMaintain(_ snapshot: CompactControlSnapshot, adoptedSessionId: String?) -> Bool {
        guard isEligible(snapshot), let sessionId = snapshot.sessionId else { return false }
        if snapshot.status.isPlaybackActive || snapshot.isRecording {
            return true
        }
        return snapshot.status == .paused && adoptedSessionId == sessionId
    }

    static func shouldEndInactive(
        activitySessionId: String,
        activityId: String,
        inactiveSessionId: String?,
        trackedActivityId: String?
    ) -> Bool {
        if let inactiveSessionId {
            return activitySessionId == inactiveSessionId
        }
        if let trackedActivityId {
            return activityId == trackedActivityId
        }
        return true
    }
}

enum Gate2LiveSpeechNowPlayingPolicy {
    static func isLiveSpeech(_ snapshot: CompactControlSnapshot) -> Bool {
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue,
             TargetType.assistantTurnTTS.rawValue,
             TargetType.summaryTurnTTS.rawValue:
            return true
        default:
            return false
        }
    }

    static func shouldPublish(_ snapshot: CompactControlSnapshot) -> Bool {
        guard isLiveSpeech(snapshot), snapshot.compactSurfaceReady, snapshot.sessionId != nil else {
            return false
        }
        switch snapshot.phase {
        case .finished, .abandoned:
            return false
        default:
            return true
        }
    }
}

enum Gate2NativeMediaNowPlayingPolicy {
    static func shouldPublish(_ snapshot: CompactControlSnapshot) -> Bool {
        guard snapshot.compactSurfaceReady, snapshot.sessionId != nil else { return false }
        guard snapshot.targetType == TargetType.transcriptBackedMedia.rawValue
                || snapshot.targetType == TargetType.browserOwnedMedia.rawValue else {
            return false
        }
        switch snapshot.phase {
        case .finished, .abandoned:
            return false
        default:
            return true
        }
    }
}

@MainActor
protocol Gate2LiveActivityControlling: AnyObject {
    var status: String { get }

    func publish(_ snapshot: CompactControlSnapshot)
    func endAll()
}

@MainActor
final class Gate2CompactControlController {
    private var dispatcher: CompactControlDispatcher?
    private var queuedCommandTask: Task<Void, Never>?
    private var queuedCommandHandler: (@MainActor (CompactControlCommand, String, String?, Int?, Double?) -> Void)?
    private var queuedApplicationCommandHandler: (@MainActor (String) -> Bool)?
    private let liveActivity: any Gate2LiveActivityControlling
    private let liveSpeechNowPlaying = Gate2LiveSpeechNowPlayingController()
    private var lastPublishedSnapshot: CompactControlSnapshot?
    private(set) var lastCommand: CompactControlCommand?
    private(set) var lastCommandOrigin = "none"
    private(set) var lastApplicationCommand = "none"
    private(set) var lastResult = "none"

    init(liveActivity: (any Gate2LiveActivityControlling)? = nil) {
        self.liveActivity = liveActivity ?? Gate2LiveActivityController()
    }

    var snapshot: CompactControlSnapshot? {
        dispatcher?.snapshot()
    }

    func configure(
        canonicalRuntime: SessionEngine,
        surfaceProfile: RuntimeCapabilityProfile,
        skipUnit: String,
        commandHandler: @escaping @MainActor (CompactControlCommand, String, String?, Int?, Double?) -> Void,
        applicationCommandHandler: @escaping @MainActor (String) -> Bool = { _ in false }
    ) {
        dispatcher = CompactControlDispatcher(
            surfaceProfile: surfaceProfile,
            canonicalRuntime: canonicalRuntime,
            defaultSkipUnit: skipUnit
        )
        queuedCommandHandler = commandHandler
        queuedApplicationCommandHandler = applicationCommandHandler
        liveSpeechNowPlaying.commandHandler = { [weak self] command, playbackRate in
            self?.queuedCommandHandler?(command, "now_playing_live_speech", nil, nil, playbackRate)
        }
        installQueuedWidgetCommandProcessor()
        publishCurrentSnapshot(force: true)
        lastResult = "configured"
    }

    func update(snapshot _: SessionSnapshot) {
        guard dispatcher != nil else { return }
        let drainedCommand = drainQueuedWidgetCommands()
        if !drainedCommand {
            publishCurrentSnapshot()
        }
    }

    @discardableResult
    func dispatch(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        unit: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) throws -> CompactControlResult {
        guard let dispatcher else {
            throw SessionKitError.invalidCommandForState("compact_control_unconfigured")
        }
        let result = try dispatcher.dispatch(
            command,
            chapterId: chapterId,
            unit: unit,
            mediaTimeMs: mediaTimeMs,
            playbackRate: playbackRate
        )
        lastCommand = command
        lastCommandOrigin = origin
        lastResult = result.delegatedToCanonicalRuntime ? "delegated" : (result.rejectedReason ?? "rejected")
        publish(result.snapshot, force: true)
        return result
    }

    func reconcileLiveActivities() {
        publishCurrentSnapshot(force: true)
    }

    func endLiveActivities() {
        lastPublishedSnapshot = nil
        liveActivity.endAll()
        liveSpeechNowPlaying.end()
    }

    func diagnostics() -> [String: String] {
        let snapshot = snapshot
        return [
            "gate2CompactSurface": snapshot?.compactSurfaceReady == true ? "ready" : "not_ready",
            "gate2SurfaceProfile": snapshot?.surfaceProfileId ?? "none",
            "gate2NowPlaying": liveSpeechNowPlaying.status,
            "gate2NowPlayingOwner": snapshot.map(Gate2LiveSpeechNowPlayingPolicy.isLiveSpeech) == true ? "live_speech_coordinator" : "media_coordinator",
            "gate2LastRemoteCommand": liveSpeechNowPlaying.lastRemoteCommand,
            "gate2LastRemoteCommandDetail": liveSpeechNowPlaying.lastRemoteCommandDetail,
            "gate2LiveActivity": liveActivity.status,
            "gate2LastCommand": lastCommand?.rawValue ?? "none",
            "gate2LastCommandOrigin": lastCommandOrigin,
            "gate2LastApplicationCommand": lastApplicationCommand,
            "gate2LastResult": lastResult,
            "gate2ExposedCommands": snapshot?.exposedCommands.map(\.rawValue).joined(separator: ",") ?? "none",
            "gate2Recording": snapshot?.isRecording == true ? "true" : "false"
        ]
    }

    private func publishCurrentSnapshot(force: Bool = false) {
        guard let snapshot = dispatcher?.snapshot() else { return }
        publish(snapshot, force: force)
    }

    private func publish(_ snapshot: CompactControlSnapshot, force: Bool = false) {
        if !force,
           let lastPublishedSnapshot,
           Self.hasEquivalentSurfaceState(lastPublishedSnapshot, snapshot) {
            return
        }
        lastPublishedSnapshot = snapshot
        liveSpeechNowPlaying.publish(snapshot)
        liveActivity.publish(snapshot)
    }

    nonisolated static func hasEquivalentSurfaceState(
        _ lhs: CompactControlSnapshot,
        _ rhs: CompactControlSnapshot
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        // The system advances an active Now Playing elapsed time from its rate,
        // while the Live Activity presents integer progress. Republishing only
        // because the raw millisecond clock advanced creates needless ActivityKit
        // and MediaPlayer work on the main actor during every playback tick.
        lhs.currentMediaTimeMs = nil
        rhs.currentMediaTimeMs = nil
        return lhs == rhs
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
                queuedCommandHandler(command, "widget_or_live_activity_queue", queuedCommand.chapterId, nil, nil)
            } else if queuedApplicationCommandHandler?(queuedCommand.command) == true {
                lastApplicationCommand = queuedCommand.command
            }
        }
        return true
    }
}

@MainActor
private final class Gate2LiveActivityController: Gate2LiveActivityControlling {
    private var activityId: String?
    private var adoptedSessionId: String?
    private var publishGeneration = 0
    private var activityTask: Task<Void, Never>?
    private(set) var status = "not_started"

    func publish(_ snapshot: CompactControlSnapshot) {
        #if SPOKEN_MARGINS_LEGACY
        status = "unavailable_legacy"
        return
        #else
        publishGeneration += 1
        let generation = publishGeneration
        let previousActivityTask = activityTask
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = "disabled"
            return
        }
        if let sessionId = snapshot.sessionId,
           snapshot.status.isPlaybackActive || snapshot.isRecording {
            adoptedSessionId = sessionId
        }
        guard Gate2LiveActivityPolicy.shouldMaintain(snapshot, adoptedSessionId: adoptedSessionId),
              let sessionId = snapshot.sessionId else {
            let inactiveSessionId = snapshot.sessionId
            let trackedActivityId = activityId
            if inactiveSessionId == nil || inactiveSessionId == adoptedSessionId {
                adoptedSessionId = nil
            }
            status = "ending"
            activityTask = Task { @MainActor in
                await previousActivityTask?.value
                guard generation == publishGeneration else { return }
                let endedCount = await Self.endInactiveActivities(
                    inactiveSessionId: inactiveSessionId,
                    trackedActivityId: trackedActivityId
                )
                guard generation == publishGeneration else { return }
                activityId = nil
                status = endedCount > 0 ? "ended" : "not_ready"
            }
            return
        }
        let nextChapter = Gate2LiveActivityPolicy.nextSourceChapter(from: snapshot)
        let state = Gate2LiveActivityAttributes.ContentState(
            title: snapshot.title ?? "Spoken Margins",
            chapterTitle: snapshot.chapterTitle ?? "Session",
            nextChapterTitle: nextChapter?.title,
            nextChapterId: nextChapter?.chapterId,
            status: snapshot.status.rawValue,
            phase: snapshot.phase.rawValue,
            progressPercent: snapshot.currentPlaybackProgressPercent,
            isRecording: snapshot.isRecording,
            availableCommands: Gate2LiveActivityPolicy.availableCommands(from: snapshot).map(\.rawValue)
        )
        activityTask = Task { @MainActor in
            await previousActivityTask?.value
            guard generation == publishGeneration else { return }
            let result = await Self.publishActivity(sessionId: sessionId, state: state)
            guard generation == publishGeneration else { return }
            activityId = result.activityId
            status = result.status
        }
        #else
        status = "unavailable"
        #endif
        #endif
    }

    func endAll() {
        #if SPOKEN_MARGINS_LEGACY
        status = "unavailable_legacy"
        #else
        publishGeneration += 1
        let generation = publishGeneration
        let previousActivityTask = activityTask
        previousActivityTask?.cancel()
        status = "ending"
        #if canImport(ActivityKit)
        activityTask = Task { @MainActor in
            // ActivityKit requests and updates are not guaranteed to stop when the
            // wrapping Swift task is cancelled. Wait for the prior publication to
            // settle before sweeping, or a late request can recreate an activity
            // immediately after an apparently successful end-all pass.
            await previousActivityTask?.value
            guard generation == publishGeneration else { return }
            let endedCount = await Self.endInactiveActivities(inactiveSessionId: nil, trackedActivityId: nil)
            guard generation == publishGeneration else { return }
            activityId = nil
            adoptedSessionId = nil
            status = endedCount > 0 ? "ended" : "not_ready"
        }
        #else
        status = "unavailable"
        #endif
        #endif
    }

    #if canImport(ActivityKit)
    private nonisolated static func publishActivity(
        sessionId: String,
        state: Gate2LiveActivityAttributes.ContentState
    ) async -> (activityId: String?, status: String) {
        let content = ActivityContent(state: state, staleDate: nil)
        let activities = Activity<Gate2LiveActivityAttributes>.activities
        var matchingActivities: [Activity<Gate2LiveActivityAttributes>] = []
        var endedCount = 0
        for activity in activities {
            if Gate2LiveActivityPolicy.shouldEnd(activitySessionId: activity.attributes.sessionId, currentSessionId: sessionId) {
                await end(activity)
                endedCount += 1
            } else {
                matchingActivities.append(activity)
            }
        }
        if let activity = matchingActivities.first {
            await activity.update(content)
            for duplicate in matchingActivities.dropFirst() {
                await end(duplicate)
                endedCount += 1
            }
            return (activity.id, endedCount > 0 ? "updated_pruned_stale" : "updated")
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

    private nonisolated static func endInactiveActivities(inactiveSessionId: String?, trackedActivityId: String?) async -> Int {
        var endedCount = 0
        for activity in Activity<Gate2LiveActivityAttributes>.activities where Gate2LiveActivityPolicy.shouldEndInactive(
            activitySessionId: activity.attributes.sessionId,
            activityId: activity.id,
            inactiveSessionId: inactiveSessionId,
            trackedActivityId: trackedActivityId
        ) {
            await end(activity)
            endedCount += 1
        }
        return endedCount
    }

    private nonisolated static func end(_ activity: Activity<Gate2LiveActivityAttributes>) async {
        let content: ActivityContent<Gate2LiveActivityAttributes.ContentState>? = nil
        await activity.end(content, dismissalPolicy: .immediate)
    }
    #endif
}

@MainActor
private final class Gate2LiveSpeechNowPlayingController {
    var commandHandler: (@MainActor (CompactControlCommand, Double?) -> Void)?
    private(set) var lastRemoteCommand = "none"
    private(set) var lastRemoteCommandDetail = "none"
    private(set) var status = "media_coordinator"
    private var ownsNowPlayingInfo = false
    #if canImport(MediaPlayer)
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    #endif

    func publish(_ snapshot: CompactControlSnapshot) {
        #if canImport(MediaPlayer)
        let publishesLiveSpeech = Gate2LiveSpeechNowPlayingPolicy.isLiveSpeech(snapshot)
        let publishesNativeMediaMetadata = Gate2NativeMediaNowPlayingPolicy.shouldPublish(snapshot)
        guard publishesLiveSpeech || publishesNativeMediaMetadata else {
            if ownsNowPlayingInfo {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            uninstallRemoteCommandHandlers()
            ownsNowPlayingInfo = false
            status = "inactive"
            return
        }
        guard !publishesLiveSpeech || Gate2LiveSpeechNowPlayingPolicy.shouldPublish(snapshot) else {
            if ownsNowPlayingInfo {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            uninstallRemoteCommandHandlers()
            ownsNowPlayingInfo = false
            status = "inactive"
            return
        }
        var audioSessionFailure: String?
        if publishesLiveSpeech {
            installRemoteCommandHandlersIfNeeded()
            audioSessionFailure = activatePlaybackAudioSessionIfNeeded(for: snapshot)
        } else {
            // The native AVPlayer route remains the transport-command owner. This
            // controller republishes metadata so its system Now Playing card does
            // not disappear after pause, backgrounding, or a route handoff.
            uninstallRemoteCommandHandlers()
        }
        #if canImport(UIKit)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
        if publishesLiveSpeech {
            configureRemoteCommandAvailability(for: snapshot)
        }
        let timeline = Gate2NowPlayingTimelineMetadata(snapshot: snapshot)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title ?? "Spoken Margins",
            MPMediaItemPropertyAlbumTitle: snapshot.chapterTitle ?? "Session",
            MPMediaItemPropertyArtist: "Spoken Margins",
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.status.isPlaybackActive ? snapshot.playbackRate : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let elapsedSeconds = timeline.elapsedSeconds,
           let durationSeconds = timeline.durationSeconds {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedSeconds
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = snapshot.playbackRate
        info[MPNowPlayingInfoPropertyIsLiveStream] = timeline.isLiveStream
        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = snapshot.sessionId
        if let targetId = snapshot.targetId, let url = URL(string: targetId), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            info[MPNowPlayingInfoPropertyAssetURL] = url
        }
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = info
        ownsNowPlayingInfo = true
        if let audioSessionFailure {
            status = "live_speech_audio_session_failed:\(audioSessionFailure)"
        } else {
            status = publishesLiveSpeech ? "live_speech_published" : "native_media_metadata_published"
        }
        #else
        status = "unavailable"
        #endif
    }

    private func configureRemoteCommandAvailability(for snapshot: CompactControlSnapshot) {
        #if canImport(MediaPlayer)
        let center = MPRemoteCommandCenter.shared()
        let availability = Gate2NowPlayingCommandAvailability(snapshot: snapshot)
        center.playCommand.isEnabled = availability.canPlay
        center.pauseCommand.isEnabled = availability.canPause
        center.togglePlayPauseCommand.isEnabled = availability.canTogglePlayPause
        center.skipBackwardCommand.isEnabled = availability.canSkipBack
        center.previousTrackCommand.isEnabled = availability.canPreviousTrack
        center.skipForwardCommand.isEnabled = availability.canSkipForward
        center.nextTrackCommand.isEnabled = availability.canNextTrack
        center.stopCommand.isEnabled = availability.canStop
        center.changePlaybackPositionCommand.isEnabled = availability.canSeek
        center.changePlaybackRateCommand.isEnabled = availability.canSetPlaybackRate
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        #endif
    }

    func end() {
        #if canImport(MediaPlayer)
        if ownsNowPlayingInfo {
            let nowPlayingCenter = MPNowPlayingInfoCenter.default()
            nowPlayingCenter.nowPlayingInfo = nil
        }
        uninstallRemoteCommandHandlers()
        #endif
        ownsNowPlayingInfo = false
        status = "ended"
    }

    private func installRemoteCommandHandlersIfNeeded() {
        #if canImport(MediaPlayer)
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.preferredIntervals = [15]
        register(center.playCommand, command: .play, detail: "none")
        register(center.pauseCommand, command: .pause, detail: "none")
        register(center.togglePlayPauseCommand, command: .togglePlayPause, detail: "none")
        register(center.skipBackwardCommand, command: .skipBack, detail: "15s")
        register(center.skipForwardCommand, command: .skipForward, detail: "15s")
        register(center.stopCommand, command: .pause, detail: "none")
        let rateTarget = center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = CompactControlCommand.setPlaybackRate.rawValue
                self?.lastRemoteCommandDetail = String(format: "%.2f", event.playbackRate)
                self?.commandHandler?(.setPlaybackRate, Double(event.playbackRate))
            }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackRateCommand, rateTarget))
        #endif
    }

    private func activatePlaybackAudioSessionIfNeeded(for snapshot: CompactControlSnapshot) -> String? {
        #if canImport(AVFoundation) && os(iOS)
        guard snapshot.status.isPlaybackActive || snapshot.status == .paused else { return nil }
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback
                || session.mode != .spokenAudio
                || !session.categoryOptions.isEmpty {
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
            }
            try session.setActive(true)
            return nil
        } catch {
            return error.localizedDescription
        }
        #else
        return nil
        #endif
    }

    #if canImport(MediaPlayer)
    private func register(_ remoteCommand: MPRemoteCommand, command: CompactControlCommand, detail: String) {
        let target = remoteCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = command.rawValue
                self?.lastRemoteCommandDetail = detail
                self?.commandHandler?(command, nil)
            }
            return .success
        }
        remoteCommandTargets.append((remoteCommand, target))
    }

    private func uninstallRemoteCommandHandlers() {
        for registration in remoteCommandTargets {
            registration.command.removeTarget(registration.target)
        }
        remoteCommandTargets.removeAll()
    }
    #else
    private func uninstallRemoteCommandHandlers() {}
    #endif
}
