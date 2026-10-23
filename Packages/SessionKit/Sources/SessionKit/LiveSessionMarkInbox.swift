import Foundation

/// Where a Lock Screen Mark waits for the live session screen (#2481). Each Mark is its own key, so writing a
/// Mark and reading the waiting ones never race: `drain` removes only the keys it read, and a Mark written
/// meanwhile, from this process or another, waits for the next read (#2485 audit).
///
/// Foundation only: the app and the widget extension compile this file directly, as the widget doesn't link
/// SessionKit.
public protocol LiveSessionMarkStore: AnyObject {
    func markKeys(prefix: String) -> [String]
    func markTime(forKey key: String) -> Double?
    func setMarkTime(_ time: Double, forKey key: String)
    func removeMark(forKey key: String)
}

extension UserDefaults: LiveSessionMarkStore {
    public func markKeys(prefix: String) -> [String] {
        dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
    }

    public func markTime(forKey key: String) -> Double? {
        object(forKey: key) as? Double
    }

    public func setMarkTime(_ time: Double, forKey key: String) {
        set(time, forKey: key)
    }

    public func removeMark(forKey key: String) {
        removeObject(forKey: key)
    }
}

public struct LiveSessionMarkInbox {
    public static let keyPrefix = "LiveSessionMark.v2."
    public static let maximumBufferedMarks = 500

    private let store: LiveSessionMarkStore

    public init(store: LiveSessionMarkStore) {
        self.store = store
    }

    /// Notes a Mark at `date`. Past the buffer's limit the oldest waiting Mark gives way.
    public func enqueue(_ date: Date, id: UUID = UUID()) {
        let waiting = store.markKeys(prefix: Self.keyPrefix)
        if waiting.count >= Self.maximumBufferedMarks,
           let oldest = waiting.min(by: { (store.markTime(forKey: $0) ?? 0) < (store.markTime(forKey: $1) ?? 0) }) {
            store.removeMark(forKey: oldest)
        }
        store.setMarkTime(date.timeIntervalSince1970, forKey: Self.keyPrefix + id.uuidString)
    }

    /// Returns the waiting Marks, oldest first, and removes exactly those.
    public func drain() -> [Date] {
        var times: [Double] = []
        for key in store.markKeys(prefix: Self.keyPrefix) {
            guard let time = store.markTime(forKey: key) else { continue }
            times.append(time)
            store.removeMark(forKey: key)
        }
        return times.sorted().map { Date(timeIntervalSince1970: $0) }
    }
}
