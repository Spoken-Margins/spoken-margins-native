import Darwin
import SessionKit
import SessionKitPersistence
import SQLite3
import SwiftUI
import UIKit
import XCTest
@testable import SpokenMarginsApp

/// Proves the 2026-10-18 accessibility fixes on the mounted views, so the unattended lane can close them instead of
/// an agent-driven Test Desk journey. Each test fails on the code before its fix:
///
/// - #1916 (PR #1999): hand-built screen titles carry the header trait.
/// - #1919 (PR #2003): the catalog's in-progress and Retry controls name the show.
/// - #1922 (PR #2005): Increase Contrast strengthens the border; Differentiate Without Color adds the chip's glyph.
/// - #1934 (PR #2016): the Add Source picker is one column and the Paste button stacks at accessibility sizes, and
///   a catalog row's Follow control sits under the title instead of beside it.
/// - #1936 (PR #2017): a Following inbox title wraps fully at accessibility sizes.
/// - #1937 (PR #2018): the Library row's play circle grows with the text.
/// - #1969 (PR #2013): a Library this build can't open says so, never "Your Library is ready".
///
/// SwiftUI builds its accessibility tree only when an assistive client is running, and an app-hosted test has none:
/// an earlier mounted test found the tree empty (PlaybackDockLayoutTests, #1666) and UIKit's own traits missing
/// (#428). The class turns on accessibility automation, as AccessibilitySnapshot does, before mounting anything, and
/// every tree test first checks the tree is there, so an empty tree fails with that reason rather than a wrong one.
@MainActor
final class AccessibilityFixProofTests: XCTestCase {
    private static var automationWasEnabled: Int32?

    override class func setUp() {
        super.setUp()
        automationWasEnabled = AccessibilityAutomation.enable()
    }

    override class func tearDown() {
        if let automationWasEnabled { AccessibilityAutomation.set(automationWasEnabled) }
        super.tearDown()
    }

    // MARK: - #1916 screen titles are headings

    func testAddSourceAndTermsTitlesAreHeadings() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        for (title, view) in [
            ("Add to Library", AnyView(ExperienceAddSourceFlow(initialRoute: .linkOrPodcast).environmentObject(model))),
            ("Spoken Margins Terms of Use", AnyView(SpokenMarginsTermsView(allowsAcceptance: false).environmentObject(model))),
        ] {
            let mounted = try mount(view)
            defer { mounted.close() }
            let node = try await mounted.waitForNode(title) { $0.label == title }
            XCTAssertTrue(node.traits.contains(.header), "\(title) is not a heading; traits \(node.traits.rawValue)")
        }
    }

    // MARK: - #1919 catalog controls name the show

    func testCatalogRowInProgressAndRetryControlsNameTheShow() async throws {
        let entry = Self.catalogEntry(title: "The Daily Example")
        let following = try mount(AnyView(CatalogDrawerRow(entry: entry, state: .following, toggleFollow: {})))
        let spinner = try await following.waitForNode("the Following spinner") { $0.label == "Following The Daily Example" }
        XCTAssertNotNil(spinner)
        following.close()

        let failed = try mount(AnyView(CatalogDrawerRow(entry: entry, state: .failed("Couldn’t reach the feed"), toggleFollow: {})))
        defer { failed.close() }
        let retry = try await failed.waitForNode("the Retry button") {
            $0.identifier == "catalog.follow.\(entry.id)" || $0.label?.hasPrefix("Retry") == true
        }
        XCTAssertEqual(retry.label, "Retry following The Daily Example")
    }

    // MARK: - #1922 Increase Contrast and Differentiate Without Color

    func testIncreaseContrastStrengthensTheBorderInBothAppearances() {
        let border = UIColor(AppColors.border)
        for (style, expected) in [(UIUserInterfaceStyle.light, AppSemanticColorRGB.borderIncreased.light),
                                  (.dark, AppSemanticColorRGB.borderIncreased.dark)] {
            let normal = border.resolvedColor(with: UITraitCollection { traits in
                traits.userInterfaceStyle = style
                traits.accessibilityContrast = .normal
            })
            let increased = border.resolvedColor(with: UITraitCollection { traits in
                traits.userInterfaceStyle = style
                traits.accessibilityContrast = .high
            })
            let (red, green, blue) = Self.rgb(increased)
            let plain = Self.rgb(normal)
            XCTAssertFalse(plain.0 == red && plain.1 == green && plain.2 == blue,
                           "\(style.rawValue): Increase Contrast left the border unchanged")
            XCTAssertEqual(red, expected.red, accuracy: 0.01)
            XCTAssertEqual(green, expected.green, accuracy: 0.01)
            XCTAssertEqual(blue, expected.blue, accuracy: 0.01)
        }
    }

    func testDifferentiateWithoutColorAddsAGlyphToTheActiveChipOnly() {
        func width(active: Bool, differentiate: Bool) -> CGFloat {
            UIHostingController(rootView: ExperienceFilterChip(isActive: active) { Text("All") }
                .environment(\._accessibilityDifferentiateWithoutColor, differentiate))
                .sizeThatFits(in: CGSize(width: 400, height: 200)).width
        }
        XCTAssertGreaterThan(width(active: true, differentiate: true), width(active: true, differentiate: false) + 8,
                             "The active chip shows its state by colour alone under Differentiate Without Color")
        XCTAssertEqual(width(active: false, differentiate: true), width(active: false, differentiate: false), accuracy: 0.5,
                       "An inactive chip gains nothing")
    }

    // MARK: - #1934 Add Source picker, Paste bar and catalog rows at accessibility sizes

    func testAddSourcePickerIsOneColumnAtAccessibilitySizesAndTwoByDefault() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        for (size, stacked) in [(DynamicTypeSize.large, false), (.accessibility3, true)] {
            let mounted = try mount(AnyView(ExperienceAddSourceFlow(initialRoute: .linkOrPodcast).environmentObject(model)),
                                    textSize: size)
            defer { mounted.close() }
            let link = try await mounted.waitForNode("the Link or Podcast tile") {
                $0.identifier == "addSource.route.linkOrPodcast" || $0.label?.hasPrefix("Link or Podcast,") == true
            }
            let text = try await mounted.waitForNode("the Paste Text tile") {
                $0.identifier == "addSource.route.pastedText" || $0.label?.hasPrefix("Paste Text,") == true
            }
            if stacked {
                XCTAssertEqual(text.frame.minX, link.frame.minX, accuracy: 1, "\(size): the tiles are not one column")
                XCTAssertGreaterThanOrEqual(text.frame.minY, link.frame.maxY - 1, "\(size): Paste Text is not under Link or Podcast")
            } else {
                XCTAssertGreaterThanOrEqual(text.frame.minX, link.frame.maxX - 1, "\(size): the tiles are not side by side")
            }
        }
    }

    func testPasteButtonStacksUnderItsTextAtAccessibilitySizes() async throws {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        let width: CGFloat = 390
        for (size, stacked) in [(DynamicTypeSize.large, false), (.accessibility3, true)] {
            let mounted = try mount(AnyView(PasteAndGoBar(onAdded: {}).environmentObject(model)), textSize: size,
                                    width: width)
            defer { mounted.close() }
            // The system draws PasteButton's control and its "Paste" label; SwiftUI's label and identifier don't reach it.
            let paste = try await mounted.waitForNode("the Paste button") {
                $0.identifier == "addSource.pasteAndGo.button" || $0.label == "Paste"
            }
            if stacked {
                XCTAssertLessThan(paste.frame.minX, 60, "\(size): the Paste button sits beside the text at x \(paste.frame.minX)")
            } else {
                XCTAssertGreaterThan(paste.frame.minX, width / 2, "\(size): the Paste button is not beside the text")
            }
        }
    }

    func testCatalogRowFollowControlSitsUnderTheTitleAtAccessibilitySizes() async throws {
        let entry = Self.catalogEntry(title: "The Daily Example")
        for (size, stacked) in [(DynamicTypeSize.large, false), (.accessibility3, true)] {
            let mounted = try mount(AnyView(CatalogDrawerRow(entry: entry, state: nil, toggleFollow: {})), textSize: size)
            defer { mounted.close() }
            let title = try await mounted.waitForNode("the show title") { $0.label == entry.title }
            let follow = try await mounted.waitForNode("the Follow button") {
                $0.identifier == "catalog.follow.\(entry.id)" || $0.label == "Follow \(entry.title)"
            }
            if stacked {
                XCTAssertGreaterThanOrEqual(follow.frame.minY, title.frame.maxY - 1, "\(size): Follow is beside the title, not under it")
            } else {
                XCTAssertGreaterThanOrEqual(follow.frame.minX, title.frame.maxX - 1, "\(size): Follow is not beside the title")
            }
        }
    }

    // MARK: - #1936 Following inbox titles wrap

    /// Before the fix the title stopped at two lines at every size, so a long title and a two-line one made rows of
    /// the same height. At accessibility sizes the row now grows with the title; at the default size it still doesn't.
    func testFollowingInboxTitleWrapsFullyOnlyAtAccessibilitySizes() throws {
        let twoLines = "A title that wraps onto a second line"
        let long = Array(repeating: "a very long episode title that keeps going", count: 8).joined(separator: " ")
        let accessible = [twoLines, long].map { inboxRowHeight(title: $0, textSize: .accessibility3) }
        XCTAssertGreaterThan(accessible[1], accessible[0] + 100,
                             "At accessibility sizes the long title was cut: \(accessible[1]) vs \(accessible[0]) pt")
        let standard = [twoLines, long].map { inboxRowHeight(title: $0, textSize: .large) }
        XCTAssertEqual(standard[1], standard[0], accuracy: 30, "At the default size the row should keep its two-line cap (#884)")
    }

    private func inboxRowHeight(title: String, textSize: DynamicTypeSize) -> CGFloat {
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient())
        model.quickAccess.recentFiles = []
        model.libraryItems = []
        model.feedSubscriptions = []
        model.followedSourceEntries = [FeedEntry(id: "episode", subscriptionId: "show", canonicalURL: "https://example.com/e/1",
                                                 title: title, publishedAt: Date(timeIntervalSince1970: 50))]
        guard let candidate = model.quickAddCandidates.first(where: { $0.id == "followed-source:episode" }) else {
            XCTFail("The followed entry is not an inbox candidate")
            return 0
        }
        let row = SourceInboxRow(candidate: candidate, artwork: FollowingArtworkCache())
            .environmentObject(model)
            .environment(\.dynamicTypeSize, textSize)
        return UIHostingController(rootView: row).sizeThatFits(in: CGSize(width: 390, height: 4_000)).height
    }

    // MARK: - #1937 Library row play button

    func testLibraryPlayCircleGrowsWithTheText() {
        func size(_ textSize: DynamicTypeSize) -> CGSize {
            UIHostingController(rootView: LibraryRowPlayLabel(isReadyOffline: true, isPreparing: false)
                .environment(\.dynamicTypeSize, textSize))
                .sizeThatFits(in: CGSize(width: 400, height: 400))
        }
        let standard = size(.large)
        let largest = size(.accessibility5)
        XCTAssertEqual(standard.height, TapTarget.minimum, accuracy: 0.5, "The default circle keeps its 44 pt hit area")
        XCTAssertGreaterThan(largest.height, standard.height + 10, "At the largest size the circle stayed \(largest.height) pt")
        XCTAssertLessThanOrEqual(largest.height, 80.5, "The circle grows at most to twice its size")
    }

    // MARK: - #1969 a Library this build can't open

    func testALibraryThisBuildCannotOpenShowsTheSafeNoteNotTheEmptyState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "a11y-future-schema-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "library.sqlite")
        do {
            let store = try SQLiteSessionStore(path: databaseURL.path)
            try store.saveItem(Item(id: "item-future", title: "Do Not Delete", mediaType: "text", text: "Keep this.",
                                    externalReference: nil, status: "ready"))
        }
        try Self.setSchemaVersion(99, at: databaseURL)
        let model = Gate1AppModel(audioPlaybackClient: NoopAudioPlaybackClient(), databaseURLOverride: databaseURL)
        model.bootstrapLibraryIfNeeded()
        XCTAssertNotNil(model.libraryAccessError, "precondition: the future schema must not open")

        let mounted = try mount(AnyView(ExperienceLibraryScreen(addSourceRoute: .constant(nil), scrollMemory: .constant(FollowingScrollMemory())).environmentObject(model)))
        defer { mounted.close() }
        let title = try await mounted.waitForNode("the cannot-open title") { $0.label == LibraryAccessNote.title }
        XCTAssertTrue(title.traits.contains(.header))
        let nodes = mounted.nodes()
        XCTAssertTrue(nodes.contains { $0.identifier == "library.cannotOpen.retry" || $0.label == "Try again" },
                      "No Try again button: saw \(nodes.compactMap(\.label).prefix(30))")
        XCTAssertFalse(nodes.contains { $0.label == "Your Library is ready" }, "The happy empty state is showing")
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: databaseURL.path), 99, "The Library was touched")
    }

    // MARK: - Helpers

    private static func catalogEntry(title: String) -> SourceCatalogEntry {
        SourceCatalogEntry(id: "daily-example", kind: .podcastFeed, contentKind: .podcast, title: title, author: "Example Radio",
                           feedURL: "https://example.com/feed.xml", subjects: ["News"], provenanceIds: [])
    }

    private static func rgb(_ color: UIColor) -> (Double, Double, Double) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue))
    }

    private static func setSchemaVersion(_ version: Int, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else { throw NSError(domain: "AccessibilityFixProofTests", code: 1) }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "UPDATE metadata SET value = '\(version)' WHERE key = 'schema_version';", nil, nil, nil) == SQLITE_OK
        else { throw NSError(domain: "AccessibilityFixProofTests", code: 2) }
    }

    private func mount(_ view: AnyView, textSize: DynamicTypeSize = .large, width: CGFloat = 390) throws -> MountedTree {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: AnyView(view.environment(\.dynamicTypeSize, textSize)))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        return MountedTree(window: window, previousKeyWindow: previousKeyWindow)
    }
}

/// Turns on the accessibility automation flag an assistive client would set, so UIKit loads its accessibility
/// bundles and SwiftUI vends its tree in-process. Test-only and simulator-only; the app never calls it.
enum AccessibilityAutomation {
    private typealias Getter = @convention(c) () -> Int32
    private typealias Setter = @convention(c) (Int32) -> Void

    private static let handle: UnsafeMutableRawPointer? = {
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        return dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW) ?? dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
    }()

    /// Returns the previous value, or nil when the library or its functions are missing.
    static func enable() -> Int32? {
        guard let handle, let getter = dlsym(handle, "_AXSAutomationEnabled") else { return nil }
        let previous = unsafeBitCast(getter, to: Getter.self)()
        set(1)
        return previous
    }

    static func set(_ value: Int32) {
        guard let handle, let setter = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
        unsafeBitCast(setter, to: Setter.self)(value)
    }
}

@MainActor
struct AccessibilityNode {
    let label: String?
    let identifier: String?
    let traits: UIAccessibilityTraits
    let frame: CGRect
}

@MainActor
struct MountedTree {
    let window: UIWindow
    let previousKeyWindow: UIWindow?

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKeyAndVisible()
    }

    /// Every labelled or identified node: views, and the elements SwiftUI vends, which are not always views.
    func nodes() -> [AccessibilityNode] {
        window.layoutIfNeeded()
        var found: [AccessibilityNode] = []
        var visited = Set<ObjectIdentifier>()
        Self.collect(window, into: &found, visited: &visited)
        return found
    }

    /// Waits up to five seconds for a node. When none appears, the failure says whether the tree was empty, which
    /// means accessibility never turned on rather than the fix being missing.
    func waitForNode(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                     _ matches: (AccessibilityNode) -> Bool) async throws -> AccessibilityNode {
        var seen: [AccessibilityNode] = []
        for _ in 0..<100 {
            seen = nodes()
            if let node = seen.first(where: matches) { return node }
            try await Task.sleep(for: .milliseconds(50))
        }
        let labelled = seen.filter { $0.label?.isEmpty == false }
        let reason = labelled.isEmpty
            ? "the accessibility tree was empty, so accessibility automation did not turn on"
            : "saw \(labelled.prefix(30).map { "\($0.label ?? "")[\($0.identifier ?? "")]" })"
        XCTFail("Never found \(description): \(reason)", file: file, line: line)
        throw NodeNotFound()
    }

    private struct NodeNotFound: Error {}

    private static func collect(_ node: NSObject, into found: inout [AccessibilityNode], visited: inout Set<ObjectIdentifier>) {
        guard visited.insert(ObjectIdentifier(node)).inserted else { return }
        let identifier = Self.identifier(of: node)
        let label = node.accessibilityLabel
        if label?.isEmpty == false || identifier?.isEmpty == false {
            found.append(AccessibilityNode(label: label, identifier: identifier, traits: node.accessibilityTraits,
                                           frame: node.accessibilityFrame))
        }
        var children: [NSObject] = []
        if let view = node as? UIView { children += view.subviews }
        children += (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        let count = node.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            children += (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
        }
        for child in children { collect(child, into: &found, visited: &visited) }
    }

    /// SwiftUI's vended elements answer `accessibilityIdentifier` without declaring `UIAccessibilityIdentification`,
    /// so a protocol cast reads nothing (the first T3 run on #2049 saw every identifier empty). Ask by selector.
    private static func identifier(of node: NSObject) -> String? {
        if let identifier = (node as? UIAccessibilityIdentification)?.accessibilityIdentifier, !identifier.isEmpty {
            return identifier
        }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue() as? String
    }
}
