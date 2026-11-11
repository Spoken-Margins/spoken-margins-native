import Foundation

#if DEBUG
/// Counts how often a tab screen's body runs, so a test can tell a redraw from a skipped one (#4028).
///
/// Following, Margins and Settings read the whole `Gate1AppModel`, which publishes while audio renders; each publish
/// reruns a screen's body while its list is moving. The count is how that is measured, per screen, without a trace.
/// It is a DEBUG probe like `PlayQueueSheetProbe`: no code in a Release build.
@MainActor
enum ScreenRedrawProbe {
    private(set) static var bodyRuns: [String: Int] = [:]

    static func record(_ screen: String) { bodyRuns[screen, default: 0] += 1 }

    static func count(_ screen: String) -> Int { bodyRuns[screen, default: 0] }
}
#endif
