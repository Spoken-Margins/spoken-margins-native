#if canImport(BackgroundTasks) && canImport(UIKit)
import BackgroundTasks
import Foundation

import SessionKit

@MainActor
final class AudioPreparationBackgroundController {
    static let shared = AudioPreparationBackgroundController()
    static let identifier = "com.spokenmargins.native.audio-preparation"

    private var work: (() async -> BackgroundPreparationWorkResult)?
    private var drainEnded: (@MainActor () -> Void)?
    private var registered = false

    private init() {}

    /// Builds up to 35 asked iOS for a "Preparing audio for offline listening" progress card, which
    /// ended as failed every time (#2694). The card is gone; a request such an install left queued
    /// is dropped here so iOS never launches the app for it.
    private static let retiredContinuedIdentifier = "com.spokenmargins.native.audio-preparation.continued"

    func register() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.retiredContinuedIdentifier)
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            // The launch closure inherits this controller’s MainActor isolation.
            // BGTaskScheduler uses a background queue when this argument is nil.
            using: .main
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                await self?.handle(processingTask)
            }
        }
    }

    /// `drainEnded` runs whenever a background task stops working, finished or expired,
    /// so the foreground loop can take over the work the task held (#534).
    func install(
        work: @escaping () async -> BackgroundPreparationWorkResult,
        drainEnded: @escaping @MainActor () -> Void
    ) {
        self.work = work
        self.drainEnded = drainEnded
    }

    func submitIfEnabled(_ enabled: Bool) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
        guard enabled else { return }
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Submission is opportunistic. Durable jobs remain the source of
            // truth and are retried on the next foreground transition.
        }
    }

    private func handle(_ task: BGProcessingTask) async {
        guard let work else {
            task.setTaskCompleted(success: false)
            return
        }
        let operation = Task { await Self.drain(work: work) }
        task.expirationHandler = Self.expirationHandler(for: operation)
        let result = await operation.value
        drainEnded?()
        task.setTaskCompleted(success: !operation.isCancelled)
        if result.hasRemainingWork || operation.isCancelled {
            submitIfEnabled(true)
        }
    }

    // BGTask can invoke expiration off the main actor. Construct the callback
    // outside actor isolation; cancellation itself is thread-safe.
    nonisolated static func expirationHandler(
        for operation: Task<BackgroundPreparationWorkResult, Never>
    ) -> @Sendable () -> Void {
        { operation.cancel() }
    }

    static func drain(
        work: () async -> BackgroundPreparationWorkResult
    ) async -> BackgroundPreparationWorkResult {
        var result = await work()
        while result == .continueNow, !Task.isCancelled {
            await Task.yield()
            result = await work()
        }
        return result
    }
}
#endif
