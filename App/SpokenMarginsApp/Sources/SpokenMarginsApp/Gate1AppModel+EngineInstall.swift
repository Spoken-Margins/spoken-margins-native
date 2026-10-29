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

/// Engine install and the compact-controls bridge (#961), moved unchanged out of the central model.
extension Gate1AppModel {
    func installEngine(_ engine: SessionEngine) {
        self.engine = engine
        engine.recordingDraftJournal = makeRecordingDraftJournal()
        // A saved podcast position that moves back by more than a minute, with the command that wrote it (#2186).
        engine.positionDiagnosticHandler = { [weak self] fields in
            Task { @MainActor [weak self] in self?.recordDeveloperDiagnostic("position.backward", fields) }
        }
        for record in podcastDownloadRecords.values where record.state == .availableOffline {
            guard let path = record.localRelativePath,
                  let url = try? applicationSupportDirectory()
                    .appending(path: "PodcastAudio", directoryHint: .isDirectory)
                    .appending(path: path) else { continue }
            _ = try? engine.updatePlaybackTransport(itemId: record.itemId, playbackURL: url.absoluteString)
        }
        configureGate2CompactControls(for: engine)
    }

    private func configureGate2CompactControls(for engine: SessionEngine) {
        do {
            let surfaceProfile = try loadProfile(id: "lock-screen-widget")
            gate2CompactControls.configure(
                canonicalRuntime: engine,
                surfaceProfile: surfaceProfile,
                skipUnit: mediaSkipUnit(seconds: mediaSkipForwardSeconds)
            ) { [weak self] command, origin, chapterId, mediaTimeMs, playbackRate in
                self?.dispatchGate2CompactCommand(
                    command,
                    chapterId: chapterId,
                    mediaTimeMs: mediaTimeMs,
                    playbackRate: playbackRate,
                    origin: origin
                )
            } applicationCommandHandler: { [weak self] command, targetID in
                self?.handleGate2CompactApplicationCommand(command, targetID: targetID) ?? false
            }
            gate2CompactControls.setNowPlayingEnabled(!mixesWithOtherAudio)
            updateGate2CompactState()
            diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
        } catch {
            diagnostics["gate2CompactSurface"] = "configuration_failed"
            diagnostics["gate2CompactError"] = String(describing: error)
        }
    }

    func updateGate2CompactState() {
        // The source Live Activity cannot describe the separate Margin player.
        // Its native Now Playing owner supplies transport until source restoration.
        guard playingImportedCommentary == nil else { return }
        let sharedMarginPrompt = pendingImportedCommentary.map {
            Gate2SharedMarginActivityPrompt(
                senderLabel: $0.senderLabel
            )
        }
        gate2CompactControls.update(
            snapshot: snapshot, sharedMarginPrompt: sharedMarginPrompt, upcomingSharedMargins: liveActivitySharedMarginNavigationEntries(),
            skimForwardDestinationMs: skimForwardDestinationMs, skimBackwardDestinationMs: skimBackwardDestinationMs // #115
        )
        let compactSnapshot = gate2CompactControls.snapshot
        if gate2CompactSnapshot != compactSnapshot {
            gate2CompactSnapshot = compactSnapshot
        }
        let compactDiagnostics = gate2CompactControls.diagnostics()
        if compactDiagnostics.contains(where: { diagnostics[$0.key] != $0.value }) {
            diagnostics.merge(compactDiagnostics, uniquingKeysWith: { _, new in new })
        }
    }

    /// Margins changed on the app's side: the Lock Screen card's timeline reads them again, not on every tick (#2505).
    func noteCompactTimelineChanged() {
        gate2CompactControls.noteMarginsChanged()
        updateGate2CompactState()
    }

    private func liveActivitySharedMarginNavigationEntries() -> [Gate2LiveActivityNavigationEntry] {
        let currentPercent = snapshot.sourceProgressPercent
        let mediaDurationMs = snapshot.currentPlaybackDurationMs ?? selectedItem.mediaDurationMs
        let textLength = selectedItem.text.count
        return importedCommentaryPrompts(includeAnnounced: false).compactMap { prompt in
            let positionPercent = SharedMarginPosition.percent(
                mediaTimeMs: prompt.interjection.resolution.localMediaTimeMs,
                mediaDurationMs: mediaDurationMs,
                charOffset: prompt.interjection.resolution.localStartChar,
                textLength: textLength
            )
            guard let positionPercent,
                  positionPercent > currentPercent else { return nil }
            return Gate2LiveActivityNavigationEntry(
                kind: .sharedMargin,
                title: "Shared Margin",
                targetID: prompt.interjection.id,
                positionPercent: min(100, max(0, positionPercent))
            )
        }
    }
}
