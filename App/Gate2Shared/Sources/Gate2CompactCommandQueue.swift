import Foundation

public struct Gate2QueuedCompactCommand: Codable, Equatable, Sendable {
    public let id: String
    public let command: String
    public let createdAt: Double

    public init(id: String, command: String, createdAt: Double) {
        self.id = id
        self.command = command
        self.createdAt = createdAt
    }
}

public enum Gate2CompactCommandQueue {
    public static let appGroupIdentifier = "group.com.spokenmargins.native"

    private static let storageKey = "Gate2CompactCommandQueue.v1"
    private static let maximumBufferedCommands = 20

    @discardableResult
    public static func enqueue(
        command: String,
        id: String = UUID().uuidString,
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) -> Bool {
        guard let store = defaults ?? sharedDefaults() else {
            return false
        }
        var commands = load(from: store)
        commands.append(
            Gate2QueuedCompactCommand(
                id: id,
                command: command,
                createdAt: now.timeIntervalSince1970
            )
        )
        save(Array(commands.suffix(maximumBufferedCommands)), to: store)
        return true
    }

    public static func drain(defaults: UserDefaults? = nil) -> [Gate2QueuedCompactCommand] {
        guard let store = defaults ?? sharedDefaults() else {
            return []
        }
        let commands = load(from: store)
        store.removeObject(forKey: storageKey)
        store.synchronize()
        return commands
    }

    private static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    private static func load(from defaults: UserDefaults) -> [Gate2QueuedCompactCommand] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Gate2QueuedCompactCommand].self, from: data)) ?? []
    }

    private static func save(_ commands: [Gate2QueuedCompactCommand], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
    }
}

public enum Gate2CompactApplicationCommand {
    public static let summarizeInterjections = "summarizeInterjections"
    public static let discussInterjections = "discussInterjections"
}
