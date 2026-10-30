import Foundation
import SessionKit
import SessionKitPersistence

/// The model's face to `SkimBridgeController` (#954): the names views, tests and the other extensions call,
/// each forwarding to the controller, and the host the controller asks the model for.
extension Gate1AppModel {
    var skimForwardDestinationMs: Int? { skimBridge.forwardDestinationMs }

    var skimBackwardDestinationMs: Int? { skimBridge.backwardDestinationMs }

    var skimForwardTitle: String { PlaybackQualityPresentation.skimTitle(destinationMs: skimForwardDestinationMs, backward: false) }

    var skimBackwardTitle: String { PlaybackQualityPresentation.skimTitle(destinationMs: skimBackwardDestinationMs, backward: true) }

    #if DEBUG
    var skimAudioTransportRate: Float? { skimBridge.audioTransportRate }

    var skimResourceLoadCount: Int { skimBridge.resourceLoadCount }

    /// Returns once Skim's map and asset read has landed, which a refresh no longer waits for (#2943).
    func settleSkimResources() async { await skimBridge.settleResources() }

    func refreshSkimAvailabilityForTesting() { updateSkimAvailability() }
    #endif

    func updateSkimAvailability(refreshResources: Bool = true) {
        skimBridge.updateAvailability(refreshResources: refreshResources)
    }

    func resolvedSkimPlaybackPlan(
        direction: SkimDirection,
        at recipientMediaTimeMs: Int
    ) -> ResolvedSkimPlaybackPlan? {
        skimBridge.resolvedPlan(direction: direction, at: recipientMediaTimeMs)
    }

    func skimForward() {
        skimBridge.perform(direction: .forward)
    }

    func skimBackward() {
        skimBridge.perform(direction: .backward)
    }

    func startSkimBridge(_ plan: ResolvedSkimPlaybackPlan, continueAfterSummary: Bool = false) {
        skimBridge.start(plan, continueAfterSummary: continueAfterSummary)
    }

    func completeSkimBridge() {
        skimBridge.complete()
    }

    func setSkimBridgePaused(_ paused: Bool) {
        skimBridge.setPaused(paused)
    }

    func returnFromSkim() {
        cancelSkimBridge(restoringOrigin: true, resumeSource: true)
    }

    func cancelSkimBridge(restoringOrigin: Bool, resumeSource: Bool) {
        skimBridge.cancel(restoringOrigin: restoringOrigin, resumeSource: resumeSource)
    }

    func restoreSkimOriginBeforeCanonicalTransport() {
        if playingImportedCommentary != nil, heldMarginVoice?.kind != .shared { stopImportedCommentaryPlayback(resumeSource: false) } // Add a Margin holds the voice and moves the source under it (#1672)
        skimBridge.restoreOriginBeforeCanonicalTransport()
    }
}

extension Gate1AppModel: SkimBridgeHost {
    var skimBridgeState: SkimBridgeState? {
        get { snapshot.skimBridgeState }
        set { snapshot.skimBridgeState = newValue }
    }

    var skimAvailability: (forward: Bool, backward: Bool) {
        get { (snapshot.canSkimForward, snapshot.canSkimBackward) }
        set {
            // Two assignments, as before: each one runs the snapshot observer once.
            snapshot.canSkimForward = newValue.forward
            snapshot.canSkimBackward = newValue.backward
        }
    }

    var skimSourceIsPlaying: Bool { snapshot.status.isPlaybackActive }

    var skimCurrentMediaTimeMs: Int? { snapshot.currentMediaTimeMs }

    var skimSource: SkimSource? {
        guard isMediaPlaybackSnapshot, !snapshot.isRecording, store != nil else { return nil }
        return SkimSource(itemId: activeItemId, durationMs: snapshot.currentPlaybackDurationMs ?? selectedItem.mediaDurationMs)
    }

    var skimStore: SQLiteSessionStore? { store }

    var skimHasEngine: Bool { engine != nil }

    var skimMayStartSummary: Bool {
        !snapshot.isRecording && playingImportedCommentary == nil && playingInterjectionAudioId == nil
            && heldMarginVoice == nil && marginMomentConductor?.isPlayingVoice != true
    }

    var skimMediaPlaybackRate: Double { mediaPlaybackRate }

    func skimPauseEngine() throws {
        guard let engine else { return }
        snapshot = try engine.pause()
    }

    func skimResumeEngine() throws {
        guard let engine else { return }
        snapshot = try engine.resumePlayback()
    }

    func skimSeekOrStage(toMediaTimeMs mediaTimeMs: Int) throws {
        guard let engine else { return }
        marginMomentConductor?.sourceMoved() // the skim lands somewhere new; Margins it passed don't play (#1656)
        snapshot = try seekOrStageMedia(engine, toMediaTimeMs: mediaTimeMs)
    }

    func skimBridgeDidFinish() {
        refreshSelectedItemAfterTransport()
    }

    func skimEngineCallFailedWhileCancelling() {
        let current = snapshot
        snapshot = current // re-publish; a stored property rejects a bare self-assignment
    }

    func skimDestinationsWillChange() {
        objectWillChange.send()
    }

    func skimDestinationsChangedWithoutAvailabilityChange() {
        updateGate2CompactState()
    }

    func skimPrepareSummaryAudio(itemId: String, proposalId: String, scene: PortableListeningMapScene) async throws -> Bool {
        guard let store else { return false }
        return try await prepareSummaryBridgeAsset(itemId: itemId, proposalId: proposalId, scene: scene, store: store) != nil
    }

    func skimRecord(_ fields: [String: String]) {
        recordDeveloperDiagnostic("skim.press", fields)
    }

    func skimWarn(_ message: String) {
        reportWarning(message)
    }

    func skimSucceeded(_ message: String) {
        reportSuccess(message)
    }

    func skimConfirmed(_ message: String) {
        reportConfirmation(message)
    }

    func skimFailed(_ error: Error, context: String) {
        reportFailure(error, context: context)
    }
}
