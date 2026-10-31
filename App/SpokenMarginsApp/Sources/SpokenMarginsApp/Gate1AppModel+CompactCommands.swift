import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitSharing
import SessionKitSupertonic
import SessionKitPersistence
import SessionKitFeeds
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Commands from compact surfaces: the Live Activity, widgets and compact URLs (#1022).
extension Gate1AppModel {
    func dispatchGate2CompactCommand(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) {
        // A headphone double-press (next track) adds a Margin, or skips forward by the listener's setting (#2031).
        // Skip forward from the Lock Screen or the screen never reaches this branch.
        if command == .skipForward, origin.hasSuffix(HeadphoneRemoteSignal.nextTrackOriginSuffix) {
            let setting = HeadphoneDoublePressAction(
                storedValue: UserDefaults.standard.string(forKey: HeadphoneDoublePressAction.storageKey)
            )
            let decision = HeadphoneDoublePressPolicy.decide(
                signal: .nextTrack, setting: setting, isRecording: snapshot.isRecording
            )
            recordDeveloperDiagnostic("transport.headphone_double_press", [
                "setting": setting.rawValue, "decision": String(describing: decision), "origin": origin,
            ])
            if decision == .startMargin {
                // The same start path as the on-screen Add a Margin, so permission and ownership checks apply.
                dispatchGate2CompactCommand(.beginInterjection, origin: origin)
                return
            }
            // End and skip decisions are the ordinary skip-forward command, which the recording branch below ends.
        }
        // A headphone click, car button or Lock Screen play/pause while a Margin records ends it (#1030).
        // Only from Now Playing: a stale queued widget command must not save a Margin. A save already
        // under way from the screen is not asked twice. Bluetooth headphones switching to the hands-free
        // profile for the microphone send a `play` nobody pressed, so one in the first moment of a recording
        // or just after the route changed is logged and ignored (#1708). A bare `play` on a hands-free input is
        // that profile's noise at any time, so it never ends a Margin (#2182).
        if snapshot.isRecording, command.endsRecordingMargin, origin.hasPrefix("now_playing") {
            guard !isFinishingInterjection else { return }
            let recordingMs = captureWatcher.elapsedMs
            let sinceRouteChangeMs = captureWatcher.msSinceRouteChange
            let onHandsFree = recordingInputIsBluetoothHandsFree
            // Where the command arrived, so a false end can be told from a real one in the export (#2182).
            let context: [String: String] = [
                "command": command.rawValue,
                "origin": origin,
                "recordingMs": String(recordingMs),
                "sinceRouteChangeMs": sinceRouteChangeMs.map(String.init) ?? "none",
                "handsFreeInput": onHandsFree ? "true" : "false",
                "appState": Gate2AppState.isInBackground() ? "background" : "foreground",
                "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
            ]
            let verdict = RecordingTransportGuard.verdict(
                command: command, recordingMs: recordingMs, sinceRouteChangeMs: sinceRouteChangeMs, onHandsFreeProfile: onHandsFree
            )
            if case .ignore(let reason) = verdict {
                recordDeveloperDiagnostic("transport.ignored_during_recording", context.merging(["reason": reason.rawValue]) { $1 })
                return
            }
            recordDeveloperDiagnostic("transport.ends_margin", context)
            performGate2CompactCommand(.finishInterjection, origin: origin)
            return
        }
        if command == .beginInterjection {
            guard !recordingNavigationIsLocked else { return }
            let request = marginCapture.beginCompactRequest()
            microphoneAccess.recordFromCompactControl(ask: { [weak self] in await self?.requestMicrophonePermission() ?? false }) { [weak self] granted in
                guard let self else { return }
                // Cancelled in the app, or overtaken by a newer request, while iOS asked: start nothing (#2126).
                guard marginCapture.isCurrentCompactRequest(request) else { return }
                if granted { performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin) }
                marginCapture.endCompactRequest()
                if !granted { reportFailure("Microphone access is required to record Margins from compact controls.") }
            }
            return
        }
        performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
    }

    func compactSkipUnit(for command: CompactControlCommand) -> String? {
        guard isMediaPlaybackSnapshot else { return nil }
        switch command {
        case .skipBack:
            return mediaSkipUnit(seconds: mediaSkipBackSeconds)
        case .skipForward:
            return mediaSkipUnit(seconds: mediaSkipForwardSeconds)
        default:
            return nil
        }
    }

    /// A card tap drawn before the state moved on: Play on a playing source, Pause on a paused one. Nothing to do,
    /// and nothing failed, so no "Compact control failed" (#2965).
    func noteCompactCommandNoOp(_ command: CompactControlCommand, origin: String, result: CompactControlResult) {
        recordDeveloperDiagnostic("transport.no_op", ["command": command.rawValue, "origin": origin, "reason": result.rejectedReason ?? ""])
    }

    /// The Margin is recording from a Bluetooth headset's hands-free port (#2182).
    private var recordingInputIsBluetoothHandsFree: Bool {
        #if canImport(AVFoundation) && os(iOS)
        AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
        #else
        false
        #endif
    }

    func handleGate2CompactURL(_ url: URL) {
        guard let rawCommand = Gate2CompactCommandURL.command(from: url) else {
            reportFailure("Unsupported compact control URL.")
            return
        }
        guard let command = CompactControlCommand(rawValue: rawCommand) else {
            if !handleGate2CompactApplicationCommand(
                rawCommand,
                targetID: Gate2CompactCommandURL.chapterId(from: url)
            ) {
                reportFailure("Unsupported compact control URL.")
            }
            return
        }
        dispatchGate2CompactCommand(
            command,
            chapterId: Gate2CompactCommandURL.chapterId(from: url),
            origin: "compact_url"
        )
    }

    @discardableResult
    func handleGate2CompactApplicationCommand(_ command: String, targetID: String? = nil) -> Bool {
        switch command {
        case Gate2CompactApplicationCommand.summarizeInterjections:
            guard gate2CompactSnapshot?.availableCommands.contains(.generateInterjectionSummary) == true else {
                reportFailure("Summary is unavailable for the current compact surface state.")
                return false
            }
            summarize()
            return true
        case Gate2CompactApplicationCommand.discussInterjections:
            guard gate2CompactSnapshot?.availableCommands.contains(.submitFollowup) == true else {
                reportFailure("Discuss is unavailable for the current compact surface state.")
                return false
            }
            reportFailure("Discuss is disabled in this release. Copy your notes to another chatbot and paste its response back here instead.")
            return true
        case Gate2CompactApplicationCommand.listenToSharedMargin:
            guard pendingImportedCommentary != nil else { return false }
            listenToPendingImportedCommentary()
            screen = .playback
            return true
        case Gate2CompactApplicationCommand.dismissSharedMargin:
            guard pendingImportedCommentary != nil else { return false }
            dismissPendingImportedCommentary()
            return true
        case Gate2CompactApplicationCommand.jumpToSharedMargin:
            guard let targetID, !targetID.isEmpty else { return false }
            return jumpToImportedCommentary(interjectionID: targetID)
        case Gate2CompactApplicationCommand.openPlayback:
            return openPlaybackFromLiveActivity()
        default:
            reportFailure("Unsupported compact application command.")
            return false
        }
    }

    /// The Live Activity card was tapped while it showed playback. What the card shows is the app's own session, so
    /// a session in the snapshot opens straight to its playback screen. With none, the card is stale or the snapshot
    /// lost its session: say so instead of silently showing the Library (#1337). Both outcomes are handled, so the
    /// URL router doesn't add "Unsupported compact control URL." over the message. The record names no item.
    private func openPlaybackFromLiveActivity() -> Bool {
        let screenBefore = String(describing: screen)
        let narrationBefore = PlaybackDiagnosticFields.narrationIsPlaying(narrationDiagnostics())
        reconcileNarrationOwnership(trigger: "live_activity_tap")
        if hasActiveSession { openPlayback() } else { reportFailure("Nothing is playing right now.") }
        recordDeveloperDiagnostic("liveActivity.tap", [
            "outcome": screen == .playback && hasActiveSession ? "opened_playback" : (hasActiveSession ? "not_opened" : "no_session"),
            "narrationClientPlaying": String(narrationBefore),
            "screenBefore": screenBefore,
        ])
        return true
    }
}
