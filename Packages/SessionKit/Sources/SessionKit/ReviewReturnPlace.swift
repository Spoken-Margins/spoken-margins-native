import Foundation

/// The place a "Review new Margins" (#474) owes the listener. A review moves the source between Margins, so the
/// session is saved wherever the review has got to. The review hands the listener's place back itself when it ends in
/// the app, but not when the app is killed mid-review. This is the note that lets the app put it back at the next launch.
public struct ReviewReturnPlace: Codable, Equatable, Sendable {
    /// How far past its last Margin a review can leave the source: the lead-in is shorter, and a voice holds it still.
    public static let slackMs = 15_000
    /// A saved position this close to the place is already there.
    public static let alreadyThereMs = 500

    public let itemId: String
    /// Where the listener left off.
    public let returnToMediaTimeMs: Int
    /// Where a review can have left the source: from the first lead-in to just past the last Margin.
    public let stretchStartMs: Int
    public let stretchEndMs: Int

    /// The place a review about to start owes. Nil for a moment that isn't a review, or one that has no place to go back to.
    public init?(sequence: MarginMomentSequence) {
        guard let review = sequence.review, let returnTo = review.returnToMediaTimeMs,
              let last = sequence.unplayed.last else { return nil }
        itemId = sequence.itemId
        returnToMediaTimeMs = returnTo
        stretchStartMs = sequence.startMediaTimeMs
        stretchEndMs = last.mediaTimeMs + Self.slackMs
    }

    /// Whether `savedMediaTimeMs`, where the session was saved or the source stands now, is somewhere the review put it.
    /// A position outside the stretch was reached some other way (the listener scrubbed or listened on), and is theirs.
    public func needsRestoring(from savedMediaTimeMs: Int?) -> Bool {
        guard let saved = savedMediaTimeMs, (stretchStartMs...stretchEndMs).contains(saved) else { return false }
        return abs(saved - returnToMediaTimeMs) > Self.alreadyThereMs
    }
}

/// The places owed to the listener, kept across launches (UserDefaults only: nothing in the database changes).
/// One per item, since only one review runs at a time.
public struct ReviewReturnPlaces {
    private static let key = "spokenmargins.reviewReturnPlaces"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func owe(_ place: ReviewReturnPlace) {
        var all = load()
        all[place.itemId] = place
        save(all)
    }

    public func owed(itemId: String) -> ReviewReturnPlace? {
        load()[itemId]
    }

    public func clear(itemId: String) {
        var all = load()
        guard all.removeValue(forKey: itemId) != nil else { return }
        save(all)
    }

    /// Forgets every place: at launch, once the one that matters has been given back.
    public func removeAll() {
        defaults.removeObject(forKey: Self.key)
    }

    private func load() -> [String: ReviewReturnPlace] {
        guard let data = defaults.data(forKey: Self.key),
              let all = try? JSONDecoder().decode([String: ReviewReturnPlace].self, from: data) else { return [:] }
        return all
    }

    private func save(_ all: [String: ReviewReturnPlace]) {
        if all.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
