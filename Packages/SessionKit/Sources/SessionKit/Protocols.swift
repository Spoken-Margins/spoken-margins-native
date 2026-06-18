import Foundation

public protocol SessionRepository {
    func loadItem(id: String) throws -> Item
    func saveItem(_ item: Item) throws
    func loadListeningMap(itemId: String) throws -> ListeningMap?
    func saveListeningMap(_ map: ListeningMap) throws
    func saveSession(_ session: Session) throws
    func loadSession(id: String) throws -> Session?
    func saveInterjection(_ interjection: Interjection) throws
    func loadInterjections(sessionId: String) throws -> [Interjection]
    func saveTurn(_ turn: ConversationTurn) throws
    func loadTurns(sessionId: String) throws -> [ConversationTurn]
    func saveAIJob(_ job: AIJob) throws
    func loadAIJobs(sessionId: String) throws -> [AIJob]
    func updateAIJob(_ job: AIJob) throws
    func saveWatchAudioPackage(_ package: WatchAudioPackage) throws
    func loadWatchAudioPackage(id: String) throws -> WatchAudioPackage?
    func loadWatchAudioPackages(itemId: String) throws -> [WatchAudioPackage]
    func saveWatchSyncEvent(_ event: WatchSyncEvent) throws
    func loadWatchSyncEvents(sessionId: String) throws -> [WatchSyncEvent]
    func loadWatchSyncEvent(id: String) throws -> WatchSyncEvent?
    func markWatchSyncEventImported(id: String) throws
    func hasImportedWatchSyncEvent(id: String) throws -> Bool
    func saveWatchPackageRequest(_ request: WatchPackageRequestEvent) throws
    func loadWatchPackageRequests(itemId: String) throws -> [WatchPackageRequestEvent]
}

public protocol AudioPlaybackClient {
    func prepareSpeechText(_ text: String) throws -> String
    func play(targetId: String) throws
    func play(targetId: String, from charOffset: Int) throws
    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws
    func currentCharOffset() -> Int?
    func currentMediaTimeMs() -> Int?
    func isPlaybackComplete(targetId: String) -> Bool
    func pause() throws
    func stop() throws
}

public extension AudioPlaybackClient {
    func play(targetId: String, from charOffset: Int) throws {
        try play(targetId: targetId)
    }

    func play(targetId: String, fromMediaTimeMs mediaTimeMs: Int) throws {
        try play(targetId: targetId, from: mediaTimeMs)
    }

    func stop() throws {
        try pause()
    }

    func currentCharOffset() -> Int? {
        nil
    }

    func currentMediaTimeMs() -> Int? {
        nil
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        false
    }
}

public protocol RecordingClient {
    func beginRecording() throws
    func finishRecording(audioRef: String?) throws -> String
    func cancelRecording() throws
}

public protocol TranscriptionClient {
    func scheduleTranscription(interjection: Interjection) throws
}

public protocol AIProviderClient {
    var providerType: String { get }
    var model: String { get }
    func shouldStartProviderCall(profile: RuntimeCapabilityProfile, kind: String) -> Bool
}

public extension AIProviderClient {
    func shouldStartProviderCall(profile: RuntimeCapabilityProfile, kind: String) -> Bool {
        switch kind {
        case "interjection_summary":
            return profile.has("ai", "summarize_interjections")
        case "assistant_response":
            return profile.has("ai", "continue_discussion")
        default:
            return false
        }
    }
}
