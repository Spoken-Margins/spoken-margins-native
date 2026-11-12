import SwiftUI
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4026: the diagnostics and listening-signals share sheets are presented from UIKit, over the front-most view
/// controller, so a redraw of the Settings form cannot reload them.
@MainActor
final class ShareFilePresenterTests: XCTestCase {
    func testTheSheetGoesOverTheFrontMostPresentedController() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let root = UIViewController()
        let first = UIViewController()
        let second = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }

        XCTAssertTrue(ShareFilePresenter.topViewController(from: root) === root)

        let presented = expectation(description: "presented")
        root.present(first, animated: false) {
            first.present(second, animated: false) { presented.fulfill() }
        }
        wait(for: [presented], timeout: 5)

        XCTAssertTrue(ShareFilePresenter.topViewController(from: root) === second)
        XCTAssertNil(ShareFilePresenter.topViewController(from: nil))
    }

    func testTheSheetCarriesTheFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics.json")
        XCTAssertEqual(ShareFilePresenter.activityItems(for: url).compactMap { $0 as? URL }, [url])
    }

    /// A view controller set to `.popover` has a popover presentation controller on any device, so this runs everywhere
    /// (the lane counts a skipped test as a fault).
    func testThePopoverIsAnchoredAtTheCentreWithNoArrow() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let controller = UIViewController()
        controller.modalPresentationStyle = .popover
        let popover = try XCTUnwrap(controller.popoverPresentationController)

        ShareFilePresenter.anchor(popover, in: view)

        XCTAssertTrue(popover.sourceView === view)
        XCTAssertEqual(popover.sourceRect, CGRect(x: 196.5, y: 426, width: 0, height: 0))
        XCTAssertEqual(popover.permittedArrowDirections, [])
    }

    func testNoPopoverMeansNothingToAnchor() {
        ShareFilePresenter.anchor(nil, in: UIView())
    }

    // MARK: - The sheet holds still while the model publishes (#4026, Done when 2)

    private static let publishes = 80

    /// The owner's recording (build 94a7bfb): with audio rendering, the share sheet over Settings reloaded again and
    /// again, because it was a SwiftUI `.sheet` inside a screen the model's publishes redraw. This mounts Settings in the
    /// app's own tab bar (which watches the whole model, as it does on the phone), presents the sheet the way the
    /// Share Diagnostics button does, and publishes about two seconds' worth of every kind of model write audio makes.
    /// The same `UIActivityViewController` must stay presented from the first look to the last: a rebuilt or re-presented
    /// sheet is a different controller (or one briefly not presented).
    func testTheSheetOverSettingsIsNotReloadedByModelPublishes() async throws {
        let model = try makeModel()
        let mounted = try mount(settingsInTheTabBar(model: model))
        defer { mounted.close() }
        try await waitUntilQuiet { ScreenRedrawProbe.count("settings") }
        let file = try exportFile()
        defer { try? FileManager.default.removeItem(at: file) }

        ShareFilePresenter.present(fileURL: file)
        let sheet = try await presentedActivitySheet(in: mounted.window)
        var presentations = 1
        var lostLooks = 0
        var lastSeen: UIViewController? = sheet
        for index in 0..<Self.publishes {
            publish(index, on: model)
            try await Task.sleep(for: .milliseconds(25))
            let now = mounted.window.rootViewController?.presentedViewController
            if now !== lastSeen { presentations += 1 }
            lastSeen = now
            if now !== sheet || sheet.isBeingDismissed || sheet.presentingViewController == nil { lostLooks += 1 }
        }

        XCTAssertEqual(lostLooks, 0, "The share sheet was gone or replaced in \(lostLooks) of \(Self.publishes) looks "
                           + "while the model published; it was presented \(presentations) times")
        XCTAssertEqual(presentations, 1, "The share sheet was presented \(presentations) times for one tap")
        XCTAssertTrue(mounted.window.rootViewController?.presentedViewController === sheet, "The first sheet is not the one left on screen")
    }

    /// The control for the test above, run against the arrangement #4026 replaced: a plain `.sheet` on a row of a form
    /// whose screen watches the model. The test above only means something if this shows the fault it guards: every
    /// publish must re-run the sheet's content closure. If it stops doing that, the test above no longer reproduces the
    /// owner's recording and its pass proves nothing.
    func testWithAPlainSheetOnAScreenThatWatchesTheModelTheSheetIsRebuiltByPublishes() async throws {
        let model = try makeModel()
        let mounted = try mount(AnyView(PlainSheetSharePresenter(model: model)))
        defer { mounted.close() }
        try await waitUntilQuiet { PlainSheetShareProbe.builds }
        let before = PlainSheetShareProbe.builds

        for index in 0..<Self.publishes {
            publish(index, on: model)
            try await Task.sleep(for: .milliseconds(25))
        }

        let rebuilt = PlainSheetShareProbe.builds - before
        XCTAssertGreaterThan(rebuilt, 0, "Plain sheet: \(Self.publishes) model publishes rebuilt the sheet's content \(rebuilt) times")
    }

    /// Every kind of write audio makes: the bare `objectWillChange` every write ends in, a rendered chunk, the prepared
    /// audio status flipping, and a percent more listening on every Library row.
    private func publish(_ index: Int, on model: Gate1AppModel) {
        switch index % 4 {
        case 0:
            model.objectWillChange.send()
        case 1:
            model.updateOnDeviceSpeechGenerationProgress(RenderedSpeechGenerationProgress(completedChunks: 100 + index, totalChunks: 959))
        case 2:
            model.preparedTextAudioStatus = (index / 4).isMultiple(of: 2) ? "preparing" : "ready"
        default:
            model.libraryItems = model.libraryItems.map { row in
                var row = row
                row.continuationProgressPercent = 10 + index
                return row
            }
        }
    }

    private func makeModel() throws -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        let store = try model.requireStore()
        for index in 0..<3 {
            try store.saveItem(Item(id: "share-sheet-\(index)", title: "Fixture article \(index + 1)", mediaType: "text",
                                    text: "One.\n\nTwo.", externalReference: nil, status: "Ready"))
        }
        try model.refreshLibraryRows(store: store)
        return model
    }

    /// The app's tab bar on the Settings tab, as `Gate1RootView` shows it.
    private struct TabsHost: View {
        @State var navigation: AppNavigationState
        let notice: SupertonicDownloadNotice

        var body: some View {
            ExperienceRootTabs(navigation: $navigation, supertonicNotice: notice)
        }
    }

    private func settingsInTheTabBar(model: Gate1AppModel) -> AnyView {
        var navigation = AppNavigationState()
        navigation.select(.settings, recordingIsLocked: false)
        let notice = SupertonicDownloadNotice(defaults: UserDefaults(suiteName: "share-sheet-\(UUID().uuidString)")!,
                                              modelInstalled: { false })
        let drawer = CatalogDrawerModel(store: nil, subscriptions: { [] }, follow: { _ in "" })
        return AnyView(TabsHost(navigation: navigation, notice: notice).environmentObject(model).environmentObject(drawer))
    }

    private func exportFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-sheet-\(UUID().uuidString).json")
        try Data("{\"fixture\":true}".utf8).write(to: url)
        return url
    }

    @MainActor
    private struct Mounted {
        let window: UIWindow
        let previousKeyWindow: UIWindow?

        func close() {
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
    }

    private func mount(_ view: AnyView) throws -> Mounted {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return Mounted(window: window, previousKeyWindow: previousKeyWindow)
    }

    /// Returns once `read` has not moved for 10 polls (0.4 s): the screen's own first-appearance work is over, so what is
    /// counted next is the publishes.
    private func waitUntilQuiet(_ read: () -> Int) async throws {
        var last = read()
        var quiet = 0
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(40))
            let now = read()
            quiet = now == last ? quiet + 1 : 0
            last = now
            if quiet >= 10 { return }
        }
        XCTFail("The screen kept redrawing with nothing changing (\(last) runs)")
    }

    private func presentedActivitySheet(in window: UIWindow) async throws -> UIActivityViewController {
        for _ in 0..<125 {
            if let sheet = window.rootViewController?.presentedViewController as? UIActivityViewController { return sheet }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("No share sheet was presented over the window's root within 5 s")
        throw NotPresented()
    }

    private struct NotPresented: Error {}
}

/// Counts how often the plain sheet's content closure runs; read by the control test. A publish can come from any
/// thread's point of view of the compiler, so the counter is not actor-bound; SwiftUI runs the closure on the main thread.
private enum PlainSheetShareProbe {
    nonisolated(unsafe) static var builds = 0
}

/// What #4026 replaced: a plain `.sheet` on a row of a form, on a screen that watches the whole model.
private struct PlainSheetSharePresenter: View {
    @ObservedObject var model: Gate1AppModel
    @State private var isPresented = true

    var body: some View {
        Form {
            Button("Share Diagnostics") { isPresented = true }
                .sheet(isPresented: $isPresented) {
                    let _ = PlainSheetShareProbe.builds += 1
                    Text("Share sheet")
                }
        }
    }
}
