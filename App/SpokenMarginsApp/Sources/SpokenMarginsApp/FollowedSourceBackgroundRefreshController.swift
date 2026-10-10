#if canImport(BackgroundTasks) && canImport(UIKit)
import BackgroundTasks
import Foundation

/// What the handler needs from a `BGAppRefreshTask`, so a test can stand in for the system's task.
protocol FeedRefreshBackgroundTask: AnyObject {
    func onExpiration(_ handler: @escaping @Sendable () -> Void)
    func clearExpiration()
    func setTaskCompleted(success: Bool)
}

extension BGAppRefreshTask: FeedRefreshBackgroundTask {
    func onExpiration(_ handler: @escaping @Sendable () -> Void) { expirationHandler = handler }
    func clearExpiration() { expirationHandler = nil }
}

/// Refreshes the followed feeds while the app is in the background, so new episodes and posts are
/// already in Following when the listener opens the app (#170). The refresh itself is the
/// foreground's (`Gate1AppModel.refreshFollowedSources`), with the same six-hour staleness rule;
/// this type only owns the system task: registering it, asking for the next run, and stopping on
/// expiry.
@MainActor
final class FollowedSourceBackgroundRefreshController {
    nonisolated static let identifier = "com.spokenmargins.native.feed-refresh"
    /// iOS decides the real time; this is the earliest it may start the next refresh.
    nonisolated static let refreshInterval: TimeInterval = 6 * 60 * 60
    static let shared = FollowedSourceBackgroundRefreshController()

    private let submit: (BGAppRefreshTaskRequest) throws -> Void
    private let cancelPending: () -> Void
    private let now: () -> Date
    private var work: (@MainActor () async -> Void)?
    private var registered = false

    init(
        submit: @escaping (BGAppRefreshTaskRequest) throws -> Void = { try BGTaskScheduler.shared.submit($0) },
        cancelPending: @escaping () -> Void = {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: FollowedSourceBackgroundRefreshController.identifier)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.submit = submit
        self.cancelPending = cancelPending
        self.now = now
    }

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            // The launch closure inherits this controller's MainActor isolation.
            using: .main
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { refreshTask.setTaskCompleted(success: false); return }
                await self.handle(refreshTask)
            }
        }
    }

    /// `work` refreshes the stale feeds and returns when it is done or has been cancelled.
    func install(work: @escaping @MainActor () async -> Void) {
        self.work = work
    }

    /// Asks iOS for a refresh about six hours from now, or withdraws the ask when nothing is followed.
    /// Submitting replaces an earlier request with the same identifier.
    func schedule(enabled: Bool = true) {
        cancelPending()
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.identifier)
        request.earliestBeginDate = now().addingTimeInterval(Self.refreshInterval)
        do {
            try submit(request)
        } catch {
            // Opportunistic: the foreground refresh still runs when the app opens.
        }
    }

    func handle(_ task: some FeedRefreshBackgroundTask) async {
        // Ask for the next run first, so a task that expires or finds no work still leaves one pending.
        schedule()
        guard let work else {
            task.setTaskCompleted(success: false)
            return
        }
        let operation = Task { await work() }
        task.onExpiration(Self.expirationHandler(for: operation))
        await operation.value
        task.clearExpiration()
        task.setTaskCompleted(success: !operation.isCancelled)
    }

    // BGTask can invoke expiration off the main actor. Construct the callback outside actor
    // isolation; cancellation itself is thread-safe.
    nonisolated static func expirationHandler(for operation: Task<Void, Never>) -> @Sendable () -> Void {
        { operation.cancel() }
    }
}
#endif
