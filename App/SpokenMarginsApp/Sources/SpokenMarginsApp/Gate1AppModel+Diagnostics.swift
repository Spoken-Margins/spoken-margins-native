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

@MainActor
final class RuntimeDiagnostics: ObservableObject {
    @Published var values: [String: String] = [:]
}

extension Gate1AppModel {
    var diagnostics: [String: String] {
        get { runtimeDiagnostics.values }
        set { if runtimeDiagnostics.values != newValue { runtimeDiagnostics.values = newValue } }
    }

    func recordDeveloperDiagnostic(_ kind: String, _ fields: [String: String] = [:]) {
        developerRecording.record(kind, fields)
        // High-frequency samples and rendering events must not erase transport history.
        if kind != "sample", !kind.hasPrefix("preparation."),
           !kind.hasPrefix("scrub."), kind != "main.delayed" {
            playbackEventRecording.record(kind, fields)
        }
    }

    func recordPlaybackEventState(previous: SessionSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        let changed = previous.status != snapshot.status || previous.targetId != snapshot.targetId
            || previous.lastFailure != snapshot.lastFailure
        guard changed || (snapshot.status.isPlaybackActive && now - lastPlaybackEventCheckpoint >= 30) else { return }
        lastPlaybackEventCheckpoint = now
        playbackEventRecording.record("playback.state", DeveloperDiagnosticRecording.playbackStateFields(
            snapshot, player: (speechPlaybackClient as? SupertonicSpeechPlaybackClient)?.playerDiagnostics() ?? [:]
        ))
    }

    func configureDeveloperDiagnosticRecording() {
        developerDiagnosticTask?.cancel()
        guard developerDiagnosticRecordingEnabled else {
            developerRecording.stop()
            return
        }
        developerRecording.start()
        developerDiagnosticTask = Task { @MainActor [weak self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.recordDeveloperSample(intervalMs: Int((now - previous) * 1000))
                previous = now
            }
        }
    }

    private func recordDeveloperSample(intervalMs: Int) {
        let row = libraryItems.first { $0.id == selectedItem.id }
        let fields: [String: String] = [
            "item": DeveloperDiagnosticRecording.token(snapshot.itemId),
            "selected": DeveloperDiagnosticRecording.token(selectedItem.id),
            "target": DeveloperDiagnosticRecording.token(snapshot.targetId),
            "screen": String(describing: screen),
            "status": snapshot.status.rawValue,
            "textOffset": String(snapshot.currentTextStart ?? 0),
            "generation": onDeviceSpeechGenerationStatus,
            "generatedChunks": String(onDeviceSpeechGenerationProgress.completedChunks),
            "totalChunks": String(onDeviceSpeechGenerationProgress.totalChunks),
            "openingState": String(describing: row?.startupAudioState),
            "openingChunks": String(row?.startupAudioCompletedChunkCount ?? 0),
            "openingTarget": String(row?.startupAudioTargetChunkCount ?? 0),
            "workerActive": String(foregroundAudioPreparationTask != nil),
            "canPrepare": String(canPrepareLibraryAudio),
            "queueCount": String(audioPreparationQueue.count),
            "lowPower": String(ProcessInfo.processInfo.isLowPowerModeEnabled),
            "thermal": String(ProcessInfo.processInfo.thermalState.rawValue),
            "intervalMs": String(intervalMs)
        ]
        recordDeveloperDiagnostic("sample", fields)
        #if canImport(UIKit)
        if intervalMs > 1000, UIApplication.shared.applicationState == .active {
            recordDeveloperDiagnostic("main.delayed", ["intervalMs": String(intervalMs)])
        }
        #endif
    }

    func dismissError() {
        lastError = nil
        if feedbackEvent?.kind == .error {
            feedbackEvent = nil
        }
        if statusMessage == "Error" {
            statusMessage = "Ready."
        }
    }

    func dismissFeedback(id: UUID? = nil) {
        guard id == nil || feedbackEvent?.id == id else { return }
        feedbackEvent = nil
    }

    func clearLastFailure(itemId: String) { itemFailures.clear(itemId: itemId) }

    /// Trying an action again answers its Retry banner, so a stale one can't linger over the result.
    func withdrawRetryOffer(_ key: String) { if feedbackEvent?.retry?.key == key { feedbackEvent = nil } }

    func updatePendingAutoPlayDiagnostics(reason: String) {
        diagnostics["pendingAutoPlayTurnId"] = pendingAutoPlayQueue.first
        diagnostics["pendingAutoPlayQueue"] = "\(pendingAutoPlayQueue.count)"
        diagnostics["pendingAutoPlayReason"] = reason
    }

    func refreshDiagnostics() {
        run { engine in
            diagnostics = try engine.diagnostics()
            diagnostics["providerProbe"] = providerProbeStatus
            diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
            settingsValueChanged()
            diagnostics["streamingSpeechPending"] = "\(streamingSpeechQueue.pendingCount)"
            if let structure = selectedItem.documentStructure {
                recordPDFExtractionDiagnostics(structure)
            }
            refreshImportInbox()
            reportSuccess("Diagnostics refreshed.")
        }
    }

    func copyDiagnosticsExport() {
        var safe = diagnostics
            .filter { !Self.diagnosticKeyMayContainUserContent($0.key) }
            .mapValues(Self.redactedDiagnosticValue)
        if let store {
            let stored = PodcastAnchorCaptureDiagnostics.exportEntries(
                sessions: (try? store.loadSessions()) ?? [],
                interjections: { try store.loadInterjections(sessionId: $0) }
            )
            safe.merge(stored.mapValues(Self.redactedDiagnosticValue)) { _, stored in stored }
        }
        safe["developerBuild"] = developerDiagnosticBuild
        safe["developerRecording"] = developerRecording.exportJSON()
        safe["playbackEvents"] = playbackEventRecording.exportJSON()
        safe["schemaVersion"] = "spoken-margins.diagnostics.v1"
        safe["exportedAt"] = ISO8601DateFormatter().string(from: Date())
        safe["playbackStatus"] = snapshot.status.rawValue
        safe["sessionPhase"] = snapshot.phase.rawValue
        safe["targetType"] = snapshot.targetType ?? "none"
        safe["pendingAIJobs"] = "\(snapshot.pendingAiJobCount)"
        do {
            let data = try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else { return }
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportConfirmation("Copied privacy-safe diagnostics.")
            #else
            exportPreview = text
            reportSuccess("Built privacy-safe diagnostics.")
            #endif
        } catch {
            reportFailure(error, context: "Diagnostics export failed")
        }
    }

    private static func redactedDiagnosticValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"https?://[^\s]+"#, with: "<redacted-url>", options: .regularExpression)
            .replacingOccurrences(of: #"/(?:private|Users|var)/[^\s]+"#, with: "<redacted-path>", options: .regularExpression)
    }

    private static func diagnosticKeyMayContainUserContent(_ key: String) -> Bool {
        [
            "lastStatus",
            "recentFailure",
            "quickAccessFolder",
            "lastSourceLinkClipboardPaste",
            "lastBrowserTextSource"
        ].contains(key)
    }

    func markProviderFailure(_ error: String, userMessage: String, retry: UserFeedbackEvent.Retry? = nil) {
        do {
            if let engine {
                snapshot = try engine.aiProviderFailed(error: error)
                refreshSelectedItem()
            }
        } catch {
            diagnostics["providerFailurePersistence"] = String(describing: error)
        }
        providerProbeStatus = userMessage
        diagnostics["providerProbe"] = providerProbeStatus
        reportFailure(userMessage, retry: retry)
    }

    func reportSuccess(_ message: String) {
        statusMessage = message
        lastError = nil
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    /// Records a successful outcome and presents it only when the result is not
    /// otherwise apparent from the current interface.
    func reportConfirmation(_ message: String) {
        reportSuccess(message)
        presentFeedback(UserFeedbackEvent(kind: .success, message: message))
    }

    /// Presents degraded-but-successful behavior without styling it as either a
    /// normal confirmation or a failure.
    func reportWarning(_ message: String) {
        statusMessage = message
        lastError = nil
        presentFeedback(UserFeedbackEvent(kind: .warning, message: message))
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    func reportFailure(_ error: Error, context: String? = nil, itemId: String? = nil, retry: UserFeedbackEvent.Retry? = nil) {
        let message: String
        if let urlError = error as? URLError {
            message = Self.userFacingMessage(for: urlError)
        } else if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            message = description
        } else {
            message = String(describing: error)
        }
        reportFailure([context, message].compactMap { $0 }.joined(separator: ": "), itemId: itemId, retry: retry)
    }

    func reportFailure(_ message: String, itemId: String? = nil, retry: UserFeedbackEvent.Retry? = nil) {
        statusMessage = "Error"
        lastError = message
        presentFeedback(UserFeedbackEvent(kind: .error, message: message, retry: retry))
        // The failure stays readable on its item: the one named, else the one on screen (#310).
        itemFailures.record(message, itemId: itemId ?? (screen == .item ? selectedItem.id : screen == .playback ? snapshot.itemId ?? "" : ""))
        diagnostics["recentFailure"] = message
    }

    func presentFeedback(_ event: UserFeedbackEvent) {
        guard feedbackEvent?.mayBeReplaced(by: event) ?? true else { return }
        feedbackEvent = event
    }
}
