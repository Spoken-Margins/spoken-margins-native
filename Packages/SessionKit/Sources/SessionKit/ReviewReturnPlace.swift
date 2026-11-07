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
    /// A Margin of the review has had the floor while the place stayed owed (the place was ahead of that Margin, so the
    /// review pulled the listener back to catch up). From then on the source is where the listener's own listening has
    /// it, as `placeToReturnToWhenStopped` treats Stop. Optional so a note saved by an earlier build still decodes; nil
    /// means no Margin has been reached yet.
    public private(set) var passedAMargin: Bool?

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
    /// Before any Margin was reached, the review's own hop is what moved the source, so any position away from the place
    /// goes back to it. After one, a position at or past the place is the listener's own listening, never rewound
    /// (#3626, the same rule Stop follows); only a position still behind the place goes back to it.
    public func needsRestoring(from savedMediaTimeMs: Int?) -> Bool {
        guard let saved = savedMediaTimeMs, (stretchStartMs...stretchEndMs).contains(saved) else { return false }
        if passedAMargin == true { return returnToMediaTimeMs - saved > Self.alreadyThereMs }
        return abs(saved - returnToMediaTimeMs) > Self.alreadyThereMs
    }
}

extension ReviewReturnPlace {
    /// Whether the place is still owed once the Margin at `marginMediaTimeMs` has the floor: only when the place is ahead
    /// of that Margin (the review pulled the listener back to catch up). The episode plays on after a Margin (#3596), so
    /// for any other listener the source is from then on where their own listening has it, and a relaunch must not send
    /// them back to the place they started from. Whether an owed place is then restored is `needsRestoring`'s question.
    public func isOwed(onceMarginAt marginMediaTimeMs: Int) -> Bool {
        returnToMediaTimeMs > marginMediaTimeMs
    }

    /// What the note is worth now that the review is in the state `sequence` says. A Margin has the floor as soon as the
    /// sequence says so, whether or not its voice ever starts (it may be unplayable, or the chime still sounding), so this
    /// is called on every change of the sequence, not from the voice's start (#3626).
    public func standing(whenReviewIs sequence: MarginMomentSequence) -> Standing {
        guard sequence.hasReachedAMargin, let playing = sequence.playing else { return .owed(self) }
        guard isOwed(onceMarginAt: playing.mediaTimeMs) else { return .released }
        var passed = self
        passed.passedAMargin = true
        return .owed(passed)
    }

    public enum Standing: Equatable, Sendable {
        /// Still owed, as this note says (the note to keep).
        case owed(ReviewReturnPlace)
        /// Nothing is owed any more: the source is where the listener's own listening has it.
        case released
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
