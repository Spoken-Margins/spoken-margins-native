import SessionKit
import SwiftUI
import Synchronization
import os

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
            content().trackedPresentation(place: place)
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
            content(presented).trackedPresentation(place: place, item: String(describing: presented.id))
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
            content().trackedPresentation(place: place)
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
            content(presented).trackedPresentation(place: place, item: String(describing: presented.id))
        }
    }
}

extension View {
    /// Reports this view, the content of a presentation, appearing and disappearing. The wrappers above use it; so does
    /// the play queue, which UIKit presents and so has no `.sheet` to wrap (`PlayQueueSheetHost`). `scene` names the
    /// window when the view is outside the scene's environment, as a UIKit-presented one is.
    func trackedPresentation(place: String, item: String? = nil, scene: String? = nil) -> some View {
        modifier(PresentationTracking(place: place, item: item, explicitScene: scene))
    }

    /// Gives this window's views a scene token for the presentations in them (#4337). The app supports several windows
    /// on an iPad, and they share one model, so each shows the Terms or Help sheet when the model sets it: the same
    /// place and item in two windows is not a screen built twice.
    func presentationSceneToken() -> some View { modifier(PresentationSceneToken()) }
}

private struct PresentationSceneKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    fileprivate var presentationScene: String? {
        get { self[PresentationSceneKey.self] }
        set { self[PresentationSceneKey.self] = newValue }
    }
}

/// Made once for each window, because a `WindowGroup`'s content is built once for each scene and keeps its state.
private struct PresentationSceneToken: ViewModifier {
    @State private var token = UUID().uuidString

    func body(content: Content) -> some View {
        content.environment(\.presentationScene, token)
    }
}

/// Reports a presentation's content appearing and disappearing. `instance` is made when the content's view is first
/// built and kept for as long as that view lives, so a screen SwiftUI builds again carries a new one; the tracker
/// tells a screen that came back from a screen that was rebuilt by it. It observes nothing, so it adds no redraw.
private struct PresentationTracking: ViewModifier {
    let place: String
    let item: String?
    let explicitScene: String?
    @Environment(\.presentationScene) private var environmentScene
    @State private var instance = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { PresentationTracker.shared.appeared(place: place, item: item, scene: explicitScene ?? environmentScene, instance: instance) }
            .onDisappear { PresentationTracker.shared.disappeared(instance: instance) }
    }
}

/// The app's `PresentationLedger`, and what a rebuild does (#4337).
///
/// - Every build: counted, and logged as a fault naming the place (never the item). `summary` is the Diagnostics
///   `screenRebuilds` line, so a rebuild a listener met shows up in an export without a trace.
/// - Debug app-hosted tests: the test bundle sets `onRebuild`, which fails the running test.
/// - Debug UI tests (scripted journeys, launched with `--ui-testing`): the app stops, naming the presentation.
final class PresentationTracker: Sendable {
    static let shared = PresentationTracker()

    private let ledger = Mutex(PresentationLedger())
    private let log = Logger(subsystem: "com.spokenmargins.native", category: "screen-rebuild")

    func appeared(place: String, item: String?, scene: String? = nil, instance: UUID) {
        let rebuild = ledger.withLock { $0.appeared(place: place, item: item, scene: scene, instance: instance, at: ProcessInfo.processInfo.systemUptime) }
        guard let rebuild else { return }
        // The place and the reason are the app's own words; the item can be a title, so it stays out of the log.
        log.fault("Screen rebuilt while open: \(rebuild.place, privacy: .public), \(rebuild.reason.rawValue, privacy: .public)")
        #if DEBUG
        tripped(by: rebuild)
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
