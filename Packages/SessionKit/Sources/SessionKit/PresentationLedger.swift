import Foundation

/// Counts sheets and full-screen covers that were built again while they were open (#4337).
///
/// A presentation that is dismissed and presented again by itself builds a new screen. The listener sees it flash,
/// and anything open on it (a sheet, a field being typed in) is lost. It reached the owner's phone as #2831, #4091
/// (twice) and #3891, and no check noticed it: the redraw probes count how often a body runs, not how often a screen
/// is built. The app reports each presentation's content appearing and disappearing here, with a token that is new
/// for every build of the content. This type holds the rule; it knows nothing about SwiftUI and takes its times as
/// arguments, so a host test can walk it through any sequence.
///
/// What counts as a rebuild: a second build of the same presentation (the same place, the same item and the same
/// window scene) that appears while the first is still showing, or within `rebuildWindow` of the first going. The same build showing
/// again is not one (a cover under another cover disappears and appears with the same token), and neither is
/// another item in the same place (a different Margin opening in the same sheet), or the same sheet in another
/// window on an iPad (two scenes share one model, so each presents the Terms or Help sheet when it is set).
///
/// The ledger holds places (a file and line in the app's own source) and counts, never an item, a title or
/// anything the listener typed, so its summary can go in the Diagnostics export.
public struct PresentationLedger: Equatable, Sendable {
    /// A build that appears this soon after another build of the same presentation went is a rebuild.
    public static let rebuildWindow: TimeInterval = 1

    /// The most recent rebuilds are kept by name, so memory stays bounded however long a screen flashes.
    public static let keptRebuilds = 20

    public enum Reason: String, Equatable, Sendable {
        /// The second build appeared while the first was still on screen.
        case whileShowing
        /// The second build appeared within `rebuildWindow` of the first going.
        case afterDismissal
    }

    public struct Rebuild: Equatable, Sendable {
        public let place: String
        public let reason: Reason
        /// The item the presentation was for, or nil for a presentation with no item. Never exported.
        public let item: String?

        /// What a failing test or a stopped app says.
        public var description: String {
            let what: String
            switch reason {
            case .whileShowing: what = "built a second time while the first was still showing"
            case .afterDismissal: what = "built again within \(Int(PresentationLedger.rebuildWindow)) s of the first going"
            }
            return "\(place)\(item.map { " for \($0)" } ?? ""): \(what)"
        }
    }

    private struct Key: Hashable, Sendable {
        let place: String
        let item: String?
        let scene: String?
    }

    private struct Gone: Equatable, Sendable {
        let instance: UUID
        let at: TimeInterval
    }

    private var showing: [UUID: Key] = [:]
    private var gone: [Key: Gone] = [:]
    /// Builds still inside the window; exposed so a test can see the ledger forgets the rest.
    var rememberedGoneCount: Int { gone.count }

    public private(set) var rebuildCount = 0
    public private(set) var whileShowingCount = 0
    public private(set) var afterDismissalCount = 0
    /// How many rebuilds each place has had.
    public private(set) var countsByPlace: [String: Int] = [:]
    /// The latest rebuilds, oldest first, at most `keptRebuilds`.
    public private(set) var recent: [Rebuild] = []

    public init() {}

    /// A presentation's content appeared. `scene` names the window it is in, nil when there is only one.
    /// `instance` is a token made once for each build of the content, so it
    /// is the same every time the same build appears and different for a new build. Returns the rebuild when
    /// this appearance is one.
    @discardableResult
    public mutating func appeared(place: String, item: String? = nil, scene: String? = nil, instance: UUID, at time: TimeInterval) -> Rebuild? {
        let key = Key(place: place, item: item, scene: scene)
        if showing[instance] != nil { return nil }
        // A build that went longer ago than the window can no longer make a rebuild, so it needn't be kept.
        gone = gone.filter { time - $0.value.at <= Self.rebuildWindow }
        var reason: Reason?
        if showing.contains(where: { $0.value == key }) {
            reason = .whileShowing
        } else if let earlier = gone[key], earlier.instance != instance, time - earlier.at <= Self.rebuildWindow {
            reason = .afterDismissal
        }
        if gone[key]?.instance == instance { gone[key] = nil }
        showing[instance] = key
        guard let reason else { return nil }
        let rebuild = Rebuild(place: place, reason: reason, item: item)
        record(rebuild)
        return rebuild
    }

    /// A presentation's content went away.
    public mutating func disappeared(instance: UUID, at time: TimeInterval) {
        guard let key = showing.removeValue(forKey: instance) else { return }
        gone[key] = Gone(instance: instance, at: time)
    }

    private mutating func record(_ rebuild: Rebuild) {
        rebuildCount += 1
        switch rebuild.reason {
        case .whileShowing: whileShowingCount += 1
        case .afterDismissal: afterDismissalCount += 1
        }
        countsByPlace[rebuild.place, default: 0] += 1
        recent.append(rebuild)
        if recent.count > Self.keptRebuilds { recent.removeFirst(recent.count - Self.keptRebuilds) }
    }

    /// The Diagnostics `screenRebuilds` line: counts and the places that rebuilt, most first. `rebuilds=0` is the
    /// healthy line.
    public var summaryText: String {
        guard rebuildCount > 0 else { return "rebuilds=0" }
        let places = countsByPlace
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(5)
            .map { "\($0.key)x\($0.value)" }
            .joined(separator: ",")
        return "rebuilds=\(rebuildCount) whileShowing=\(whileShowingCount) afterDismissal=\(afterDismissalCount) places=\(places)"
    }
}

extension PresentationLedger {
    /// A presentation's place: the file and line of the call that made it, as `PlaybackScreen:229`. Two calls never
    /// share one, so a screen presented from one place can't be mistaken for a rebuild of another's.
    public static func place(fileID: String, line: Int) -> String {
        let file = fileID.split(separator: "/").last.map(String.init) ?? fileID
        let name = file.hasSuffix(".swift") ? String(file.dropLast(".swift".count)) : file
        return "\(name):\(line)"
    }
}
