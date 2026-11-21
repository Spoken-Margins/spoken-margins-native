import Combine
import Foundation
import SwiftUI
import Synchronization

#if DEBUG
/// Counts how often a tab screen's body runs, so a test can tell a redraw from a skipped one (#4028).
///
/// Following, Margins and Settings read the whole `Gate1AppModel`, which publishes while audio renders; each publish
/// reruns a screen's body while its list is moving. The count is how that is measured, per screen, without a trace.
/// It is a DEBUG probe like `PlayQueueSheetProbe`: no code in a Release build.
@MainActor
enum ScreenRedrawProbe {
    private(set) static var bodyRuns: [String: Int] = [:]
    /// How often SwiftUI asked a screen's `==`, so a redraw count over the limit says whether the tab bar's redraw
    /// reached the screen's equality check (a parent redraw) or the screen was invalidated by something it watches.
    private nonisolated static let equalityChecks = Mutex<[String: Int]>([:])

    /// How often each thing a screen watches announced a change, by the name the screen gave it. A body-run count over
    /// the limit says a screen was redrawn; this says which of the screen's own objects asked for it (#4379).
    private(set) static var publishes: [String: Int] = [:]

    /// Screens whose body prints SwiftUI's own reason for each run (`Self._printChanges()`), set by a test that is
    /// chasing a redraw. Off otherwise: the output is one line per run.
    static var printsChanges: Set<String> = []

    static func record(_ screen: String) { bodyRuns[screen, default: 0] += 1 }

    static func recordPublish(_ source: String) { publishes[source, default: 0] += 1 }

    static func count(_ screen: String) -> Int { bodyRuns[screen, default: 0] }

    nonisolated static func recordEqualityCheck(_ screen: String) {
        equalityChecks.withLock { $0[screen, default: 0] += 1 }
    }

    nonisolated static func equalityCheckCount(_ screen: String) -> Int {
        equalityChecks.withLock { $0[screen, default: 0] }
    }
}

extension View {
    /// Counts each announcement of the screen's own objects in `ScreenRedrawProbe.publishes`, under `"<screen>.<name>"`.
    /// `onReceive` redraws nothing by itself, so the screen runs as it does without this.
    func recordsPublishes(screen: String, of sources: KeyValuePairs<String, ObservableObjectPublisher>) -> some View {
        onReceive(Publishers.MergeMany(sources.map { name, publisher in publisher.map { _ in name } })) { name in
            ScreenRedrawProbe.recordPublish("\(screen).\(name)")
        }
    }
}
#endif
