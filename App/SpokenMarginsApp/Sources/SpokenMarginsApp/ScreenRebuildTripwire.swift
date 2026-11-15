import Foundation
import os
import SessionKit
import SwiftUI

/// Catches a sheet or full-screen cover built again while it is open (#4337), the class behind #2831 and #4091: a
/// presentation SwiftUI dismisses and presents again by itself builds a new screen, which flashes and loses whatever was
/// open on it. The rules live in `PresentationRebuildLedger`; this feeds it from every presented screen.
///
/// Every `.sheet` and `.fullScreenCover` in the app goes through `trackedSheet` / `trackedFullScreenCover` below
/// (`scripts/check_tracked_presentations.py` refuses the raw ones). A rebuild is logged and counted on the Diagnostics
/// line `screenRebuilds` in every build. In a Debug build under UI tests (the scripted journeys) it stops the app with
/// the presentation named, and the app-hosted test bundle fails the running test on one.
@MainActor
final class ScreenRebuildTripwire {
    static let shared = ScreenRebuildTripwire()
    static let diagnosticsKey = "screenRebuilds"

    private(set) var ledger = PresentationRebuildLedger()
    /// Set by the app-hosted test bundle, which fails the running test.
    var onRebuild: ((PresentationRebuildLedger.Rebuild) -> Void)?
    private var nextToken = 0
    private var publish: (@MainActor (String, String) -> Void)?
    private let log = Logger(subsystem: "com.spokenmargins.native", category: "screen-rebuild")

    func attach(_ publish: @escaping @MainActor (String, String) -> Void) {
        self.publish = publish
        publish(Self.diagnosticsKey, ledger.summary)
    }

    /// A test starts from no builds, so a screen one test closed is not compared with the next test's.
    func reset() {
        ledger = PresentationRebuildLedger()
    }

    func built(presentation: String, item: String?) -> Int {
        nextToken += 1
        ledger.built(token: nextToken, presentation: presentation, item: item)
        return nextToken
    }

    func appeared(_ token: Int) {
        guard let rebuild = ledger.appeared(token: token, at: Date()) else { return }
        log.fault("Screen rebuilt while open: \(rebuild.presentation, privacy: .public), gap \(rebuild.gapMs) ms")
        publish?(Self.diagnosticsKey, ledger.summary)
        onRebuild?(rebuild)
        #if DEBUG
        if ProcessInfo.processInfo.environment["SPOKEN_MARGINS_UI_TESTING"] == "1" {
            fatalError("Screen rebuilt while open (#4337): \(rebuild.presentation), gap \(rebuild.gapMs) ms")
        }
        #endif
    }

    func disappeared(_ token: Int) {
        ledger.disappeared(token: token, at: Date())
    }

    func released(_ token: Int) {
        ledger.released(token: token)
    }
}

/// One build of a presented screen: created once per screen SwiftUI builds, as the `@StateObject` of its content.
@MainActor
private final class PresentationBuild: ObservableObject {
    let token: Int

    init(presentation: String, item: String?) {
        token = ScreenRebuildTripwire.shared.built(presentation: presentation, item: item)
    }

    deinit {
        let token = token
        Task { @MainActor in ScreenRebuildTripwire.shared.released(token) }
    }
}

private struct RebuildTripwire: ViewModifier {
    @StateObject private var build: PresentationBuild

    init(presentation: String, item: String?) {
        _build = StateObject(wrappedValue: PresentationBuild(presentation: presentation, item: item))
    }

    func body(content: Content) -> some View {
        content
            .onAppear { ScreenRebuildTripwire.shared.appeared(build.token) }
            .onDisappear { ScreenRebuildTripwire.shared.disappeared(build.token) }
    }
}

private func presentationName(_ file: StaticString, _ line: UInt) -> String {
    "\((("\(file)" as NSString).lastPathComponent)):\(line)"
}

extension View {
    func trackedSheet<Content: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
        file: StaticString = #fileID, line: UInt = #line,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let name = presentationName(file, line)
        return sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().modifier(RebuildTripwire(presentation: name, item: nil))
        }
    }

    func trackedSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
        file: StaticString = #fileID, line: UInt = #line,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        let name = presentationName(file, line)
        return sheet(item: item, onDismiss: onDismiss) { shown in
            content(shown).modifier(RebuildTripwire(presentation: name, item: "\(shown.id)"))
        }
    }

    func trackedFullScreenCover<Content: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
        file: StaticString = #fileID, line: UInt = #line,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let name = presentationName(file, line)
        return fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            content().modifier(RebuildTripwire(presentation: name, item: nil))
        }
    }

    func trackedFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
        file: StaticString = #fileID, line: UInt = #line,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        let name = presentationName(file, line)
        return fullScreenCover(item: item, onDismiss: onDismiss) { shown in
            content(shown).modifier(RebuildTripwire(presentation: name, item: "\(shown.id)"))
        }
    }
}
