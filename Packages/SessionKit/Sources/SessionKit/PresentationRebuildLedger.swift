import Foundation

/// Notices a sheet or full-screen cover that is built again while it is open (#4337).
///
/// A presentation that SwiftUI dismisses and presents again by itself builds a new screen: the listener sees it flash,
/// and whatever was open on it (a sheet, a half-typed field) is gone. That reached the owner's phone as #2831 and twice
/// as #4091, and no check saw it, because the redraw probes count body runs, not builds. Each presented screen reports
/// its builds, appearances and disappearances here, under a key naming the presentation and the item it shows.
///
/// A rebuild is a build of a key whose earlier build had appeared and is still showing, or went less than `window`
/// before the new one appeared. A listener can't close a screen and open the same one again inside that window: the
/// dismiss and present animations alone take longer. A build that never appeared (SwiftUI may build and drop one) is
/// not a screen anybody saw, so it never counts. A different item under the same presentation is a new screen, not a
/// rebuild.
public struct PresentationRebuildLedger: Sendable {
    public struct Rebuild: Equatable, Sendable {
        /// The presentation, as `File.swift:line`, without the item.
        public let presentation: String
        /// How long the earlier build had been gone when this one appeared; 0 when it was still showing.
        public let gapMs: Int
    }

    public static let defaultWindow: TimeInterval = 1.0

    private struct Build {
        let key: String
        let presentation: String
        var appearedAt: Date?
        var disappearedAt: Date?
        var isShowing = false
    }

    public let window: TimeInterval
    public private(set) var rebuilds: [Rebuild] = []
    private var builds: [Int: Build] = [:]
    /// The most recent build of each key that appeared: what a new build of that key is compared with.
    private var lastShown: [String: Int] = [:]

    public init(window: TimeInterval = PresentationRebuildLedger.defaultWindow) {
        self.window = window
    }

    /// The key for a presentation and the item it shows.
    public static func key(presentation: String, item: String?) -> String {
        item.map { "\(presentation)#\($0)" } ?? presentation
    }

    public mutating func built(token: Int, presentation: String, item: String?) {
        builds[token] = Build(key: Self.key(presentation: presentation, item: item), presentation: presentation)
    }

    /// Returns the rebuild this appearance makes, if it makes one.
    @discardableResult
    public mutating func appeared(token: Int, at now: Date) -> Rebuild? {
        guard var build = builds[token] else { return nil }
        let firstAppearance = build.appearedAt == nil
        build.appearedAt = build.appearedAt ?? now
        build.isShowing = true
        build.disappearedAt = nil
        builds[token] = build
        // A screen shown again after a push or a tab switch inside it is the same build, not a rebuild.
        guard firstAppearance else { return nil }
        defer { lastShown[build.key] = token }
        guard let earlierToken = lastShown[build.key], earlierToken != token, let earlier = builds[earlierToken] else { return nil }
        let rebuild: Rebuild?
        if earlier.isShowing {
            rebuild = Rebuild(presentation: build.presentation, gapMs: 0)
        } else if let gone = earlier.disappearedAt, now.timeIntervalSince(gone) < window {
            rebuild = Rebuild(presentation: build.presentation, gapMs: max(0, Int((now.timeIntervalSince(gone) * 1_000).rounded())))
        } else {
            rebuild = nil
        }
        if let rebuild { rebuilds.append(rebuild) }
        return rebuild
    }

    public mutating func disappeared(token: Int, at now: Date) {
        guard var build = builds[token], build.isShowing else { return }
        build.isShowing = false
        build.disappearedAt = now
        builds[token] = build
    }

    /// Forgets a build once its screen object is gone, unless it is the one a new build would be compared with.
    public mutating func released(token: Int) {
        guard let build = builds[token], lastShown[build.key] != token else { return }
        builds[token] = nil
    }

    /// The Diagnostics line: `none`, or each presentation's rebuild count, most first, as `File.swift:12×3`.
    public var summary: String {
        guard !rebuilds.isEmpty else { return "none" }
        let counts = Dictionary(grouping: rebuilds, by: \.presentation).mapValues(\.count)
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: ", ")
    }
}
