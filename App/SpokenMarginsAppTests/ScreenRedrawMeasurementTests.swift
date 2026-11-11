import SwiftUI
import UIKit
import XCTest
@testable import SessionKit
@testable import SpokenMarginsApp

/// Measurement for #4028: how often Following, Margins and Settings rebuild their bodies while the model publishes the
/// way it does as audio renders. Each screen is mounted alone, left to settle, then given 20 publishes of one kind, 25 ms
/// apart; the count of body runs that follow is the number. The census is attached to the run (`redraw-census`) and
/// printed, so a lane report's result bundle holds it.
///
/// The one assertion is that the probe sees a real redraw: a count of zero everywhere could mean the screens never redraw,
/// or that the probe is dead. A screen that redraws on a plain publish proves the probe works.
@MainActor
final class ScreenRedrawMeasurementTests: XCTestCase {
    private static let publishes = 20

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
    }

    func testCensusOfScreenRedrawsPerModelPublish() async throws {
        var lines: [String] = []
        var plainCounts: [Screen: Int] = [:]
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
                if kind == .plain { plainCounts[screen] = runs }
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

        for screen in Screen.allCases {
            XCTAssertGreaterThan(plainCounts[screen] ?? 0, 0,
                                 "\(screen.rawValue): a plain model publish ran no body, so the probe or the mount is not seeing redraws\n\(census)")
        }
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

    private func screenView(_ screen: Screen, model: Gate1AppModel) -> AnyView {
        switch screen {
        case .following:
            let drawer = CatalogDrawerModel(store: nil, subscriptions: { [] }, follow: { _ in "" })
            return AnyView(ExperienceSourcesScreen(scrollMemory: .constant(FollowingScrollMemory()))
                .environmentObject(model).environmentObject(drawer))
        case .margins:
            return AnyView(ExperienceMarginsScreen().environmentObject(model))
        case .settings:
            let notice = SupertonicDownloadNotice(defaults: UserDefaults(suiteName: "redraw-census-\(UUID().uuidString)")!,
                                                  modelInstalled: { false })
            return AnyView(SettingsScreen(supertonicNotice: notice).environmentObject(model))
        }
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
