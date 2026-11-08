import Darwin
import Foundation
import SessionKit

/// Times each launch and keeps the last few, with how the runs before them ended, in Diagnostics (#3752).
///
/// The Diagnostics event log holds 300 events, so the slow open the owner felt on Saturday and the relaunch
/// after it were gone from Sunday's export. This keeps `LaunchHistory` in `UserDefaults`, apart from that log,
/// and saves it at each stage, so a launch that was killed before the Library showed is still there for the
/// next run to report. The lines are pinned, so Refresh Diagnostics doesn't drop them.
///
/// Marks: the root view appearing, the Library loaded, and the root view showing it (`usable`), in milliseconds
/// since `App.init`. The time from the kernel's process start to `App.init` is kept apart: iOS can prewarm an app
/// (start its process hours before the listener opens it), and then that gap is idle time, so it is dropped and
/// the launch is marked `prewarmed`. A launch iOS makes with no screen (a background refresh) never shows the
/// root view and reads `no_ui`. A unit test has no recorder (`shared` stays nil) and every call is a no-op.
@MainActor
final class LaunchRecorder {
    static let defaultsKey = "launchHistory.v1"
    static let launchesKey = "launchHistory"
    static let exitsKey = "previousExits"
    /// A gap between process start and `App.init` longer than this is a prewarm, not the time to load the app.
    static let prewarmGapMs = 60_000

    /// Set once in `SpokenMarginsApp.init`; nil in unit tests.
    static var shared: LaunchRecorder?

    private(set) var history: LaunchHistory
    private let defaults: UserDefaults
    private let now: () -> Date
    /// When `App.init` ran: the baseline for every mark.
    private let launchStart: Date
    private let runSoon: (@escaping @MainActor () -> Void) -> Void
    private var publish: (@MainActor (String, String) -> Void)?

    init(
        defaults: UserDefaults = .standard,
        build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        processStart: Date? = LaunchRecorder.currentProcessStart(),
        now: @escaping () -> Date = Date.init,
        runSoon: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    ) {
        self.defaults = defaults
        self.now = now
        self.runSoon = runSoon
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(LaunchHistory.self, from: data) {
            history = saved
        } else {
            history = LaunchHistory()
        }
        launchStart = now()
        let gap = LaunchHistory.elapsedMs(from: processStart, to: launchStart)
        let prewarmed = ProcessInfo.processInfo.environment["ActivePrewarm"] == "1" || (gap ?? 0) > Self.prewarmGapMs
        history.beginLaunch(at: launchStart, build: build, preInitMs: gap, prewarmed: prewarmed)
        save()
    }

    /// Sets where the Diagnostics lines go, and shows what is already known, including the earlier launches.
    func attach(_ publish: @escaping @MainActor (String, String) -> Void) {
        self.publish = publish
        publishLines()
    }

    func markRootAppeared() { mark(.rootAppear) }

    /// The Library's rows are loaded and published. The root view shows them on its next update, which marks
    /// `usable` (`markLibraryShown`); an empty Library changes nothing the root view watches, so the next turn does.
    func markLibraryReady(items: Int) {
        mark(.libraryReady, libraryItems: items)
        if items == 0 { runSoon { [weak self] in self?.mark(.usable) } }
    }

    /// The root view updated for the loaded Library. Ignored until the Library is ready.
    func markLibraryShown() { mark(.usable) }

    func markLibraryFailed() { mark(.libraryReady, libraryFailed: true) }

    /// One `app.previous_exit` event's fields, kept past the event log's 300.
    func noteExit(fields: [String: String]) {
        history.recordExit(fields: fields, at: now())
        save()
        publishLines()
    }

    private func mark(_ stage: LaunchHistory.Stage, libraryItems: Int? = nil, libraryFailed: Bool = false) {
        guard let elapsed = LaunchHistory.elapsedMs(from: launchStart, to: now()) else { return }
        history.mark(stage, elapsedMs: elapsed, libraryItems: libraryItems, libraryFailed: libraryFailed)
        save()
        publishLines()
    }

    private func publishLines() {
        publish?(Self.launchesKey, history.launchesLine)
        publish?(Self.exitsKey, history.exitsLine)
    }

    // A few hundred bytes, a handful of times per launch. Written at once so a kill right after still has it.
    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// When this process started, from the kernel. Nil if it can't be read.
    nonisolated static func currentProcessStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&request, UInt32(request.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        guard started.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }
}
