import Foundation

/// One CPU budget for every on-device renderer in the process while the app is away (#2695).
///
/// Each renderer used to pace itself to a 65% duty cycle on its own, charging only the CPU used during its own
/// inference. After the Kitten stand-in took over, a Library Supertonic render ran in Kitten's rests, nobody was charged
/// for it, and iOS stopped the app for using too much CPU in the background. The budget is a ledger of CPU charged over
/// the last `window`; a paced inference starts only when the ledger, plus what is already in flight, plus one more
/// inference, fits under `limit`. Renderers then split the budget instead of each taking 65%.
///
/// What is charged is the whole process's CPU clock across each inference, not the inference alone. That catches the
/// ONNX Runtime pool threads a multi-threaded voice runs on (a calling-thread clock would miss them), but it also charges
/// whatever else the process did meanwhile: the player's decoding, main-thread work, SQLite saves. When two inferences
/// overlap, each is charged the other's CPU too. Every one of those errors overcounts, so the budget errs toward resting,
/// which is intended: iOS's limit counts the whole process, and admission (#2695) makes overlap rare.
///
/// The live chain is never starved for it: while the play head waits on audio, or the listening waiting ahead is below
/// `liveReserve`, live narration skips the budget (it keeps its own duty cycle), and what it spends still counts against
/// every other render. The governor reads that from the playing client at each check (`LiveNarrationBuffer`).
public struct OnDeviceCPUBudget: Equatable, Sendable {
    /// Share of one core that all on-device inference together may use in the background, averaged over `window`.
    ///
    /// iOS stops a background audio app that uses more than about 80% of one core over 60 s (`cpu_resource`). The
    /// player's decoding, WAV writes and trims, the cache, SQLite saves and diagnostics all fall outside inference and
    /// are not charged here; Kitten alone at the old 0.65 ran four minutes in the background without a kill, so it was
    /// close but under. 0.6 leaves 20 points for that work and for wakes that arrive late. It stays well above what
    /// live narration needs: Kitten renders about 5.8x real time on one thread, so 0.6 is about 3.5x, against 1.75x
    /// listening at the owner's fastest speed, which still refills the render-ahead window.
    public static let backgroundCoreShare = 0.6
    /// The span iOS averages CPU over for its background limit.
    public static let window: TimeInterval = 60
    /// Listening waiting ahead below which live narration may not wait on the budget. A full ledger drains within
    /// `window`, so the live chain could be held up to 60 s; 90 s ahead covers that wait plus one slow chunk's render.
    public static let liveReserve: TimeInterval = 90

    public static let backgroundLimit = backgroundCoreShare * window

    public let limit: TimeInterval
    private struct Entry: Equatable, Sendable { var at: TimeInterval; var cpu: TimeInterval }
    private var entries: [Entry] = []
    private var inFlight: [TimeInterval] = []

    public init(limit: TimeInterval = OnDeviceCPUBudget.backgroundLimit) {
        self.limit = limit
    }

    /// CPU charged in the window ending at `now`.
    public func spent(now: TimeInterval) -> TimeInterval {
        entries.lazy.filter { $0.at > now - Self.window }.reduce(0) { $0 + $1.cpu }
    }

    /// What the next inference is expected to cost: the largest one in the window. A voice's chunks are alike, and the
    /// larger renderer's bounds the smaller's, so this errs toward resting.
    func estimate(now: TimeInterval) -> TimeInterval {
        entries.lazy.filter { $0.at > now - Self.window }.map(\.cpu).max() ?? 0
    }

    /// An inference is starting: hold its expected cost until `settle` replaces it with what it used, so a second
    /// renderer checking meanwhile sees it.
    public mutating func reserve(now: TimeInterval) -> TimeInterval {
        let expected = estimate(now: now)
        inFlight.append(expected)
        return expected
    }

    /// The inference that `reserve` held for has ended at `now`, having used `cpu`.
    public mutating func settle(reserved: TimeInterval, cpu: TimeInterval, now: TimeInterval) {
        if let index = inFlight.firstIndex(of: reserved) { inFlight.remove(at: index) }
        entries.removeAll { $0.at <= now - Self.window }
        if cpu > 0 { entries.append(Entry(at: now, cpu: cpu)) }
    }

    /// The earliest time from `now` at which one more inference fits under the limit.
    public func earliestStart(now: TimeInterval) -> TimeInterval {
        let live = entries.filter { $0.at > now - Self.window }
        let next = estimate(now: now)
        var spent = live.reduce(0) { $0 + $1.cpu } + inFlight.reduce(0, +)
        if spent + next <= limit { return now }
        for entry in live {
            spent -= entry.cpu
            if spent + next <= limit { return entry.at + Self.window }
        }
        // What is in flight alone fills the budget: look again once one of them settles.
        return now + 0.1
    }
}
