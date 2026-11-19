import Foundation

/// Counts of how the sharing star was changed since the last send (#4173). Counts only: no Margin id, no words, no
/// friend. It exists so a Diagnostics export can say whether a listener stars while listening or sorts at the end.
public struct ShareStarTally: Codable, Equatable, Sendable {
    /// Turned on from the row on the Now screen.
    public var starsNow = 0
    /// Turned on from the player's Margins pane.
    public var starsPlayerMargins = 0
    /// Turned on from the detail sheet, Manage Margin or the Margins tab.
    public var starsElsewhere = 0
    /// Every turn to off, wherever it came from.
    public var unstars = 0

    public init(starsNow: Int = 0, starsPlayerMargins: Int = 0, starsElsewhere: Int = 0, unstars: Int = 0) {
        self.starsNow = starsNow
        self.starsPlayerMargins = starsPlayerMargins
        self.starsElsewhere = starsElsewhere
        self.unstars = unstars
    }

    /// Adds one change. `turnedOn` is false for a star taken off, which counts as an unstar whatever the screen.
    public mutating func add(_ place: ShareStarPlace, turnedOn: Bool) {
        guard turnedOn else {
            unstars += 1
            return
        }
        switch place {
        case .now: starsNow += 1
        case .playerMargins: starsPlayerMargins += 1
        case .detail, .manage, .marginsTab: starsElsewhere += 1
        }
    }

    public mutating func reset() {
        self = ShareStarTally()
    }

    public var isEmpty: Bool { self == ShareStarTally() }
}

/// Keeps the tally in `UserDefaults` so a relaunch between starring and sending doesn't lose it (#4173). A value that
/// can't be read back counts as empty; it never blocks starring.
public struct ShareStarTallyStore: @unchecked Sendable {
    public static let key = "shareStarTally.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ShareStarTally {
        guard let data = defaults.data(forKey: Self.key),
              let tally = try? JSONDecoder().decode(ShareStarTally.self, from: data) else { return ShareStarTally() }
        return tally
    }

    @discardableResult
    public func record(_ place: ShareStarPlace, turnedOn: Bool) -> ShareStarTally {
        var tally = load()
        tally.add(place, turnedOn: turnedOn)
        save(tally)
        return tally
    }

    public func reset() {
        defaults.removeObject(forKey: Self.key)
    }

    private func save(_ tally: ShareStarTally) {
        guard let data = try? JSONEncoder().encode(tally) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
