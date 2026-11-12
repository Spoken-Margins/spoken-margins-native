import Foundation

/// One edit of one field: the value, its stamp, and the stamp of every edit its writer had seen (a version vector, one
/// entry per device). The vector is what tells "this edit replaced that one" from "these two raced".
public struct SyncVersion: Codable, Hashable, Sendable {
    public var value: SyncValue
    public var stamp: SyncStamp
    /// The latest stamp seen from each device when this edit was made, its own included.
    public var seen: [String: SyncStamp]

    public init(value: SyncValue, stamp: SyncStamp, seen: [String: SyncStamp] = [:]) {
        self.value = value
        self.stamp = stamp
        var seen = seen
        seen[stamp.device] = stamp
        self.seen = seen
    }

    /// Whether `other` was made knowing this edit, so this one has been replaced and is not a rival.
    func isReplaced(by other: SyncVersion) -> Bool {
        guard other.stamp != stamp else { return false }
        return seen.allSatisfy { device, stamp in
            guard let theirs = other.seen[device] else { return false }
            return theirs >= stamp
        }
    }
}

/// One field of a record: the edits no later edit has replaced. Usually one. After a race (two devices edit the same
/// field before either has seen the other) there are two or more, and none is dropped:
///
/// - `current` is the one with the highest stamp, the same on every device;
/// - `otherValues` are the different values the rest hold, which a text field offers as "Other version" until the
///   listener picks one (`resolve`) or edits the field (`write`), either of which replaces every version this device holds.
///
/// `merged(with:)` is the union of both sides' edits with the replaced ones removed. That is commutative, associative
/// and idempotent, so applying a change twice, in any order, or after a later one, gives the same register.
public struct SyncRegister: Codable, Equatable, Sendable {
    /// Highest stamp first. Never empty.
    public private(set) var heads: [SyncVersion]

    public init(first version: SyncVersion) {
        heads = [version]
    }

    public var current: SyncVersion { heads[0] }

    /// Values that raced with `current` and lost the order, each once, newest first.
    public var otherValues: [SyncValue] {
        var seen: Set<SyncValue> = [current.value]
        var result: [SyncValue] = []
        for head in heads.dropFirst() where seen.insert(head.value).inserted {
            result.append(head.value)
        }
        return result
    }

    public func merged(with other: SyncRegister) -> SyncRegister {
        var register = self
        register.heads = Self.normalized(heads + other.heads)
        return register
    }

    /// An edit, or a pick, made on a device that holds `heads`: the new version replaces every version the device holds,
    /// as in any multi-value register. A version that raced and has not reached this device yet is not replaced and
    /// stays. So the screen must show "Other version" before it takes an edit of a field that has one; an edit then is
    /// the listener's choice. Writing the value the field already has, with nothing waiting, changes nothing.
    public mutating func write(_ value: SyncValue, clock: inout SyncClock, wallMillis: Int64) {
        guard value != current.value || heads.count > 1 else { return }
        let stamp = clock.tick(wallMillis: wallMillis)
        var seen: [String: SyncStamp] = [:]
        for head in heads {
            for (device, theirs) in head.seen {
                if let existing = seen[device], existing >= theirs { continue }
                seen[device] = theirs
            }
        }
        seen[stamp.device] = stamp
        heads = Self.normalized(heads + [SyncVersion(value: value, stamp: stamp, seen: seen)])
    }

    /// The listener's pick between versions: the same replacement as an edit, named for what the screen offers.
    public mutating func resolve(to value: SyncValue, clock: inout SyncClock, wallMillis: Int64) {
        write(value, clock: &clock, wallMillis: wallMillis)
    }

    /// The highest stamp anywhere in the register, for the receiving clock to observe.
    var highestStamp: SyncStamp {
        heads.flatMap { [$0.stamp] + Array($0.seen.values) }.max() ?? current.stamp
    }

    private static func normalized(_ versions: [SyncVersion]) -> [SyncVersion] {
        var byStamp: [SyncStamp: SyncVersion] = [:]
        for version in versions { byStamp[version.stamp] = version }
        let all = Array(byStamp.values)
        return all
            .filter { version in !all.contains { version.isReplaced(by: $0) } }
            .sorted { $0.stamp > $1.stamp }
    }
}
