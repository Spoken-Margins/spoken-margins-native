#if canImport(BackgroundTasks) && canImport(UIKit)
import BackgroundTasks
import Foundation
import SessionKit
import UIKit

/// Keeps an explicit Make available offline run going after the listener puts the phone down (#905).
///
/// iOS suspends an app seconds after it leaves the screen, which stopped a long preparation run
/// unless the listener kept the phone awake. A continued processing task is the system's way to say
/// "the listener started this and wants it finished": the process keeps running, the Lock Screen
/// and Dynamic Island show progress, and the listener can cancel it.
///
/// The task renders nothing itself. The app's own preparation loop does, as before, so there is
/// still one renderer, one heat gate and one queue. This controller asks iOS for the time, keeps
/// the task open while that loop runs, and reports the loop's progress.
@MainActor
final class ContinuedAudioPreparationController {
    static let shared = ContinuedAudioPreparationController()
    static let identifier = "com.spokenmargins.native.audio-preparation.continued"

    /// What the controller reads from the app model, and how it stops the loop.
    struct Hooks {
        /// The audio preparation queue, as a run reads it.
        var jobs: @MainActor () -> [OfflinePreparationRun.Job]
        /// True while the preparation loop is rendering or waiting out a heat pause.
        var isRunning: @MainActor () -> Bool
        var isCoolingDown: @MainActor () -> Bool
        /// Stops the loop. Queued jobs and committed chunks stay.
        var cancel: @MainActor () -> Void
        /// A short trail of what happened, for the diagnostics export.
        var report: @MainActor (String) -> Void
    }

    /// iOS starts a task it accepted within seconds. A request older than this never started, so
    /// a new one may be made.
    private static let staleRequestSeconds: TimeInterval = 120
    private static let pollSeconds = 1

    private var hooks: Hooks?
    private var registered = false
    private var requestedAt: Date?
    private var taskIsActive = false
    private var expired = false
    private var lastSubtitle: String?
    private var trail: [String] = []

    private init() {}

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            // The launch closure inherits this controller’s MainActor isolation.
            // BGTaskScheduler uses a background queue when this argument is nil.
            using: .main
        ) { task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                await self?.run(continuedTask)
            }
        }
    }

    func install(_ hooks: Hooks) {
        self.hooks = hooks
    }

    /// Called when the preparation loop starts. Asks iOS to keep the app running if the listener
    /// has a long run queued and the app is on screen.
    func requestIfNeeded() {
        guard let hooks else { return }
        let progress = OfflinePreparationRun.explicitProgress(hooks.jobs())
        let alreadyRequested = taskIsActive
            || requestedAt.map { Date().timeIntervalSince($0) < Self.staleRequestSeconds } == true
        guard OfflinePreparationRun.shouldRequestContinuedProcessing(
            progress,
            alreadyRequested: alreadyRequested,
            appIsActive: UIApplication.shared.applicationState == .active
        ) else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.identifier,
            title: OfflinePreparationRun.continuedTitle,
            subtitle: OfflinePreparationRun.continuedSubtitle(progress, phase: .preparing)
        )
        do {
            try BGTaskScheduler.shared.submit(request)
            requestedAt = Date()
            note("requested")
        } catch {
            // The run still goes on while the app is on screen, and the queue keeps its jobs.
            note("request_failed:\(error.localizedDescription)")
        }
    }

    private func run(_ task: BGContinuedProcessingTask) async {
        requestedAt = nil
        guard let hooks else {
            task.setTaskCompleted(success: false)
            return
        }
        taskIsActive = true
        expired = false
        lastSubtitle = nil
        trail.removeAll()
        note("started")
        task.expirationHandler = Self.expirationHandler { [weak self] in self?.handleExpiration() }
        while hooks.isRunning(), !expired {
            publish(to: task, hooks: hooks)
            try? await Task.sleep(for: .seconds(Self.pollSeconds))
        }
        publish(to: task, hooks: hooks)
        let finished = OfflinePreparationRun.explicitProgress(hooks.jobs()).remainingChunks == 0
        if finished, task.progress.totalUnitCount > 0 {
            task.progress.completedUnitCount = task.progress.totalUnitCount
        }
        taskIsActive = false
        note(expired ? "expired" : (finished ? "finished" : "stopped_with_work_left"))
        task.setTaskCompleted(success: finished && !expired)
    }

    private func publish(to task: BGContinuedProcessingTask, hooks: Hooks) {
        let progress = OfflinePreparationRun.explicitProgress(hooks.jobs())
        // The queue drops a job the moment it finishes, so an empty queue keeps the last numbers.
        if progress.totalChunks > 0 {
            task.progress.totalUnitCount = Int64(progress.totalChunks)
            task.progress.completedUnitCount = Int64(progress.completedChunks)
        }
        let phase: OfflinePreparationRun.Phase = hooks.isCoolingDown() ? .coolingDown : .preparing
        let subtitle = OfflinePreparationRun.continuedSubtitle(progress, phase: phase)
        guard subtitle != lastSubtitle else { return }
        lastSubtitle = subtitle
        task.updateTitle(OfflinePreparationRun.continuedTitle, subtitle: subtitle)
    }

    private func handleExpiration() {
        expired = true
        hooks?.cancel()
    }

    private func note(_ event: String) {
        trail.append(event)
        if trail.count > 6 { trail.removeFirst(trail.count - 6) }
        hooks?.report(trail.joined(separator: " > "))
    }

    // BGTask can invoke expiration off the main actor. Construct the callback
    // outside actor isolation and hop to the main actor inside it.
    nonisolated static func expirationHandler(
        _ expire: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable () -> Void {
        { Task { @MainActor in expire() } }
    }
}
#endif
