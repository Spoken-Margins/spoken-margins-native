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
    ///
    /// What this does and does not guard: the presentation is called directly, not by tapping Share Diagnostics, so it
    /// guards that a sheet UIKit presents over the window survives the app's publishes and redraws. It does not catch
    /// Settings going back to hosting the sheet itself; `SettingsScreen` calls `ShareFilePresenter.present` at both buttons
    /// and has no `.sheet` for a share view, and a reviewer must keep it so.
    func testTheSheetOverSettingsIsNotReloadedByModelPublishes() async throws {
        let model = try makeModel()
        let mounted = try mount(settingsInTheTabBar(model: model))
        defer { mounted.close() }
        try await waitUntilQuiet { ScreenRedrawProbe.count("settings") }
        let file = try exportFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var modelPublishes = 0
        let watch = model.objectWillChange.sink { modelPublishes += 1 }
        defer { watch.cancel() }

        ShareFilePresenter.present(fileURL: file)
        let sheet = try await presentedActivitySheet(in: mounted.window)
        // Let the sheet finish coming up, so the looks below are of a settled sheet, not one still animating in.
        try await Task.sleep(for: .milliseconds(500))
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

        XCTAssertGreaterThanOrEqual(modelPublishes, Self.publishes, "Only \(modelPublishes) of \(Self.publishes) writes reached the model's observers, so the sheet was not tested against publishes")
        XCTAssertEqual(lostLooks, 0, "The share sheet was gone or replaced in \(lostLooks) of \(Self.publishes) looks "
                           + "while the model published; it was presented \(presentations) times")
        XCTAssertEqual(presentations, 1, "The share sheet was presented \(presentations) times for one tap")
        XCTAssertTrue(mounted.window.rootViewController?.presentedViewController === sheet, "The first sheet is not the one left on screen")
    }

    /// The control for the test above, run against the arrangement #4026 replaced: a plain `.sheet` on a row of a form
    /// whose screen watches the model. The test above only means something if this shows the fault it guards: a write
    /// to what the sheet shows must re-run the sheet's content closure. If it stops doing that, the test above no longer
    /// reproduces the owner's recording and its pass proves nothing.
    ///
    /// This reads what the sheet's content *shows*, not how many times it was built (#4260). A count asserted idle first
    /// ("no rebuilds with no publish") failed on the hosted runner (6 builds where 2 were expected): a sheet that has just
    /// come up rebuilds for reasons that are not publishes (its presentation settling, a trait or safe-area change), so
    /// the count of builds cannot say what caused them. A value only a publish writes can: the sheet shows the status
    /// and the first Library row's progress the model holds, so each sentinel below reaches the sheet only if a publish
    /// made the sheet rebuild. The wait for each is a deadline, not a count.
    func testWithAPlainSheetOnAScreenThatWatchesTheModelTheSheetIsRebuiltByPublishes() async throws {
        PlainSheetShareProbe.reset()
        let model = try makeModel()
        model.preparedTextAudioStatus = "control-start"
        let mounted = try mount(AnyView(PlainSheetSharePresenter(model: model)))
        defer { mounted.close() }
        try await pollUntil { PlainSheetShareProbe.lastStatus != nil }
        XCTAssertNotNil(PlainSheetShareProbe.lastStatus, "The plain sheet's content was never built, so there is nothing to compare")

        for index in 0..<Self.publishes {
            publish(index, on: model)
            try await Task.sleep(for: .milliseconds(25))
        }

        // The sentinels are written after the publishes above, one at a time: the sheet must come to show each. One
        // is a write to the status, one is a write to a Library row (the two kinds of write the sheet can show; a bare
        // `objectWillChange` or a progress chunk carries no value to read back).
        for sentinel in ["control-first", "control-second", "control-third"] {
            model.preparedTextAudioStatus = sentinel
            try await pollUntil(timeout: .seconds(10)) { PlainSheetShareProbe.lastStatus == sentinel }
            XCTAssertEqual(PlainSheetShareProbe.lastStatus, sentinel,
                           "Plain sheet: after \(Self.publishes) model publishes and a write of \(sentinel), the sheet's content still showed "
                           + "\(PlainSheetShareProbe.lastStatus ?? "nothing"), so a status write did not rebuild it")
        }
        for percent in [901, 902, 903] {
            model.libraryItems = model.libraryItems.map { row in
                var row = row
                row.continuationProgressPercent = percent
                return row
            }
            try await pollUntil(timeout: .seconds(10)) { PlainSheetShareProbe.lastPercent == percent }
            XCTAssertEqual(PlainSheetShareProbe.lastPercent, percent,
                           "Plain sheet: after a Library row write of \(percent) percent, the sheet's content still showed "
                           + "\(PlainSheetShareProbe.lastPercent.map { String($0) } ?? "nothing"), so a Library write did not rebuild it")
        }
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
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            try await Task.sleep(for: .milliseconds(40))
            let now = read()
            quiet = now == last ? quiet + 1 : 0
            last = now
            if quiet >= 10 { return }
        }
        XCTFail("The screen kept redrawing with nothing changing (\(last) runs)")
    }

    private func presentedActivitySheet(in window: UIWindow) async throws -> UIActivityViewController {
        let pollDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < pollDeadline {
            if let sheet = window.rootViewController?.presentedViewController as? UIActivityViewController { return sheet }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("No share sheet was presented over the window's root within 30 s")
        throw NotPresented()
    }

    private struct NotPresented: Error {}
}

/// Records the status the plain sheet's content closure last showed; read by the control test. A publish can come from
/// any thread's point of view of the compiler, so the state is not actor-bound; SwiftUI runs the closure on the main thread.
/// A build is told apart by what it shows, never by how many there were (#4260).
private enum PlainSheetShareProbe {
    nonisolated(unsafe) static var lastStatus: String?
    nonisolated(unsafe) static var lastPercent: Int?

    static func reset() {
        lastStatus = nil
        lastPercent = nil
    }
}

/// What #4026 replaced: a plain `.sheet` on a row of a form, on a screen that reads the model, as the old Settings did
/// (its rows and the sheet's content came from model values). An unread `@ObservedObject` is not enough: the first lane
/// run showed SwiftUI does not rebuild the sheet's content for publishes the view never reads (0 rebuilds in 80), so the
/// screen and the sheet both read the prepared-audio status the publishes flip.
private struct PlainSheetSharePresenter: View {
    @ObservedObject var model: Gate1AppModel
    @State private var isPresented = true

    var body: some View {
        Form {
            Text("Audio: \(model.preparedTextAudioStatus)")
            Button("Share Diagnostics") { isPresented = true }
                .sheet(isPresented: $isPresented) {
                    let _ = PlainSheetShareProbe.lastStatus = model.preparedTextAudioStatus
                    let _ = PlainSheetShareProbe.lastPercent = model.libraryItems.first?.continuationProgressPercent
                    Text("Share sheet, audio \(model.preparedTextAudioStatus), \(model.libraryItems.first?.continuationProgressPercent ?? 0) percent")
                }
        }
    }
}
