#if canImport(BackgroundTasks) && canImport(UIKit)
import BackgroundTasks
import Foundation

enum BackgroundPreparationWorkResult: Equatable {
    case finished
    case continueNow
    case retryLater

    var hasRemainingWork: Bool { self != .finished }
}

@MainActor
final class AudioPreparationBackgroundController {
    static let shared = AudioPreparationBackgroundController()
    static let identifier = "com.spokenmargins.native.audio-preparation"

    private var work: (() async -> BackgroundPreparationWorkResult)?
    private var registered = false

    private init() {}

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: nil
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

    func install(work: @escaping () async -> BackgroundPreparationWorkResult) {
        self.work = work
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
        task.expirationHandler = { operation.cancel() }
        let result = await operation.value
        task.setTaskCompleted(success: !operation.isCancelled)
        if result.hasRemainingWork && !operation.isCancelled {
            submitIfEnabled(true)
        }
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
