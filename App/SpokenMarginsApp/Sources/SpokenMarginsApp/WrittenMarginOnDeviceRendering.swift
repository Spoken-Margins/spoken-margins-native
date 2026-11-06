import Foundation
import SessionKit
import SessionKitAudio
import SessionKitSupertonic

/// The app's side of reading a friend's written Margin in the listener's chosen on-device voice (#3391). The decision
/// is `WrittenMarginVoiceChoice` and the render-then-file, time budget, fallback and skip are `WrittenMarginReader`
/// (SessionKitAudio), both host-tested. This file only reads the facts the choice needs and hands the reader a render.
///
/// Memory: no model of its own. Supertonic's renderer is the one the model already caches (`makeSupertonicRenderer`), a
/// downloaded voice's is the one `SharedDownloadedRenderers` shares with the player and Prepare (weak: nothing here
/// keeps it loaded), and the reader never starts a second on-device render while a late one still holds the voice.
@MainActor
enum WrittenMarginOnDeviceRendering {
    /// The chosen on-device voice as it can be seen from the main thread with no disk and no model: just which voice it is,
    /// or nil when none is chosen (the iPhone voice, Kitten) or this build has no renderer for it. Whether its files are on
    /// the phone and whether the heat, memory and power governor allows it are asked of every voice alike on the render's
    /// own thread (`WrittenMarginOnDeviceStage.isAllowed`), so a missing or blocked voice gives the reading to the iPhone
    /// voice there.
    static func candidate(for selection: AppTTSVoiceSelection, model: Gate1AppModel) -> WrittenMarginVoiceChoice.Candidate? {
        if let voice = selection.supertonicVoice {
            return .init(key: "supertonic-\(voice.rawValue)", isInstalled: true, allowedNow: true)
        }
        guard selection.choice.downloadedVoiceId != nil, DownloadedVoiceRegistry.descriptor(for: selection.choice) != nil else { return nil }
        return .init(key: "downloaded-\(selection.rawValue)", isInstalled: true, allowedNow: true)
    }

    /// The reader's on-device stage for `selection`. Its checks and its render run on a background thread and take what
    /// they need from the main actor only at that moment, so building the stage costs nothing.
    static func stage(for selection: AppTTSVoiceSelection, key: String, model: Gate1AppModel) -> WrittenMarginOnDeviceStage {
        WrittenMarginOnDeviceStage(
            key: key,
            isAllowed: { [weak model] in
                // The same block the player obeys (`OnDeviceVoiceEngine.renderingAllowed`): model present, chip and memory fit
                // for a downloaded voice, and the governor's heat, memory and power. Asked off the main thread: it reads the disk.
                guard let model, let plan = try? onMain({ try makePlan(for: selection, model: model) }) else { return false }
                return plan.allowed()
            },
            render: { [weak model] text, _, cancel in
                guard let model else { throw CancellationError() }
                let plan = try onMain { try makePlan(for: selection, model: model) }
                let renderer = try onMain { try plan.renderer() }
                return try renderSynchronously(renderer, text: text, voice: selection.supertonicVoice ?? .m2, cancel: cancel)
            }
        )
    }

    /// What reading in `selection`'s voice needs, gathered on the main actor without running the model. Checks the Terms again.
    private struct Plan: Sendable {
        let allowed: @Sendable () -> Bool
        let renderer: @MainActor @Sendable () throws -> any SupertonicRendering
    }

    private static func makePlan(for selection: AppTTSVoiceSelection, model: Gate1AppModel) throws -> Plan {
        try model.verifyCurrentTermsForOnDeviceVoice()
        if selection.supertonicVoice != nil {
            return Plan(
                allowed: model.supertonicModel.renderingAllowed(when: SupertonicModelNotDownloaded.governorAllowsRendering),
                renderer: { [weak model] in
                    guard let model else { throw CancellationError() }
                    return try model.makeSupertonicRenderer() // the model's cached renderer: no second copy
                }
            )
        }
        guard let descriptor = DownloadedVoiceRegistry.descriptor(for: selection.choice),
              let registration = descriptor.registration,
              let supportDirectory = try? model.applicationSupportDirectory() else { throw WrittenMarginOnDeviceError.notAvailable }
        let engine = OnDeviceVoiceEngines.downloaded(
            descriptor, registration: registration, supportDirectory: supportDirectory,
            deviceChipGeneration: model.preparationSeams.deviceChipGeneration,
            renderer: SharedDownloadedRenderers.shared.renderer(for: descriptor, registration: registration, supportDirectory: supportDirectory)
        )
        return Plan(allowed: engine.renderingAllowed, renderer: { engine.renderer })
    }

    enum WrittenMarginOnDeviceError: Error { case notAvailable }

    /// Runs the async render and waits on this background thread, stopping it at its next step when `cancel` is set.
    nonisolated private static func renderSynchronously(_ renderer: any SupertonicRendering, text: String, voice: SupertonicVoiceID, cancel: RenderCancellation) throws -> URL {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            do { box.set(.success(try await renderer.render(text: text, voice: voice, language: "en", speed: 1, synthesisSteps: 8))) } catch { box.set(.failure(error)) }
            done.signal()
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            if cancel.isCancelled { task.cancel() }
        }
        return try box.get().audioURL
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<SupertonicNarrationResult, Error>?
        func set(_ value: Result<SupertonicNarrationResult, Error>) { lock.withLock { result = value } }
        func get() throws -> SupertonicNarrationResult { try lock.withLock { result }!.get() }
    }

    private final class MainBox<T: Sendable>: @unchecked Sendable {
        var result: Result<T, Error>?
    }

    /// Runs `work` on the main actor and waits for it from this background thread. The main thread never waits on the
    /// reader, so this cannot deadlock.
    nonisolated private static func onMain<T: Sendable>(_ work: @MainActor @Sendable @escaping () throws -> T) throws -> T {
        let box = MainBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.result = Result { try work() }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }
}
