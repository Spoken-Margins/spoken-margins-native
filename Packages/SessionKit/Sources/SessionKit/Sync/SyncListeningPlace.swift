import Foundation

/// Where a listener is in an item, as seen across devices (`place/<item key>`). Two registers:
///
/// - `place`: position, the source revision it is a position in, and how it got there. Its stamp is when playback
///   **advanced the place or the listener deliberately moved it** (a seek or rewind is a play event). The stamp is
///   made when that happens, not when the record is saved or uploaded, so a place uploaded late loses to newer listening.
/// - `completion`: set when the item was finished, for one source revision.
///
/// Furthest-wins would undo a rewind made on purpose; latest-saved-wins would let a phone left paused overwrite
/// today's listening. Most recent play wins avoids both.
public enum ListeningPlaceSync {
    public static let schemaVersion = 1

    /// A place as the sync layer holds it, and as a device is asked to take it.
    public struct Place: Equatable, Sendable {
        public var position: SyncValue
        /// What the position is a position in: the exact-edition hash or text digest. A different revision means a
        /// different recording or text, and the same number may point somewhere else.
        public var sourceRevision: String
        public var stamp: SyncStamp
        public var cause: Cause
        /// When the item was finished in this revision, if it was and nothing was played after.
        public var completedAt: SyncStamp?

        public var isCompleted: Bool { completedAt != nil }
    }

    public enum Cause: String, Sendable { case play, seek }

    /// What this device holds: its own place, the revision of the copy it has, and when it last played.
    public struct LocalPlace: Equatable, Sendable {
        public var sourceRevision: String
        public var lastPlayedAt: SyncStamp?
        public var isCompleted: Bool

        public init(sourceRevision: String, lastPlayedAt: SyncStamp?, isCompleted: Bool = false) {
            self.sourceRevision = sourceRevision
            self.lastPlayedAt = lastPlayedAt
            self.isCompleted = isCompleted
        }
    }

    /// What a device does with a place that arrived.
    public enum Application: Equatable, Sendable {
        /// Do nothing: this device played more recently, or the same.
        case keepLocal
        /// Move to the place.
        case adopt(Place)
        /// This device is playing now. Never move it; offer "Continue on this phone?" once it stops.
        case deferUntilStopped(Place)
        /// A different source revision: do not apply, offer "Continue where you were on your other device".
        case offer(Place)
        /// The place is not newer, but the item was finished after this device last played it: mark it finished.
        case markCompleted
    }

    /// A listener played or moved: one new place, stamped at the time it happened.
    public static func recordPlay(
        position: SyncValue, sourceRevision: String, cause: Cause = .play,
        in record: inout SyncRecord, clock: inout SyncClock, atMillis: Int64
    ) {
        record.set("place", .object([
            "position": position, "revision": .string(sourceRevision), "cause": .string(cause.rawValue),
            // A play at the same spot as the last is still a new play: the value differs, so its stamp is new.
            "at": .number(Double(atMillis))
        ]), clock: &clock, wallMillis: atMillis)
    }

    public static func recordCompletion(
        sourceRevision: String, in record: inout SyncRecord, clock: inout SyncClock, atMillis: Int64
    ) {
        record.set("completion", .object(["revision": .string(sourceRevision), "at": .number(Double(atMillis))]), clock: &clock, wallMillis: atMillis)
    }

    public static func place(of record: SyncRecord) -> Place? {
        guard let register = record.register("place"), let fields = register.current.value.objectValue,
              let position = fields["position"], let revision = fields["revision"]?.stringValue else { return nil }
        let stamp = register.current.stamp
        var completedAt: SyncStamp?
        if let done = record.register("completion"), done.current.value.objectValue?["revision"]?.stringValue == revision,
           done.current.stamp > stamp {
            completedAt = done.current.stamp
        }
        return Place(
            position: position, sourceRevision: revision, stamp: stamp,
            cause: Cause(rawValue: fields["cause"]?.stringValue ?? "") ?? .play, completedAt: completedAt
        )
    }

    /// What to do with `remote` on a device. A pure rule: applying a place is never itself a play, so it writes nothing
    /// back and two devices cannot pass one place between them forever.
    public static func decide(remote: Place, local: LocalPlace, isPlaying: Bool) -> Application {
        let remoteIsNewer = local.lastPlayedAt.map { remote.stamp > $0 } ?? true
        guard remoteIsNewer else {
            // Finishing is sticky only within one revision, and only if this device has not played since.
            if let finished = remote.completedAt, remote.sourceRevision == local.sourceRevision, !local.isCompleted,
               local.lastPlayedAt.map({ finished > $0 }) ?? true {
                return .markCompleted
            }
            return .keepLocal
        }
        if remote.sourceRevision != local.sourceRevision { return .offer(remote) }
        return isPlaying ? .deferUntilStopped(remote) : .adopt(remote)
    }
}
