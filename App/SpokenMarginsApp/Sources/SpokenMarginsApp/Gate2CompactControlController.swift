import Foundation
import SessionKit
import SessionKitAudio

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
#if canImport(CallKit) && os(iOS)
import CallKit
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

    init(snapshot: CompactControlSnapshot, headphoneDoublePressAddsMargin: Bool = false) {
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
        // Exception (#2031): a headphone double-press arrives as next track, so while it adds a Margin the
        // command stays enabled whenever skip forward is. Not checked on a phone: whether iOS then swaps the
        // Lock Screen skip icons for track icons is the thing to look at.
        canNextTrack = headphoneDoublePressAddsMargin && canSkipForward
        // While a Margin records these commands end it. Disabled, iOS drops the headphone click before it
        // reaches the app (#1030).
        if snapshot.transportCommandsEndMargin {
            canNextTrack = headphoneDoublePressAddsMargin
            canPlay = true
            canPause = true
            canTogglePlayPause = true
            canSkipForward = true
            canStop = true // registered as pause
        }
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
    /// Now Playing remains the authoritative general transport surface. The Live
    /// Activity exposes only bounded actions whose shared intents execute in the
    /// app process and hand off to the canonical player.
    static func availableCommands(from snapshot: CompactControlSnapshot) -> [CompactControlCommand] {
        snapshot.availableCommands.filter {
            switch $0 {
            case .beginInterjection, .finishInterjection, .skimBackward, .skimForward:
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

    static func nextNavigationEntry(
        from snapshot: CompactControlSnapshot,
        upcomingSharedMargins: [Gate2LiveActivityNavigationEntry]
    ) -> Gate2LiveActivityNavigationEntry? {
        let sourceChapter = nextSourceChapter(from: snapshot).flatMap { chapter -> Gate2LiveActivityNavigationEntry? in
            guard let chapterID = chapter.chapterId else { return nil }
            return Gate2LiveActivityNavigationEntry(
                kind: .sourceChapter,
                title: chapter.title,
                targetID: chapterID,
                positionPercent: chapter.percent ?? 100
            )
        }
        return ([sourceChapter].compactMap { $0 } + upcomingSharedMargins)
            .sorted { lhs, rhs in
                if lhs.positionPercent == rhs.positionPercent {
                    return lhs.kind == .sourceChapter && rhs.kind == .sharedMargin
                }
                return lhs.positionPercent < rhs.positionPercent
            }
            .first
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
        if snapshot.audibleStatus.isPlaybackActive || snapshot.isRecording { // a Skim summary counts (#2965)
            return true
        }
        return snapshot.audibleStatus == .paused && adoptedSessionId == sessionId
    }

    /// `isFirstPassInProcess`: activities left by an earlier process (killed in the background, so
    /// `willTerminate` never ran) are ended by the first idle pass after launch, whatever their session.
    static func shouldEndInactive(
        activitySessionId: String,
        activityId: String,
        inactiveSessionId: String?,
        trackedActivityId: String?,
        isFirstPassInProcess: Bool = false
    ) -> Bool {
        if isFirstPassInProcess {
            return true
        }
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

/// A finished or abandoned session leaves no card, even one the player holds: the player only rewrites it on its own
/// events, and a finished episode whose session stays open would keep a stale "finished" card (#58, #943).
enum Gate2EndedSessionNowPlaying {
    static func clearPlayerCard(for snapshot: CompactControlSnapshot) {
        switch snapshot.phase {
        case .finished, .abandoned:
            NowPlayingInfoOwnership.shared.clear(as: .mediaPlayer, detail: "session_ended phase=\(snapshot.phase)")
        default:
            break
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

    func publish(
        _ snapshot: CompactControlSnapshot,
        staleDate: Date?,
        sharedMarginPrompt: Gate2SharedMarginActivityPrompt?,
        upcomingSharedMargins: [Gate2LiveActivityNavigationEntry],
        microphone: Gate2LiveActivityMicrophone
    )
    func endAll()
    /// Ends every activity with its current content and lets iOS remove it at `date`, so the
    /// card goes on time even if the app never runs again (#193, option 2).
    func handOffDismissal(at date: Date) async
}

struct Gate2SharedMarginActivityPrompt: Equatable, Sendable {
    let senderLabel: String
}

struct Gate2LiveActivityNavigationEntry: Equatable, Sendable {
    let kind: Gate2LiveActivityNavigationKind
    let title: String
    let targetID: String
    let positionPercent: Int
}

@MainActor
final class Gate2CompactControlController {
    private var dispatcher: CompactControlDispatcher?
    private var sharedMarginPrompt: Gate2SharedMarginActivityPrompt?
    private var upcomingSharedMargins: [Gate2LiveActivityNavigationEntry] = []
    private var queuedCommandTask: Task<Void, Never>?
    private var queuedCommandHandler: (@MainActor (CompactControlCommand, String, String?, Int?, Double?) -> Void)?
    private var queuedApplicationCommandHandler: (@MainActor (String, String?) -> Bool)?
    private let liveActivity: any Gate2LiveActivityControlling
    private var liveActivityLifecycle = LiveActivityLifecycle()
    private var liveActivityLifecycleStatus = "none"
    private var idleDeadlineTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var endWatchBackgroundTask: (@MainActor () -> Void)?
    private let now: () -> Date
    private let isAppInBackground: @MainActor () -> Bool
    private let isOtherAudioPlaying: @MainActor () -> Bool
    private let isPhoneCallActive: @MainActor () -> Bool
    private let beginBackgroundTask: @MainActor (String) -> (@MainActor () -> Void)
    #if canImport(AVFoundation) && os(iOS)
    private var audioInterruptionObserver: Gate2AudioInterruptionObserver?
    #endif
    private var appLifecycleObserver: Gate2AppLifecycleObserver?
    private let liveSpeechNowPlaying = Gate2LiveSpeechNowPlayingController()
    private var nowPlayingEnabled = true
    private var lastPublishedSnapshot: CompactControlSnapshot?
    private var latestAppSnapshot: SessionSnapshot?
    /// Where the model's Skim plans land (#115), carried to the Lock Screen with the snapshot.
    private var latestSkimDestinations: (forward: Int?, backward: Int?) = (nil, nil)
    /// Whether the microphone is really taking in sound, for the Live Activity's REC indicator (#937).
    private(set) var microphone = Gate2LiveActivityMicrophone.capturing
    private(set) var lastCommand: CompactControlCommand?
    private(set) var lastCommandOrigin = "none"
    private(set) var lastApplicationCommand = "none"
    private(set) var lastResult = "none"

    init(
        liveActivity: (any Gate2LiveActivityControlling)? = nil,
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter = .default,
        isAppInBackground: @escaping @MainActor () -> Bool = Gate2AppState.isInBackground,
        isOtherAudioPlaying: @escaping @MainActor () -> Bool = Gate2AppState.isOtherAudioPlaying,
        isPhoneCallActive: @escaping @MainActor () -> Bool = Gate2AppState.isPhoneCallActive,
        beginBackgroundTask: @escaping @MainActor (String) -> (@MainActor () -> Void) = Gate2AppState.beginBackgroundTask
    ) {
        self.liveActivity = liveActivity ?? Gate2LiveActivityController()
        self.now = now
        self.isAppInBackground = isAppInBackground
        self.isOtherAudioPlaying = isOtherAudioPlaying
        self.isPhoneCallActive = isPhoneCallActive
        self.beginBackgroundTask = beginBackgroundTask
        #if canImport(AVFoundation) && os(iOS)
        audioInterruptionObserver = Gate2AudioInterruptionObserver(
            center: notificationCenter,
            onBegan: { [weak self] in self?.handleAudioInterruptionBegan() },
            onEnded: { [weak self] shouldResume in self?.handleAudioInterruptionEnded(shouldResume: shouldResume) }
        )
        #endif
        appLifecycleObserver = Gate2AppLifecycleObserver(
            center: notificationCenter,
            onBackground: { [weak self] in self?.startBackgroundWatchIfNeeded() },
            onForeground: { [weak self] in self?.handleAppReturnedToForeground() }
        )
    }

    var snapshot: CompactControlSnapshot? {
        currentSnapshot()
    }

    func configure(
        canonicalRuntime: SessionEngine,
        surfaceProfile: RuntimeCapabilityProfile,
        skipUnit: String,
        commandHandler: @escaping @MainActor (CompactControlCommand, String, String?, Int?, Double?) -> Void,
        applicationCommandHandler: @escaping @MainActor (String, String?) -> Bool = { _, _ in false }
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
        liveSpeechNowPlaying.nextTrackHandler = { [weak self] in
            self?.queuedCommandHandler?(
                .skipForward, "now_playing_live_speech" + HeadphoneRemoteSignal.nextTrackOriginSuffix, nil, nil, nil
            )
        }
        installQueuedWidgetCommandProcessor()
        publishCurrentSnapshot(force: true)
        lastResult = "configured"
    }

    /// A Margin or turn changed in the app, not through a command here: the card's timeline is read again (#2505).
    func noteMarginsChanged() {
        dispatcher?.noteContentChanged()
    }

    /// The capture watcher found the microphone starting, capturing or stopped. The card says REC only
    /// for capturing, and is republished at once while a Margin records.
    func setMicrophone(_ state: Gate2LiveActivityMicrophone) {
        guard microphone != state else { return }
        microphone = state
        if snapshot?.isRecording == true { publishCurrentSnapshot(force: true) }
    }

    func update(
        snapshot: SessionSnapshot,
        sharedMarginPrompt: Gate2SharedMarginActivityPrompt? = nil,
        upcomingSharedMargins: [Gate2LiveActivityNavigationEntry] = [],
        skimForwardDestinationMs: Int? = nil,
        skimBackwardDestinationMs: Int? = nil
    ) {
        guard dispatcher != nil else { return }
        let activityContextChanged = self.sharedMarginPrompt != sharedMarginPrompt
            || self.upcomingSharedMargins != upcomingSharedMargins
        latestAppSnapshot = snapshot
        latestSkimDestinations = (skimForwardDestinationMs, skimBackwardDestinationMs)
        self.sharedMarginPrompt = sharedMarginPrompt
        self.upcomingSharedMargins = upcomingSharedMargins
        let drainedCommand = drainQueuedWidgetCommands()
        if !drainedCommand {
            publishCurrentSnapshot(force: activityContextChanged)
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
        NowPlayingInfoOwnership.shared.note("lifecycle_refresh")
        publishCurrentSnapshot(force: true)
    }

    /// Another app kept the audio after an interruption: a paused Live Activity goes now rather
    /// than waiting out the idle limit. A phone call ends with `shouldResume`, so it stays.
    func handleAudioInterruptionEnded(shouldResume: Bool) {
        guard case .end(let reason)? = liveActivityLifecycle.audioInterruptionEnded(shouldResume: shouldResume) else {
            return
        }
        liveActivity.endAll()
        liveActivityLifecycleStatus = "ended_\(reason.rawValue)"
        scheduleIdleDeadlineCheck()
        cancelWatch()
    }

    /// A phone call or another app took the audio: that pause never hands off to iOS. A call keeps
    /// the card for resuming; otherwise the app watches for another app's audio (#245).
    func handleAudioInterruptionBegan() {
        liveActivityLifecycle.audioInterruptionBegan()
        if isPhoneCallActive() {
            cancelWatch()
        } else {
            startBackgroundWatchIfNeeded()
        }
    }

    /// #245: if another app is playing audio while our card is paused in the background, and no call
    /// is active, the card ends now. Internal so tests can run a check without waiting.
    @discardableResult
    func checkForOtherAudio() -> Bool {
        guard isAppInBackground(),
              case .end(let reason)? = liveActivityLifecycle.otherAudioChecked(
                isOtherAudioPlaying: isOtherAudioPlaying(),
                isPhoneCallActive: isPhoneCallActive()
              ) else { return false }
        liveActivity.endAll()
        liveActivityLifecycleStatus = "ended_\(reason.rawValue)"
        scheduleIdleDeadlineCheck()
        cancelWatch()
        return true
    }

    /// Runs when the grace after a locked pause ends. Internal so tests can fire it on an
    /// injected clock instead of waiting.
    func handOffIfDue() async {
        guard let dismissAt = liveActivityLifecycle.handOffIfDue(appInBackground: isAppInBackground(), now: now()) else {
            finishWatch()
            return
        }
        liveActivityLifecycleStatus = "handed_off_to_system"
        scheduleIdleDeadlineCheck()
        await liveActivity.handOffDismissal(at: dismissAt)
        finishWatch()
    }

    private func handleAppReturnedToForeground() {
        liveActivityLifecycle.appReturnedToForeground()
        cancelWatch()
    }

    /// A pause with the app in the background (phone locked, paused from AirPods or the Lock Screen,
    /// or the listener switched apps). For the grace, the app checks every few seconds whether another
    /// app is playing audio, and ends the card at once if so (#245). At the end of the grace, a
    /// listener pause hands the removal to iOS (#193). A background task keeps the app running
    /// through the watch; otherwise iOS would suspend it first. Not during a phone call.
    private func startBackgroundWatchIfNeeded() {
        guard isAppInBackground(), !isPhoneCallActive(), liveActivityLifecycle.isPausedCardOnScreen else {
            cancelWatch()
            return
        }
        let handOffAt = liveActivityLifecycle.scheduleHandOff(appInBackground: true, now: now())
        guard watchTask == nil else { return }
        endWatchBackgroundTask = beginBackgroundTask("Spoken Margins Live Activity watch")
        let interval = LiveActivityLifecycle.otherAudioCheckInterval
        let checks = max(1, Int(LiveActivityLifecycle.lockedPauseGrace / interval))
        watchTask = Task { @MainActor [weak self] in
            for _ in 0..<checks {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                if self.checkForOtherAudio() { return }
            }
            guard !Task.isCancelled else { return }
            await self?.handOffIfDue()
        }
        liveActivityLifecycleStatus = handOffAt == nil ? "watching_other_audio" : "hand_off_scheduled"
    }

    private func cancelWatch() {
        watchTask?.cancel()
        finishWatch()
    }

    private func finishWatch() {
        watchTask = nil
        endWatchBackgroundTask?()
        endWatchBackgroundTask = nil
    }

    func setNowPlayingEnabled(_ enabled: Bool) {
        guard nowPlayingEnabled != enabled else { return }
        nowPlayingEnabled = enabled
        if enabled {
            publishCurrentSnapshot(force: true)
        } else {
            liveSpeechNowPlaying.end()
        }
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
            "gate2NowPlayingEnabled": nowPlayingEnabled ? "true" : "false",
            "gate2NowPlayingLedger": NowPlayingInfoOwnership.shared.summary(),
            "gate2NowPlayingOwner": snapshot.map(Gate2LiveSpeechNowPlayingPolicy.isLiveSpeech) == true ? "live_speech_coordinator" : "media_coordinator",
            "gate2LastRemoteCommand": liveSpeechNowPlaying.lastRemoteCommand,
            "gate2LastRemoteCommandDetail": liveSpeechNowPlaying.lastRemoteCommandDetail,
            "gate2LiveActivity": liveActivity.status,
            "gate2LiveActivityLifecycle": liveActivityLifecycleStatus,
            "gate2LastCommand": lastCommand?.rawValue ?? "none",
            "gate2LastCommandOrigin": lastCommandOrigin,
            "gate2LastApplicationCommand": lastApplicationCommand,
            "gate2LastResult": lastResult,
            "gate2ExposedCommands": snapshot?.exposedCommands.map(\.rawValue).joined(separator: ",") ?? "none",
            "gate2Recording": snapshot?.isRecording == true ? "true" : "false"
        ]
    }

    private func publishCurrentSnapshot(force: Bool = false) {
        guard let snapshot = currentSnapshot() else { return }
        publish(snapshot, force: force)
    }

    private func currentSnapshot() -> CompactControlSnapshot? {
        guard var compact = dispatcher?.snapshot() else { return nil }
        guard let app = latestAppSnapshot else { return compact }
        compact.skimBridgeState = app.skimBridgeState
        compact.canSkimForward = app.canSkimForward
        compact.canSkimBackward = app.canSkimBackward
        compact.availableCommands.removeAll {
            $0 == .skimForward || $0 == .skimBackward
                || ($0 == .beginInterjection && app.skimBridgeState != nil)
        }
        if !app.isRecording, app.canSkimBackward, compact.exposedCommands.contains(.skimBackward) {
            compact.availableCommands.append(.skimBackward)
        }
        if !app.isRecording, app.canSkimForward, compact.exposedCommands.contains(.skimForward) {
            compact.availableCommands.append(.skimForward)
        }
        // Only for a button that is shown, so a hidden Skim never leaves a stale time behind.
        compact.skimForwardDestinationMs = compact.availableCommands.contains(.skimForward)
            ? latestSkimDestinations.forward : nil
        compact.skimBackwardDestinationMs = compact.availableCommands.contains(.skimBackward)
            ? latestSkimDestinations.backward : nil
        return compact
    }

    private func publish(_ snapshot: CompactControlSnapshot, force: Bool = false) {
        if !force,
           let lastPublishedSnapshot,
           Self.hasEquivalentSurfaceState(lastPublishedSnapshot, snapshot) {
            return
        }
        lastPublishedSnapshot = snapshot
        if nowPlayingEnabled {
            liveSpeechNowPlaying.publish(snapshot)
        } else {
            liveSpeechNowPlaying.end()
        }
        publishLiveActivity(snapshot)
    }

    private func publishLiveActivity(_ snapshot: CompactControlSnapshot) {
        let decision = liveActivityLifecycle.observe(
            sessionId: snapshot.sessionId,
            // A Skim summary playing over the paused source is listening, not an idle pause (#2965).
            isListening: snapshot.audibleStatus.isPlaybackActive || snapshot.isRecording,
            isPaused: snapshot.audibleStatus == .paused,
            now: now()
        )
        switch decision {
        case .show(let staleDate):
            liveActivity.publish(
                snapshot,
                staleDate: staleDate,
                sharedMarginPrompt: sharedMarginPrompt,
                upcomingSharedMargins: upcomingSharedMargins,
                microphone: microphone
            )
            liveActivityLifecycleStatus = staleDate == nil ? "live" : "paused_idle_deadline"
            if staleDate == nil {
                cancelWatch()
            } else {
                startBackgroundWatchIfNeeded()
            }
        case .end(let reason):
            liveActivity.endAll()
            liveActivityLifecycleStatus = "ended_\(reason.rawValue)"
            cancelWatch()
        case .hidden(let reason):
            liveActivityLifecycleStatus = "ended_\(reason.rawValue)"
        }
        scheduleIdleDeadlineCheck()
    }

    /// Ends a paused activity at its deadline while the process is running. When the app is
    /// suspended this doesn't fire; the stale date changes the card's look instead, and the next
    /// refresh (returning to the foreground) ends it.
    private func scheduleIdleDeadlineCheck() {
        idleDeadlineTask?.cancel()
        idleDeadlineTask = nil
        guard let deadline = liveActivityLifecycle.idleDeadline else { return }
        let delay = max(0, deadline.timeIntervalSince(now()))
        idleDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.publishCurrentSnapshot(force: true)
        }
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
                // Stops once the controller is gone; it used to wake every 400 ms for the rest of the process (#2195).
                guard self?.drainQueuedWidgetCommands() != nil else { return }
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
            } else if queuedApplicationCommandHandler?(queuedCommand.command, queuedCommand.chapterId) == true {
                lastApplicationCommand = queuedCommand.command
            }
        }
        return true
    }
}

#if canImport(ActivityKit)
/// One Live Activity card as the controller's sweeps see it: ActivityKit's `Activity` in the app,
/// a fake in tests, so the orphan sweep and duplicate pruning run under test (APO-05, #1291).
protocol Gate2LiveActivityCard: Sendable {
    var id: String { get }
    var sessionId: String { get }
    var state: ActivityState { get }
    func update(_ state: Gate2LiveActivityAttributes.ContentState, staleDate: Date?) async
    /// Ends the card and takes it off the screen now.
    func endImmediately() async
    /// Ends the card with its current content; iOS removes it at `date`.
    func endKeepingContent(dismissAt date: Date) async
}

/// Where the Live Activity controller reads, requests and checks permission for cards.
struct Gate2LiveActivitySystem: Sendable {
    var areActivitiesEnabled: @MainActor @Sendable () -> Bool
    var activities: @Sendable () -> [any Gate2LiveActivityCard]
    /// Requests a new card and returns its id.
    var request: @Sendable (
        _ sessionId: String,
        _ state: Gate2LiveActivityAttributes.ContentState,
        _ staleDate: Date?
    ) throws -> String

    static let activityKit = Gate2LiveActivitySystem(
        areActivitiesEnabled: { ActivityAuthorizationInfo().areActivitiesEnabled },
        activities: { Activity<Gate2LiveActivityAttributes>.activities.map(ActivityKitLiveActivityCard.init) },
        request: { sessionId, state, staleDate in
            try Activity<Gate2LiveActivityAttributes>.request(
                attributes: Gate2LiveActivityAttributes(sessionId: sessionId),
                content: ActivityContent(state: state, staleDate: staleDate),
                pushType: nil
            ).id
        }
    )

    /// The default under unit tests: no card, and no call to ActivityKit. Each of those calls waits on a system
    /// daemon from the main thread, and on a loaded Mac they left 1 to 2.5 s of main-queue work behind the test
    /// that made them (#2195). Tests of the cards themselves pass a fake system.
    static let unitTestHost = Gate2LiveActivitySystem(
        areActivitiesEnabled: { false },
        activities: { [] },
        request: { _, _, _ in throw CancellationError() }
    )
}

private struct ActivityKitLiveActivityCard: Gate2LiveActivityCard, @unchecked Sendable {
    let activity: Activity<Gate2LiveActivityAttributes>

    var id: String { activity.id }
    var sessionId: String { activity.attributes.sessionId }
    var state: ActivityState { activity.activityState }

    func update(_ state: Gate2LiveActivityAttributes.ContentState, staleDate: Date?) async {
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    func endImmediately() async {
        let content: ActivityContent<Gate2LiveActivityAttributes.ContentState>? = nil
        await activity.end(content, dismissalPolicy: .immediate)
    }

    func endKeepingContent(dismissAt date: Date) async {
        await activity.end(activity.content, dismissalPolicy: .after(date))
    }
}
#endif

@MainActor
final class Gate2LiveActivityController: Gate2LiveActivityControlling {
    #if canImport(ActivityKit)
    private let system: Gate2LiveActivitySystem
    #endif
    private var activityId: String?
    private var adoptedSessionId: String?
    private var hasSweptEarlierProcess = false
    private var publishGeneration = 0
    private var activityTask: Task<Void, Never>?
    private(set) var status = "not_started"

    #if canImport(ActivityKit)
    init(system: Gate2LiveActivitySystem = Gate1AppModel.isRunningUnitTests ? .unitTestHost : .activityKit) {
        self.system = system
    }
    #endif

    /// Waits for the queued ActivityKit work to finish (tests).
    func waitForPendingWork() async {
        await activityTask?.value
    }

    func publish(
        _ snapshot: CompactControlSnapshot,
        staleDate: Date?,
        sharedMarginPrompt: Gate2SharedMarginActivityPrompt?,
        upcomingSharedMargins: [Gate2LiveActivityNavigationEntry],
        microphone: Gate2LiveActivityMicrophone
    ) {
        #if SPOKEN_MARGINS_LEGACY
        status = "unavailable_legacy"
        return
        #else
        publishGeneration += 1
        let generation = publishGeneration
        let previousActivityTask = activityTask
        #if canImport(ActivityKit)
        guard system.areActivitiesEnabled() else {
            status = "disabled"
            return
        }
        let system = system
        if let sessionId = snapshot.sessionId,
           snapshot.audibleStatus.isPlaybackActive || snapshot.isRecording {
            adoptedSessionId = sessionId
        }
        // Set only once a sweep has run: a pass superseded by a newer publish sweeps nothing.
        let isFirstPassInProcess = !hasSweptEarlierProcess
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
                    system.activities(),
                    inactiveSessionId: inactiveSessionId,
                    trackedActivityId: trackedActivityId,
                    isFirstPassInProcess: isFirstPassInProcess
                )
                hasSweptEarlierProcess = true
                guard generation == publishGeneration else { return }
                activityId = nil
                status = endedCount > 0 ? "ended" : "not_ready"
            }
            return
        }
        let nextNavigation = Gate2LiveActivityPolicy.nextNavigationEntry(
            from: snapshot,
            upcomingSharedMargins: upcomingSharedMargins
        )
        let state = Gate2LiveActivityAttributes.ContentState(
            title: snapshot.title ?? "Spoken Margins",
            chapterTitle: snapshot.chapterTitle ?? "Session",
            nextChapterTitle: nextNavigation?.title,
            nextChapterId: nextNavigation?.targetID,
            nextNavigationKind: nextNavigation?.kind,
            status: snapshot.audibleStatus.rawValue, // what is heard: a Skim summary is not "Paused, tap to resume" (#2965)
            phase: snapshot.phase.rawValue,
            progressPercent: snapshot.currentPlaybackProgressPercent,
            isRecording: snapshot.isRecording,
            microphone: snapshot.isRecording ? microphone : .capturing,
            availableCommands: Gate2LiveActivityPolicy.availableCommands(from: snapshot).map(\.rawValue),
            sharedMarginSenderLabel: sharedMarginPrompt?.senderLabel,
            skimForwardDestinationMs: snapshot.skimForwardDestinationMs,
            skimBackwardDestinationMs: snapshot.skimBackwardDestinationMs
        )
        activityTask = Task { @MainActor in
            await previousActivityTask?.value
            guard generation == publishGeneration else { return }
            // Publishing ends every other session's activity and any duplicate, so it is a sweep too.
            let result = await Self.publishActivity(system, sessionId: sessionId, state: state, staleDate: staleDate)
            hasSweptEarlierProcess = true
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
            let endedCount = await Self.endInactiveActivities(system.activities(), inactiveSessionId: nil, trackedActivityId: nil)
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

    func handOffDismissal(at date: Date) async {
        #if SPOKEN_MARGINS_LEGACY
        status = "unavailable_legacy"
        #else
        publishGeneration += 1
        let generation = publishGeneration
        let previousActivityTask = activityTask
        status = "handing_off"
        #if canImport(ActivityKit)
        let task = Task { @MainActor in
            await previousActivityTask?.value
            guard generation == publishGeneration else { return }
            let count = await Self.handOffActivities(system.activities(), dismissAt: date)
            guard generation == publishGeneration else { return }
            activityId = nil
            adoptedSessionId = nil
            status = count > 0 ? "handed_off" : "not_ready"
        }
        activityTask = task
        await task.value
        #else
        status = "unavailable"
        #endif
        #endif
    }

    #if canImport(ActivityKit)
    private nonisolated static func handOffActivities(_ cards: [any Gate2LiveActivityCard], dismissAt date: Date) async -> Int {
        var count = 0
        for card in cards where card.state == .active || card.state == .stale {
            await card.endKeepingContent(dismissAt: date)
            count += 1
        }
        return count
    }

    private nonisolated static func publishActivity(
        _ system: Gate2LiveActivitySystem,
        sessionId: String,
        state: Gate2LiveActivityAttributes.ContentState,
        staleDate: Date?
    ) async -> (activityId: String?, status: String) {
        var matchingCards: [any Gate2LiveActivityCard] = []
        var endedCount = 0
        for card in system.activities() {
            // A card handed off to iOS is ended but still on screen, saying "Paused". It can't be
            // updated, so it goes now and a new card is requested.
            if card.state == .ended {
                await card.endImmediately()
                endedCount += 1
                continue
            }
            if Gate2LiveActivityPolicy.shouldEnd(activitySessionId: card.sessionId, currentSessionId: sessionId) {
                await card.endImmediately()
                endedCount += 1
            } else {
                matchingCards.append(card)
            }
        }
        if let card = matchingCards.first {
            await card.update(state, staleDate: staleDate)
            for duplicate in matchingCards.dropFirst() {
                await duplicate.endImmediately()
                endedCount += 1
            }
            return (card.id, endedCount > 0 ? "updated_pruned_stale" : "updated")
        }
        do {
            let requestedId = try system.request(sessionId, state, staleDate)
            return (requestedId, "started")
        } catch {
            return (nil, "failed:\(error.localizedDescription)")
        }
    }

    private nonisolated static func endInactiveActivities(
        _ cards: [any Gate2LiveActivityCard],
        inactiveSessionId: String?,
        trackedActivityId: String?,
        isFirstPassInProcess: Bool = false
    ) async -> Int {
        var endedCount = 0
        for card in cards where Gate2LiveActivityPolicy.shouldEndInactive(
            activitySessionId: card.sessionId,
            activityId: card.id,
            inactiveSessionId: inactiveSessionId,
            trackedActivityId: trackedActivityId,
            isFirstPassInProcess: isFirstPassInProcess
        ) {
            await card.endImmediately()
            endedCount += 1
        }
        return endedCount
    }
    #endif
}

#if canImport(AVFoundation) && os(iOS)
/// Reports `AVAudioSession` interruptions: when one begins, and when it ends whether the system
/// says playback may resume.
private final class Gate2AudioInterruptionObserver {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(
        center: NotificationCenter,
        onBegan: @escaping @MainActor @Sendable () -> Void,
        onEnded: @escaping @MainActor @Sendable (_ shouldResume: Bool) -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            switch type {
            case .began:
                MainActor.assumeIsolated { onBegan() }
            case .ended:
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                MainActor.assumeIsolated { onEnded(shouldResume) }
            @unknown default:
                break
            }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}
#endif

/// Reports the app entering the background and returning to the foreground.
private final class Gate2AppLifecycleObserver {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter, onBackground: @escaping @MainActor @Sendable () -> Void, onForeground: @escaping @MainActor @Sendable () -> Void) {
        self.center = center
        #if canImport(UIKit)
        tokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onBackground() }
        })
        tokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onForeground() }
        })
        #endif
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}

/// The app's real background state and background tasks, injectable for tests.
enum Gate2AppState {
    @MainActor
    static func isInBackground() -> Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .background
        #else
        false
        #endif
    }

    /// Whether another app is playing audio now (#245).
    @MainActor
    static func isOtherAudioPlaying() -> Bool {
        #if canImport(AVFoundation) && os(iOS)
        AVAudioSession.sharedInstance().isOtherAudioPlaying
        #else
        false
        #endif
    }

    /// Whether a phone or VoIP call is in progress. A call's pause keeps the card (#193).
    @MainActor
    static func isPhoneCallActive() -> Bool {
        #if canImport(CallKit) && os(iOS)
        callObserver.calls.contains { !$0.hasEnded }
        #else
        false
        #endif
    }

    #if canImport(CallKit) && os(iOS)
    @MainActor private static let callObserver = CXCallObserver()
    #endif

    /// Begins a background task and returns the call that ends it. iOS ends it early if time runs out.
    @MainActor
    static func beginBackgroundTask(_ name: String) -> (@MainActor () -> Void) {
        #if canImport(UIKit)
        let token = BackgroundTaskToken()
        token.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { token.end() }
        }
        return { token.end() }
        #else
        return {}
        #endif
    }

    #if canImport(UIKit)
    @MainActor
    private final class BackgroundTaskToken {
        var identifier: UIBackgroundTaskIdentifier = .invalid

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
    #endif
}

@MainActor
private final class Gate2LiveSpeechNowPlayingController {
    var commandHandler: (@MainActor (CompactControlCommand, Double?) -> Void)?
    /// A headphone double-press: the next-track remote command, kept distinct from skip forward (#2031).
    var nextTrackHandler: (@MainActor () -> Void)?
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
                NowPlayingInfoOwnership.shared.clear(as: .compactControls, detail: "inactive phase=\(snapshot.phase)")
            }
            Gate2EndedSessionNowPlaying.clearPlayerCard(for: snapshot)
            uninstallRemoteCommandHandlers()
            ownsNowPlayingInfo = false
            status = "inactive"
            return
        }
        guard !publishesLiveSpeech || Gate2LiveSpeechNowPlayingPolicy.shouldPublish(snapshot) else {
            if ownsNowPlayingInfo {
                NowPlayingInfoOwnership.shared.clear(as: .compactControls, detail: "live_speech_ended phase=\(snapshot.phase)")
            }
            Gate2EndedSessionNowPlaying.clearPlayerCard(for: snapshot)
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
        // A pending start publishes rate 0 and a loading line: iOS runs the clock from a nonzero rate (#943).
        let presentation = SystemPlaybackPresentation(
            status: snapshot.status, selectedRate: snapshot.playbackRate, isNarration: publishesLiveSpeech
        )
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title ?? "Spoken Margins",
            MPMediaItemPropertyAlbumTitle: snapshot.chapterTitle ?? "Session",
            MPMediaItemPropertyArtist: presentation.loadingLine ?? "Spoken Margins",
            MPNowPlayingInfoPropertyPlaybackRate: presentation.playbackRate,
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
        let ledger = NowPlayingInfoOwnership.shared
        let ledgerDetail = "\(publishesLiveSpeech ? "live_speech" : "native_media") phase=\(snapshot.phase)"
        if publishesLiveSpeech {
            ledger.write(info, as: .compactControls, detail: ledgerDetail)
            ownsNowPlayingInfo = true
        } else {
            // The player owns a native media card and refreshes it every second. This fills the card only when the
            // player has none, so it never overwrites the player's or takes a card the player is keeping (#2181).
            ownsNowPlayingInfo = ledger.writeIfUnheld(info, as: .compactControls, detail: ledgerDetail)
        }
        if let audioSessionFailure {
            status = "live_speech_audio_session_failed:\(audioSessionFailure)"
        } else if publishesLiveSpeech {
            status = "live_speech_published"
        } else {
            status = ownsNowPlayingInfo ? "native_media_metadata_published" : "native_media_deferred_to_player"
        }
        #else
        status = "unavailable"
        #endif
    }

    private func configureRemoteCommandAvailability(for snapshot: CompactControlSnapshot) {
        #if canImport(MediaPlayer)
        let center = MPRemoteCommandCenter.shared()
        let addsMargin = HeadphoneDoublePressAction(
            storedValue: UserDefaults.standard.string(forKey: HeadphoneDoublePressAction.storageKey)
        ) == .addMargin
        let availability = Gate2NowPlayingCommandAvailability(snapshot: snapshot, headphoneDoublePressAddsMargin: addsMargin)
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
        center.changePlaybackRateCommand.supportedPlaybackRates = SpeechRateRule.supportedMultipliers.map { NSNumber(value: $0) }
        #endif
    }

    func end() {
        #if canImport(MediaPlayer)
        if ownsNowPlayingInfo {
            NowPlayingInfoOwnership.shared.clear(as: .compactControls, detail: "end")
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
        center.changePlaybackRateCommand.supportedPlaybackRates = SpeechRateRule.supportedMultipliers.map { NSNumber(value: $0) }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.preferredIntervals = [15]
        register(center.playCommand, command: .play, detail: "none")
        register(center.pauseCommand, command: .pause, detail: "none")
        register(center.togglePlayPauseCommand, command: .togglePlayPause, detail: "none")
        register(center.skipBackwardCommand, command: .skipBack, detail: "15s")
        register(center.skipForwardCommand, command: .skipForward, detail: "15s")
        register(center.stopCommand, command: .pause, detail: "none")
        let nextTrackTarget = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastRemoteCommand = "nextTrack"
                self?.lastRemoteCommandDetail = "none"
                self?.nextTrackHandler?()
            }
            return .success
        }
        remoteCommandTargets.append((center.nextTrackCommand, nextTrackTarget))
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
            try PlaybackAudioSessionPolicy.ensurePlaybackCategory(options: [], session: session)
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
