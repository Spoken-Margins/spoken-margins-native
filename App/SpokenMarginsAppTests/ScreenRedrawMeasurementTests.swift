import SwiftUI
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// #4028: Following, Margins and Settings rebuilt their bodies on every model publish while audio rendered, 20 runs for
/// 20 publishes each (the census below, first run on the lane for #4039), and the lists stuttered under the listener's
/// finger. Each screen now reads the model through a `ScreenInputsFeed`.
///
/// Each screen is mounted inside the app's own tab bar (`ExperienceRootTabs`, which watches the whole model and so
/// redraws on every publish, as it does on the phone), left to settle, then given model publishes, 25 ms apart. The
/// regression tests send 20 publishes that leave the screen's inputs as they were and allow at most 2 body runs; on
/// `main` before the fix each screen ran 20. They then make one change the screen shows and require a redraw, so a feed
/// that went deaf cannot pass. The census is attached to the run (`redraw-census`) and printed.
@MainActor
final class ScreenRedrawMeasurementTests: XCTestCase {
    private static let publishes = 20
    /// A stray draw from the screen's own late first-appearance work is not a publish redrawing it.
    private static let allowedRuns = 2

    private enum Publish: String, CaseIterable {
        /// `objectWillChange.send()`, what every model write ends in.
        case plain
        /// A new chunk count, which is what each rendered chunk writes.
        case renderProgress
        /// The prepared-audio status flipping between two words.
        case preparedStatus
    }

    private enum Screen: String, CaseIterable {
        case following, margins, settings

        var root: AppRoot {
            switch self {
            case .following: .sources
            case .margins: .margins
            case .settings: .settings
            }
        }
    }

    // MARK: - Regression tests

    func testFollowingIsNotRedrawnByModelPublishesThatLeaveItsListAsItWas() async throws {
        try await assertOnlyShownChangesRedraw(.following) { model in
            // Offline shows the "last local snapshot" line.
            model.selectedProfileId = "phone-tablet-offline"
        }
    }

    func testMarginsIsNotRedrawnByModelPublishesThatLeaveItsListAsItWas() async throws {
        try await assertOnlyShownChangesRedraw(.margins) { model in
            model.marginCollectionQuery.filter = .shared
        }
    }

    func testSettingsIsNotRedrawnByModelPublishesThatLeaveItsRowsAsTheyWere() async throws {
        try await assertOnlyShownChangesRedraw(.settings) { model in
            model.skipUnit = model.skipUnit == "sentence" ? "paragraph" : "sentence"
        }
    }

    private func assertOnlyShownChangesRedraw(_ screen: Screen, shownChange: (Gate1AppModel) -> Void) async throws {
        let model = try makeModel()
        let mounted = try mount(screen, model: model)
        defer { mounted.close() }
        try await waitUntilQuiet(screen.rawValue)
        let before = ScreenRedrawProbe.count(screen.rawValue)
        for index in 0..<Self.publishes {
            publish(Publish.allCases[index % Publish.allCases.count], index: index, on: model)
            try await Task.sleep(for: .milliseconds(25))
        }
        try await waitUntilQuiet(screen.rawValue)
        let afterPublishes = ScreenRedrawProbe.count(screen.rawValue)
        XCTAssertLessThanOrEqual(afterPublishes - before, Self.allowedRuns,
                                 "\(screen.rawValue): \(Self.publishes) model publishes that change nothing it shows ran its body "
                                     + "\(afterPublishes - before) times")

        shownChange(model)
        try await waitUntilQuiet(screen.rawValue)
        XCTAssertGreaterThan(ScreenRedrawProbe.count(screen.rawValue), afterPublishes,
                             "\(screen.rawValue): a change it shows did not redraw it, so its feed missed the change")
    }

    // MARK: - Census

    func testCensusOfScreenRedrawsPerModelPublish() async throws {
        var lines: [String] = []
        for screen in Screen.allCases {
            for kind in Publish.allCases {
                let model = try makeModel()
                let mounted = try mount(screen, model: model)
                try await waitUntilQuiet(screen.rawValue)
                let before = ScreenRedrawProbe.count(screen.rawValue)
                for index in 0..<Self.publishes {
                    publish(kind, index: index, on: model)
                    try await Task.sleep(for: .milliseconds(25))
                }
                try await waitUntilQuiet(screen.rawValue)
                let runs = ScreenRedrawProbe.count(screen.rawValue) - before
                lines.append("\(screen.rawValue) / \(kind.rawValue): \(runs) body runs for \(Self.publishes) publishes")
                mounted.close()
            }
        }
        let census = lines.joined(separator: "\n")
        print("redraw-census\n\(census)")
        let attachment = XCTAttachment(string: census)
        attachment.name = "redraw-census"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The feed

    func testTheFeedPublishesOnlyWhenWhatItReadsChanges() async throws {
        let model = try makeModel()
        let feed = ScreenInputsFeed(model: model) { $0.skipUnit }
        var published = 0
        let subscription = feed.$inputs.dropFirst().sink { _ in published += 1 }
        defer { subscription.cancel() }

        for _ in 0..<5 { model.objectWillChange.send() }
        model.preparedTextAudioStatus = "ready"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(published, 0, "Publishes that leave the read value as it was must not reach the screen")

        let next = model.skipUnit == "sentence" ? "paragraph" : "sentence"
        model.skipUnit = next
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(published, 1)
        XCTAssertEqual(feed.inputs, next, "The feed reads the model after the write, not the value it is about to replace")
    }

    // MARK: - Publishing

    private func publish(_ kind: Publish, index: Int, on model: Gate1AppModel) {
        switch kind {
        case .plain:
            model.objectWillChange.send()
        case .renderProgress:
            model.updateOnDeviceSpeechGenerationProgress(RenderedSpeechGenerationProgress(completedChunks: 100 + index, totalChunks: 959))
        case .preparedStatus:
            model.preparedTextAudioStatus = index.isMultiple(of: 2) ? "preparing" : "ready"
        }
    }

    // MARK: - Fixtures

    private func makeModel() throws -> Gate1AppModel {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.resetAndSeed()
        model.declineCurrentTerms()
        let store = try model.requireStore()
        for index in 0..<12 {
            try store.saveItem(Item(id: "redraw-census-\(index)", title: "Fixture article \(index + 1)", mediaType: "text",
                                    text: "One.\n\nTwo.", externalReference: nil, status: "Ready"))
        }
        try model.refreshLibraryRows(store: store)
        return model
    }

    /// The app's tab bar on one tab, as `Gate1RootView` shows it.
    private struct TabsHost: View {
        @State var navigation: AppNavigationState
        let notice: SupertonicDownloadNotice

        var body: some View {
            ExperienceRootTabs(navigation: $navigation, supertonicNotice: notice)
        }
    }

    private func screenView(_ screen: Screen, model: Gate1AppModel) -> AnyView {
        var navigation = AppNavigationState()
        navigation.select(screen.root, recordingIsLocked: false)
        let notice = SupertonicDownloadNotice(defaults: UserDefaults(suiteName: "redraw-census-\(UUID().uuidString)")!,
                                              modelInstalled: { false })
        let drawer = CatalogDrawerModel(store: nil, subscriptions: { [] }, follow: { _ in "" })
        return AnyView(TabsHost(navigation: navigation, notice: notice).environmentObject(model).environmentObject(drawer))
    }

    // MARK: - Mounting

    @MainActor
    private struct Mounted {
        let window: UIWindow
        let previousKeyWindow: UIWindow?

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
    }

    private func mount(_ screen: Screen, model: Gate1AppModel) throws -> Mounted {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: screenView(screen, model: model))
        window.makeKeyAndVisible()
        return Mounted(window: window, previousKeyWindow: previousKeyWindow)
    }

    /// The screen's body-run count once it has not moved for 10 polls (0.4 s): the screen's own first-appearance work
    /// is over, so what is counted next is the publishes.
    private func waitUntilQuiet(_ screen: String) async throws {
        var last = ScreenRedrawProbe.count(screen)
        var quiet = 0
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(40))
            let now = ScreenRedrawProbe.count(screen)
            quiet = now == last ? quiet + 1 : 0
            last = now
            if quiet >= 10 { return }
        }
        XCTFail("\(screen) kept redrawing with nothing changing (\(last) body runs)")
    }
}
