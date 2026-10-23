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

/// Ending and closing the current session (#990), moved unchanged out of the central model.
extension Gate1AppModel {
    func endSession() {
        guard !rejectNavigationOrSessionMutationWhileRecording("end_session") else { return }
        closeCurrentSession(navigateHome: true)
    }

    func dismissMiniPlayer() {
        recordDeveloperDiagnostic("miniPlayer.close")
        guard !rejectNavigationOrSessionMutationWhileRecording("dismiss_mini_player") else {
            recordMiniPlayerCloseOutcome("blocked_recording")
            return
        }
        guard !isDismissingMiniPlayer else {
            recordMiniPlayerCloseOutcome("already_dismissing")
            return
        }
        recordMiniPlayerCloseOutcome("accepted")
        isDismissingMiniPlayer = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.closeCurrentSession(navigateHome: false)
            self.isDismissingMiniPlayer = false
        }
    }

    private func closeCurrentSession(
        navigateHome: Bool,
        successMessage: String = "Session saved. You can resume it later."
    ) {
        cancelSkimBridge(restoringOrigin: true, resumeSource: false)
        let closedItemId = snapshot.itemId ?? activeItemId
        run { engine in
            snapshot = try endEngineSession(engine, reason: navigateHome ? .doneButton : .miniPlayerClose)
            activeItemId = SessionCloseSelection.itemId(closing: closedItemId, pageOnScreen: screen == .item ? selectedItem.id : nil, navigatesHome: navigateHome)
            refreshSelectedItemInBackground()
            refreshLibraryRowsInBackground()
            reportConfirmation(successMessage)
        }
        streamingSpeechQueue.stopAndClear()
        gate2CompactControls.endLiveActivities()
        resetMixWithOtherAudioForNewSession()
        unloadNarrationRenderers()
        if navigateHome {
            screen = .home
        }
    }
}
