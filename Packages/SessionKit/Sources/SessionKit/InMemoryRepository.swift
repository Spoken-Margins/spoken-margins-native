import Foundation

public final class InMemorySessionRepository: SessionRepository {
    public var items: [String: Item]
    public var mapsByItemId: [String: ListeningMap]
    public var sessions: [String: Session]
    public var interjections: [String: Interjection]
    public var turns: [String: ConversationTurn]
    public var aiJobs: [String: AIJob]

    public init(
        items: [String: Item] = [:],
        mapsByItemId: [String: ListeningMap] = [:],
        sessions: [String: Session] = [:],
        interjections: [String: Interjection] = [:],
        turns: [String: ConversationTurn] = [:],
        aiJobs: [String: AIJob] = [:]
    ) {
        self.items = items
        self.mapsByItemId = mapsByItemId
        self.sessions = sessions
        self.interjections = interjections
        self.turns = turns
        self.aiJobs = aiJobs
    }

    public func loadItem(id: String) throws -> Item {
        guard let item = items[id] else { throw SessionKitError.missingFixture(id) }
        return item
    }

    public func saveItem(_ item: Item) throws {
        items[item.id] = item
    }

    public func loadListeningMap(itemId: String) throws -> ListeningMap? {
        mapsByItemId[itemId]
    }

    public func saveListeningMap(_ map: ListeningMap) throws {
        mapsByItemId[map.itemId] = map
    }

    public func saveSession(_ session: Session) throws {
        sessions[session.id] = session
    }

    public func loadSession(id: String) throws -> Session? {
        sessions[id]
    }

    public func saveInterjection(_ interjection: Interjection) throws {
        interjections[interjection.id] = interjection
    }

    public func loadInterjections(sessionId: String) throws -> [Interjection] {
        interjections.values.filter { $0.sessionId == sessionId }.sorted { $0.createdAt < $1.createdAt }
    }

    public func saveTurn(_ turn: ConversationTurn) throws {
        turns[turn.id] = turn
    }

    public func loadTurns(sessionId: String) throws -> [ConversationTurn] {
        turns.values.filter { $0.sessionId == sessionId }.sorted { $0.id < $1.id }
    }

    public func saveAIJob(_ job: AIJob) throws {
        aiJobs[job.id] = job
    }

    public func loadAIJobs(sessionId: String) throws -> [AIJob] {
        aiJobs.values.filter { $0.sessionId == sessionId }.sorted { $0.id < $1.id }
    }

    public func updateAIJob(_ job: AIJob) throws {
        aiJobs[job.id] = job
    }
}
