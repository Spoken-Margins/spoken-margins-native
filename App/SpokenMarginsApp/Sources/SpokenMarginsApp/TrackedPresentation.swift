import SessionKit
import SwiftUI
import Synchronization

/// The one place the app presents a sheet or a full-screen cover (#4337).
///
/// A presentation that is dismissed and presented again by itself builds a new screen: the listener sees it flash and
/// loses what was open on it (a sheet, a field being typed in). It reached the owner's phone as #2831, #4091 (twice,
/// the #4119 fix stopped redraws, not rebuilds) and #3891, and no check noticed, because the redraw probes count how
/// often a body runs, not how often a screen is built.
///
/// `trackedSheet` and `trackedFullScreenCover` take the arguments of SwiftUI's `sheet` and `fullScreenCover`, plus
/// the call's file and line (defaulted), which name the presentation. Each adds one modifier to the content, which
/// reports its appearing and disappearing to `PresentationTracker`. A raw `.sheet(` or `.fullScreenCover(` anywhere
/// else in the app's sources fails `scripts/tests/test_tracked_presentations.py`, so a new screen can't skip this.
///
/// What a rebuild is, and what it does when one happens, is in `PresentationLedger` and `PresentationTracker`.
extension View {
    func trackedSheet<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        fileID: String = #fileID,
        line: Int = #line,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let place = PresentationLedger.place(fileID: fileID, line: line)
        return sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().modifier(PresentationTracking(place: place, item: nil))
        }
    }

    func trackedSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        fileID: String = #fileID,
        line: Int = #line,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        let place = PresentationLedger.place(fileID: fileID, line: line)
        return sheet(item: item, onDismiss: onDismiss) { presented in
            content(presented).modifier(PresentationTracking(place: place, item: String(describing: presented.id)))
        }
    }

    func trackedFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        fileID: String = #fileID,
        line: Int = #line,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let place = PresentationLedger.place(fileID: fileID, line: line)
        return fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            content().modifier(PresentationTracking(place: place, item: nil))
        }
    }

    func trackedFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        fileID: String = #fileID,
        line: Int = #line,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        let place = PresentationLedger.place(fileID: fileID, line: line)
        return fullScreenCover(item: item, onDismiss: onDismiss) { presented in
            content(presented).modifier(PresentationTracking(place: place, item: String(describing: presented.id)))
        }
    }
}

/// Reports a presentation's content appearing and disappearing. `instance` is made when the content's view is first
/// built and kept for as long as that view lives, so a screen SwiftUI builds again carries a new one; the tracker
/// tells a screen that came back from a screen that was rebuilt by it. It observes nothing, so it adds no redraw.
private struct PresentationTracking: ViewModifier {
    let place: String
    let item: String?
    @State private var instance = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { PresentationTracker.shared.appeared(place: place, item: item, instance: instance) }
            .onDisappear { PresentationTracker.shared.disappeared(instance: instance) }
    }
}

/// The app's `PresentationLedger`, and what a rebuild does (#4337).
///
/// - Release: counted. `summary` is the Diagnostics `screenRebuilds` line, so a rebuild a listener met shows up in
///   an export without a trace.
/// - Debug app-hosted tests: the test bundle sets `onRebuild`, which fails the running test.
/// - Debug UI tests (scripted journeys, launched with `--ui-testing`): the app stops, naming the presentation.
final class PresentationTracker: Sendable {
    static let shared = PresentationTracker()

    private let ledger = Mutex(PresentationLedger())

    func appeared(place: String, item: String?, instance: UUID) {
        let rebuild = ledger.withLock { $0.appeared(place: place, item: item, instance: instance, at: ProcessInfo.processInfo.systemUptime) }
        #if DEBUG
        if let rebuild { tripped(by: rebuild) }
        #endif
    }

    func disappeared(instance: UUID) {
        ledger.withLock { $0.disappeared(instance: instance, at: ProcessInfo.processInfo.systemUptime) }
    }

    /// The Diagnostics `screenRebuilds` line.
    var summary: String { ledger.withLock { $0.summaryText } }

    #if DEBUG
    private let handler = Mutex<(@Sendable (PresentationLedger.Rebuild) -> Void)?>(nil)

    /// What a rebuild does in a test that hosts the app. Set by the test bundle; nil means nothing (a plain launch).
    var onRebuild: (@Sendable (PresentationLedger.Rebuild) -> Void)? {
        get { handler.withLock { $0 } }
        set { handler.withLock { $0 = newValue } }
    }

    /// Forgets what was showing and what was counted, so one test's screens can't make the next one's look rebuilt.
    func reset() { ledger.withLock { $0 = PresentationLedger() } }

    var rebuilds: [PresentationLedger.Rebuild] { ledger.withLock { $0.recent } }

    private func tripped(by rebuild: PresentationLedger.Rebuild) {
        if UITestingHooks.isActive { fatalError("Screen rebuilt while open: \(rebuild.description)") }
        onRebuild?(rebuild)
    }
    #endif
}
