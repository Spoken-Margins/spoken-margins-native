import SessionKit
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Mounts the real Margins screen on the route Review Margins opens (one item in scope) and measures the scope
/// control against the filters under it. A long item title once wrapped through several lines behind the
/// Mine / Starred / Shared buttons and into the group heading (#1631); the scope control now keeps one line, so its
/// height must not depend on the title and it must end above the filters. An empty list still has the scope row and
/// the filters, which is all this measures.
@MainActor
final class MarginsScopeLayoutTests: XCTestCase {
    private static let longTitle = "How to be more ambitious: A tutorial for humans with models, and why a very long title should never cover the filters"
    private static let shortTitle = "Short"
    private static let scopeIdentifier = "margins.scope.picker"
    private static let firstFilterIdentifier = "margins.filter.all"

    private static let phones: [(name: String, size: CGSize)] = [
        ("iPhone SE class", CGSize(width: 375, height: 667)),
        ("iPhone 16 class", CGSize(width: 393, height: 852)),
    ]
    private static let textSizes: [(name: String, size: DynamicTypeSize)] = [
        ("default text", .large),
        ("largest accessibility text", .accessibility5),
    ]

    func testALongItemTitleStaysOnOneLineAboveTheFilters() async throws {
        for phone in Self.phones {
            for text in Self.textSizes {
                let label = "\(phone.name), \(text.name)"
                let short = try await measure(title: Self.shortTitle, phone: phone.size, textSize: text.size)
                let long = try await measure(title: Self.longTitle, phone: phone.size, textSize: text.size)
                XCTAssertEqual(long.scope.height, short.scope.height, accuracy: 1,
                               "\(label): the long title made the scope control \(long.scope.height) points tall, not \(short.scope.height)")
                XCTAssertLessThanOrEqual(long.scope.maxY, long.filter.minY + 0.5,
                                         "\(label): the scope control (to \(long.scope.maxY)) reaches the filters (from \(long.filter.minY))")
                XCTAssertLessThanOrEqual(long.scope.maxX, phone.size.width,
                                         "\(label): the scope control runs off the screen")
                XCTAssertEqual(long.filter.minY, short.filter.minY, accuracy: 1,
                               "\(label): the long title moved the filters")
            }
        }
    }

    // MARK: - Measuring

    private struct Frames {
        let scope: CGRect
        let filter: CGRect
    }

    private func measure(title: String, phone: CGSize, textSize: DynamicTypeSize) async throws -> Frames {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("margins-scope-\(UUID().uuidString).sqlite")
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: database)
        model.libraryItems = [LibraryItemRow(id: "scope-item", title: title, status: "ready", canDelete: true)]
        model.selectedItem = ItemDetailState(id: "scope-item", title: title, text: "Some text.")
        // What Review Margins sets (ExperienceItemDetailScreen).
        model.marginCollectionQuery = MarginCollectionQuery(itemID: "scope-item")

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(
            ExperienceMarginsScreen().environmentObject(model).environment(\.dynamicTypeSize, textSize)
        ))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: phone)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        for _ in 0..<150 {
            window.layoutIfNeeded()
            if let frames = Self.frames(in: window) {
                // Let SwiftUI finish any follow-up layout pass before measuring.
                try await Task.sleep(for: .milliseconds(100))
                window.layoutIfNeeded()
                return Self.frames(in: window) ?? frames
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The mounted Margins screen never laid out its scope control and filters")
        throw NotLaidOut()
    }

    private struct NotLaidOut: Error {}

    /// The frames of the scope control and the first filter, by accessibility identifier.
    private static func frames(in window: UIWindow) -> Frames? {
        var found: [String: CGRect] = [:]
        var visited = Set<ObjectIdentifier>()
        collect(from: window, into: &found, visited: &visited)
        guard let scope = found[scopeIdentifier], let filter = found[firstFilterIdentifier],
              scope.height > 0, filter.height > 0 else { return nil }
        return Frames(scope: scope, filter: filter)
    }

    /// Walks views and the accessibility elements SwiftUI vends, which are not always views.
    private static func collect(from node: NSObject, into found: inout [String: CGRect], visited: inout Set<ObjectIdentifier>) {
        guard visited.insert(ObjectIdentifier(node)).inserted else { return }
        if node.responds(to: Selector(("accessibilityIdentifier"))),
           let identifier = node.value(forKey: "accessibilityIdentifier") as? String, !identifier.isEmpty,
           found[identifier] == nil {
            found[identifier] = node.accessibilityFrame
        }
        var children: [NSObject] = []
        if let view = node as? UIView { children += view.subviews }
        children += (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        let count = node.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            children += (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
        }
        for child in children { collect(from: child, into: &found, visited: &visited) }
    }
}
