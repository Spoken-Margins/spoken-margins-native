import Foundation
@testable import SessionKit

enum RepoPaths {
    static func root() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: url.appending(path: "README.md").path),
               FileManager.default.fileExists(atPath: url.appending(path: "traces").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw SessionKitError.missingFixture("repo-root")
    }
}

enum JSON {
    static func object(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func array(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }
}

enum Fixtures {
    static func profile(id: String) throws -> RuntimeCapabilityProfile {
        let root = try RepoPaths.root()
        let object = try JSON.object(at: root.appending(path: "fixtures/capabilities/\(id).json"))
        return RuntimeCapabilityProfile(
            id: object["id"] as? String ?? id,
            displayName: object["displayName"] as? String ?? id,
            capabilities: object["capabilities"] as? [String: [String]] ?? [:],
            forbiddenCapabilities: object["forbiddenCapabilities"] as? [String] ?? []
        )
    }

    static func seed(trace: [String: Any], into repository: InMemorySessionRepository) throws {
        let root = try RepoPaths.root()
        let fixtures = trace["fixtures"] as? [String: Any] ?? [:]
        if let itemPath = fixtures["item"] as? String {
            let item = try item(at: root.appending(path: itemPath))
            repository.items[item.id] = item
        }
        if let mapPath = fixtures["listeningMap"] as? String {
            let map = try listeningMap(at: root.appending(path: mapPath))
            repository.mapsByItemId[map.itemId] = map
        }
        if let sessionPath = fixtures["session"] as? String {
            let session = try session(at: root.appending(path: sessionPath))
            repository.sessions[session.id] = session
        }
        if let interjectionPath = fixtures["interjection"] as? String {
            let interjection = try interjection(at: root.appending(path: interjectionPath))
            repository.interjections[interjection.id] = interjection
        }
        if let interjectionPath = fixtures["sourceInterjection"] as? String {
            var interjection = try interjection(at: root.appending(path: interjectionPath))
            interjection.sessionId = repository.sessions.values.first?.id ?? interjection.sessionId
            repository.interjections[interjection.id] = interjection
        }
        if let interjectionPath = fixtures["aiInterjection"] as? String {
            let interjection = try interjection(at: root.appending(path: interjectionPath))
            repository.interjections[interjection.id] = interjection
        }
        if let turnsPath = fixtures["turns"] as? String {
            for turn in try turns(at: root.appending(path: turnsPath)) {
                repository.turns[turn.id] = turn
            }
        }
    }

    static func item(at url: URL) throws -> Item {
        let object = try JSON.object(at: url)
        return Item(
            id: object["id"] as? String ?? "",
            title: object["title"] as? String ?? "",
            mediaType: object["mediaType"] as? String ?? "text",
            text: object["text"] as? String,
            externalReference: object["externalReference"] as? String,
            status: object["status"] as? String ?? "ready"
        )
    }

    static func listeningMap(at url: URL) throws -> ListeningMap {
        let object = try JSON.object(at: url)
        let chapters = (object["chapters"] as? [[String: Any]] ?? []).map { chapter -> Chapter in
            let resolved = chapter["resolved"] as? [String: Any] ?? [:]
            return Chapter(
                id: chapter["id"] as? String ?? "",
                title: chapter["title"] as? String ?? "",
                startChar: resolved["startChar"] as? Int ?? 0,
                endChar: resolved["endChar"] as? Int ?? 0,
                percent: resolved["percent"] as? Int ?? 0
            )
        }
        return ListeningMap(
            id: object["id"] as? String ?? "",
            itemId: object["itemId"] as? String ?? "",
            overview: object["overview"] as? String ?? "",
            chapters: chapters
        )
    }

    static func session(at url: URL) throws -> Session {
        let object = try JSON.object(at: url)
        let target = object["currentTarget"] as? [String: Any] ?? [:]
        let position = target["position"] as? [String: Any] ?? [:]
        return Session(
            id: object["id"] as? String ?? "",
            itemId: object["itemId"] as? String ?? "",
            status: object["status"] as? String ?? "in_progress",
            phase: SessionPhase(rawValue: object["phase"] as? String ?? "item_playback") ?? .itemPlayback,
            currentTargetType: TargetType(rawValue: target["targetType"] as? String ?? "item_text_tts") ?? .itemTextTTS,
            currentTargetId: target["targetId"] as? String ?? object["itemId"] as? String ?? "",
            position: Position(
                charOffset: position["charOffset"] as? Int ?? 0,
                mediaTimeMs: position["mediaTimeMs"] as? Int,
                segmentIndex: position["segmentIndex"] as? Int,
                chapterId: position["chapterId"] as? String
            ),
            completionPercent: object["completionPercent"] as? Int ?? 0,
            playbackRate: object["playbackRate"] as? Double ?? 1
        )
    }

    static func interjection(at url: URL) throws -> Interjection {
        let object = try JSON.object(at: url)
        let anchorObject = object["anchor"] as? [String: Any] ?? [:]
        let audio = object["audio"] as? [String: Any] ?? [:]
        return Interjection(
            id: object["id"] as? String ?? "",
            itemId: object["itemId"] as? String ?? "",
            sessionId: object["sessionId"] as? String ?? "",
            targetType: InterjectionTargetType(rawValue: object["targetType"] as? String ?? "item") ?? .item,
            targetId: object["targetId"] as? String ?? "",
            createdAt: ISO8601DateFormatter().date(from: object["createdAt"] as? String ?? "") ?? Date(timeIntervalSince1970: 0),
            roughPercent: object["roughPercent"] as? Int ?? 0,
            anchor: Anchor(
                anchorType: AnchorType(rawValue: anchorObject["anchorType"] as? String ?? "text") ?? .text,
                startChar: anchorObject["startChar"] as? Int ?? 0,
                endChar: anchorObject["endChar"] as? Int ?? 0,
                anchorBefore: anchorObject["anchorBefore"] as? String ?? "",
                anchorAfter: anchorObject["anchorAfter"] as? String ?? "",
                mediaTimeMs: anchorObject["mediaTimeMs"] as? Int,
                playbackRateObserved: anchorObject["playbackRateObserved"] as? Double ?? 1,
                transcriptSegmentId: anchorObject["transcriptSegmentId"] as? String,
                turnSegmentIndex: anchorObject["turnSegmentIndex"] as? Int
            ),
            audioPath: audio["path"] as? String,
            audioStatus: audio["status"] as? String ?? "missing",
            transcriptionStatus: object["transcriptionStatus"] as? String ?? "pending",
            transcript: object["transcript"] as? String,
            cleanedTranscript: object["cleanedTranscript"] as? String,
            displayText: object["cleanedTranscript"] as? String ?? object["transcript"] as? String,
            status: object["status"] as? String ?? "active"
        )
    }

    static func turns(at url: URL) throws -> [ConversationTurn] {
        try JSON.array(at: url).map { object in
            ConversationTurn(
                id: object["id"] as? String ?? "",
                sessionId: object["sessionId"] as? String ?? "",
                role: object["role"] as? String ?? "",
                turnType: object["turnType"] as? String ?? "",
                status: object["status"] as? String ?? "",
                summary: object["summary"] as? String,
                text: object["text"] as? String,
                rawText: object["rawText"] as? String,
                sourceInterjectionIds: object["sourceInterjectionIds"] as? [String] ?? []
            )
        }
    }
}
