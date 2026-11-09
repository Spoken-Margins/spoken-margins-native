import Foundation
import SessionKit
import SessionKitPersistence

/// The model's face to `TextSceneMapPreparer` (#3450): what it tells the listener when a run ends.
extension Gate1AppModel: TextSceneMapPreparerHost {
    func textSceneSummariesDidFinish(
        itemId: String, outcome: TextSceneSummaryOutcome, policy: PreparationJobPolicy, progressed: Bool
    ) {
        diagnostics["textSceneSummaries:\(itemId)"] = outcome.diagnostic
        // A run that saved scenes ended in any way (a tap, the charging pass, heat, iOS's cut-off) clears the item's
        // stop count, so a long PDF that advances between stops is never dropped for the stops in between.
        let stoppedByModel: Bool
        if case .modelStopped = outcome { stoppedByModel = true } else { stoppedByModel = false }
        let tooManyStops = TextSceneBackgroundMemo.noteRun(
            itemId, progressed: progressed, modelStopped: stoppedByModel && policy == .whileCharging
        )
        // The background pass settles an item once a run ended on it for good, so a charge isn't spent on it again.
        // An error that never clears (the model stopped it several windows in a row with nothing saved) must not hold
        // the pass on one item while the ones behind it wait. The listener's tap still works.
        if policy == .whileCharging, outcome.settlesBackgroundRun || tooManyStops {
            TextSceneBackgroundMemo.settle(itemId)
        }
        guard itemId == activeItemId else { return }
        // A paused or cancelled run saved the scenes it had written, so the screen and Skim read them now (#3461).
        switch outcome {
        case .summarised, .paused, .audioPaused, .modelStopped, .cancelled, .keptOtherMap, .failed:
            refreshSelectedItemInBackground()
            updateSkimAvailability()
        case .nothingToSummarise, .noSummaryAccepted:
            break
        }
        objectWillChange.send()
        if case .cancelled = outcome { return }
        if policy == .whileCharging { return } // a background run doesn't speak up on whatever the listener is doing
        reportConfirmation(outcome.message)
    }
}

extension Gate1AppModel {
    func generateListeningMap() {
        guard beginListeningMapGeneration() else { return }
        generateLocalListeningMap(confirmation: "Generated Listening Map.")
        isGeneratingListeningMap = false
    }

    /// The Prepare Listening Map tap (#2256): the same request with the item's load, its chapter cutting and the save
    /// off the main thread, which took 787 ms on a 1.1 MB book. `isGeneratingListeningMap` holds the button until it ends.
    func generateListeningMapFromTap() {
        guard beginListeningMapGeneration() else { return }
        Task {
            await generateLocalListeningMapOffMain(confirmation: "Generated Listening Map.")
            isGeneratingListeningMap = false
            // A transcript that finished during the wait asked for its map while this one held the flag: it is made now.
            if let pending = pendingMapGenerationItemId, pending == activeItemId {
                pendingMapGenerationItemId = nil
                generateListeningMap()
            }
        }
    }

    /// The checks both entry points share. True when a local map is to be made now, with `isGeneratingListeningMap` set
    /// for the caller to clear; false when the request ended here (already generating, already has a map, an episode
    /// that goes to the episode map, or a source that has no on-device map).
    func beginListeningMapGeneration() -> Bool {
        guard !isGeneratingListeningMap else { return false }
        guard selectedItem.chapters.isEmpty, selectedItem.mediaChapters.isEmpty else {
            reportSuccess("This \(selectedItem.sourceNoun.inSentence) already has a Listening Map.")
            return false
        }
        isGeneratingListeningMap = true
        let selectedItemRecord = try? store?.loadItemSummary(id: activeItemId)
        if let item = selectedItemRecord,
           item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream {
            isGeneratingListeningMap = false
            prepareEpisodeMap(itemId: item.id, policy: .explicit)
            return false
        }
        guard selectedItemRecord?.media == nil else {
            diagnostics["lastListeningMapMode"] = "on_device_generation_disabled"
            isGeneratingListeningMap = false
            reportFailure("Publisher chapters appear when available. AI-generated podcast maps are reserved for a future server-hosted option.")
            return false
        }
        return true
    }

    /// Prepare Listening Map on an article or PDF: the rule-based chapters first, then the on-device model writes each
    /// scene's summary for Skim, or the listener is told it can't and keeps the chapters (#3450). Moved from the
    /// model unchanged except for that last step.
    func generateLocalListeningMap(confirmation: String) {
        let itemId = activeItemId
        run { engine in
            snapshot = try engine.generateListeningMap(itemId: itemId)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
            }
            finishLocalListeningMap(itemId: itemId, confirmation: confirmation)
        }
    }

    /// The same map with its store work off the main thread (#2256): the item is loaded, cut into chapters and saved
    /// by `ListeningMapGenerationPersister`, and only the engine half and the screen updates run here. With no engine
    /// yet, or one that cannot generate, it takes the synchronous path, which installs the engine or reports the failure.
    /// Everything after the wait uses the item the tap was made on, not whichever the listener has open by then.
    func generateLocalListeningMapOffMain(confirmation: String) async {
        let itemId = activeItemId
        guard let engine, let persister = try? engine.listeningMapGenerationPersister(itemId: itemId) else {
            generateLocalListeningMap(confirmation: confirmation)
            return
        }
        let generated: Result<GeneratedListeningMapResult, Error>
        do {
            generated = .success(try await Self.offMain { try persister.generate(itemId: itemId) })
        } catch {
            generated = .failure(error)
        }
        hangTelemetry.labels.scoped("listeningMapGenerate") {
            _ = run { engine in
                snapshot = try engine.generateListeningMap(try generated.get())
                refreshLibraryRowsInBackground(mustPublish: true) // #2505, as a finished transcript does
                finishLocalListeningMap(itemId: itemId, confirmation: confirmation)
            }
        }
    }

    private func finishLocalListeningMap(itemId: String, confirmation: String) {
        refreshSelectedItemInBackground()
        diagnostics["lastGeneratedMapItem"] = itemId
        diagnostics["lastListeningMapMode"] = "local_deterministic"
        schedulePrewarmAfterPreparedTextChange(itemId: itemId)
        reportConfirmation("\(confirmation) \(textSceneMapPreparer.prepare(itemId: itemId).note)")
    }
}

extension Gate1AppModel {
    /// True while this item's scene summaries are being written.
    var isWritingSceneSummaries: Bool { textSceneMapPreparer.itemId == activeItemId }

    /// The item screen's button for an article or PDF that already has chapters: write the scene summaries, or continue
    /// after a run that failed, was cancelled, paused for heat, or was cut off (#3461). Saved scenes are kept.
    func writeSceneSummaries() {
        reportConfirmation(textSceneMapPreparer.prepare(itemId: activeItemId).note)
        objectWillChange.send()
    }

    /// One article or PDF's scene summaries in the background pass, which iOS runs only on external power and which
    /// needs the While Charging setting for episode maps (#3461). Returns nil when there is nothing to do right now, so
    /// the pass goes on to its other work; otherwise how the pass went. Fetches nothing: the text is the item's own.
    func performBackgroundTextSceneSummaryPass() async -> BackgroundPreparationWorkResult? {
        guard automaticEpisodeMapPreparationPolicy == .whileCharging,
              let store,
              textSceneMapPreparer.task == nil,
              localFoundationModelAvailable,
              EpisodeMapRunGuard.yieldReason(conditions: episodeMapDeviceConditions(), policy: .whileCharging) == nil
        else { return nil }
        let ids = libraryItems.map(\.id)
        let settled = TextSceneBackgroundMemo.settled()
        let next = try? await Gate1AppModel.offMain {
            TextSceneSummaryCandidates.next(itemIds: ids, settled: settled, store: store)
        }
        guard let itemId = next ?? nil, case .started = textSceneMapPreparer.prepare(itemId: itemId, policy: .whileCharging),
              let task = textSceneMapPreparer.task else { return nil }
        let preparer = textSceneMapPreparer
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            // iOS ended the background time: the run stops at the next scene and keeps what it wrote.
            Task { @MainActor in preparer.cancel(itemId: itemId) }
        }
        // A run that ended for good moves on to the next item; one that stopped (heat, cancel, error) waits for the next pass.
        return TextSceneBackgroundMemo.settled().contains(itemId) ? .continueNow : .retryLater
    }
}

/// The items a background run has already ended on for good (finished, or nothing the model could summarise), kept so
/// the charging pass doesn't pick them again. The listener's own tap is not affected (#3461).
enum TextSceneBackgroundMemo {
    private static let key = "textSceneSummaries.backgroundSettled"

    static func settled(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private static let stopsKey = "textSceneSummaries.backgroundModelStops"
    /// How many model stops in a row that saved nothing settle an item for the background pass.
    static let modelStopLimit = 3

    /// Notes how a run ended. A run that saved scenes is progress, whatever stopped it: it clears the item's count
    /// (a long PDF needs several windows). A model stop with nothing saved adds one. True when that was the
    /// `modelStopLimit`th stop in a row with no progress, so an error that never clears can't hold the pass on one item.
    /// Scenes decided but never saved are not progress: the next run would ask about them again.
    static func noteRun(_ itemId: String, progressed: Bool, modelStopped: Bool, _ defaults: UserDefaults = .standard) -> Bool {
        var stops = defaults.dictionary(forKey: stopsKey) as? [String: Int] ?? [:]
        if progressed {
            stops[itemId] = nil
        } else if modelStopped {
            stops[itemId, default: 0] += 1
        }
        defaults.set(stops, forKey: stopsKey)
        return stops[itemId, default: 0] >= modelStopLimit
    }

    static func settle(_ itemId: String, _ defaults: UserDefaults = .standard) {
        defaults.set(Array(settled(defaults).union([itemId])).sorted(), forKey: key)
    }
}
