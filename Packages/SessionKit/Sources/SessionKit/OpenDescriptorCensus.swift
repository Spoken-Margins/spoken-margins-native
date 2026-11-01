import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One file descriptor this process has open, and what it points at (#2818).
public struct OpenDescriptor: Equatable, Sendable {
    public var descriptor: Int32
    /// The file's path, or a word for what has none: `socket`, `pipe`, `other`.
    public var target: String

    public init(descriptor: Int32, target: String) {
        self.descriptor = descriptor
        self.target = target
    }
}

/// The file descriptors this process has open now, for finding what leaks them. iOS gives an app 256, and a leak shows
/// up first as SQLite error 24 and then as every query failing (#2818). Counting `/dev/fd` says how many; this says
/// which files, so a guard that sees the count climb can name what holds it.
public enum OpenDescriptorCensus {
    /// Every open descriptor, lowest first. The descriptor the scan itself uses is never in the answer.
    public static func current() -> [OpenDescriptor] {
        let upper = Int32(min(softLimit(), 8192))
        var found: [OpenDescriptor] = []
        for descriptor in 0..<max(upper, 1) where fcntl(descriptor, F_GETFD) != -1 {
            found.append(OpenDescriptor(descriptor: descriptor, target: target(of: descriptor)))
        }
        return found
    }

    /// The most descriptors this process may have open (`RLIMIT_NOFILE`, soft).
    public static func softLimit() -> Int {
        var limit = rlimit()
        #if canImport(Darwin)
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 256 }
        #else
        guard getrlimit(__rlimit_resource_t(RLIMIT_NOFILE.rawValue), &limit) == 0 else { return 256 }
        #endif
        // "Unlimited" is a huge number; scanning that many descriptors would be pointless.
        return limit.rlim_cur > 1_000_000 ? 8192 : Int(limit.rlim_cur)
    }

    /// Open descriptors grouped by what they are, biggest group first. A test's temporary folder carries a UUID, so
    /// every store a class leaves behind collapses into one line: `summary-ownership-<id>/library.sqlite-wal`.
    public static func grouped(_ descriptors: [OpenDescriptor]) -> [(kind: String, count: Int)] {
        var counts: [String: Int] = [:]
        for descriptor in descriptors { counts[kind(of: descriptor.target), default: 0] += 1 }
        return counts.map { (kind: $0.key, count: $0.value) }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.kind < $1.kind
        }
    }

    /// `target` with its identifiers removed and only its last two path components kept.
    static func kind(of target: String) -> String {
        guard target.hasPrefix("/") else { return target }
        let components = target.split(separator: "/").map { stripIdentifiers(String($0)) }
        return components.suffix(2).joined(separator: "/")
    }

    /// Replaces each UUID in a name with `<id>`.
    static func stripIdentifiers(_ name: String) -> String {
        name.replacingOccurrences(
            of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "<id>",
            options: .regularExpression
        )
    }

    private static func target(of descriptor: Int32) -> String {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(descriptor, F_GETPATH, &buffer) != -1 { return String(cString: buffer) }
        #else
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = readlink("/proc/self/fd/\(descriptor)", &buffer, buffer.count - 1)
        if length > 0 {
            buffer[length] = 0
            let path = String(cString: buffer)
            if path.hasPrefix("/") { return path }
        }
        #endif
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return "other" }
        switch info.st_mode & S_IFMT {
        case S_IFSOCK: return "socket"
        case S_IFIFO: return "pipe"
        default: return "other"
        }
    }
}

/// How many descriptors a test run had open at the end of each test class, in the order the classes ran (#2818).
/// The test bundle's observer feeds it and the budget test reads it, so a class that leaves descriptors behind is
/// named while the run still has room, instead of 250 later tests failing with "too many open files".
public struct DescriptorLedger: Sendable {
    public struct Entry: Equatable, Sendable {
        public var group: String
        public var count: Int
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Notes the count at the end of `group`. A group seen again (its tests ran apart) updates its place in the list.
    public mutating func record(group: String, count: Int) {
        if let index = entries.firstIndex(where: { $0.group == group }) {
            entries[index].count = count
        } else {
            entries.append(Entry(group: group, count: count))
        }
    }

    public var peak: Entry? { entries.max { $0.count < $1.count } }

    /// The first group that ended with more than `budget` descriptors open.
    public func firstOver(budget: Int) -> Entry? { entries.first { $0.count > budget } }

    /// The groups that ended with more open than the one before it by at least `minimum`, biggest jump first.
    public func biggestGrowth(atLeast minimum: Int = 1) -> [(group: String, growth: Int)] {
        var previous = 0
        var growth: [(group: String, growth: Int)] = []
        for entry in entries {
            if entry.count - previous >= minimum { growth.append((entry.group, entry.count - previous)) }
            previous = entry.count
        }
        return growth.sorted { $0.growth != $1.growth ? $0.growth > $1.growth : $0.group < $1.group }
    }
}
