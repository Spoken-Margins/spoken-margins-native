import Foundation

/// Which source-link imports are running, and whether this one may still start playback (#2135).
///
/// The busy flag was one Bool that every import set and then cleared when it ended. A second import (a link handed
/// over by the share extension while the form's was resolving) cleared it while the first was still running, which let
/// a third Add start at once. Counting the imports keeps the flag up until the last one ends.
public struct SourceLinkImportGate: Equatable, Sendable {
    public private(set) var running = 0

    public init() {}

    public var isBusy: Bool { running > 0 }

    public mutating func begin() { running += 1 }

    public mutating func end() { running = max(0, running - 1) }

    /// Whether an import may start playing the item it found. The answer is asked again once the link has resolved,
    /// because resolving takes seconds: a start the listener or an earlier import began in between wins, and the new
    /// item is only added to the Library, never swapped in for what is playing.
    public static func mayStartPlayback(requested: Bool, anotherSessionIsActive: Bool) -> Bool {
        requested && !anotherSessionIsActive
    }
}
