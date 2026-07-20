import Foundation

public enum ContractFixtureLoader {
    public static func item(at url: URL) throws -> Item {
        let object = try object(at: url)
        let media = object["media"] as? [String: Any]
        return Item(
            id: object["id"] as? String ?? "",
            title: object["title"] as? String ?? "",
            mediaType: object["mediaType"] as? String ?? "text",
            text: object["text"] as? String,
            externalReference: object["externalReference"] as? String,
            status: object["status"] as? String ?? "ready",
            externalReferenceType: object["externalReferenceType"] as? String,
            media: media.flatMap { mediaObject in
                guard let rawSourceType = mediaObject["sourceType"] as? String,
                      let sourceType = AudioSourceType(rawValue: rawSourceType) else {
                    return nil
                }
                return ItemMedia(
                    sourceType: sourceType,
                    url: mediaObject["url"] as? String,
                    durationMs: mediaObject["durationMs"] as? Int,
                    nativeMediaId: mediaObject["nativeMediaId"] as? String
                )
            },
            transcriptId: object["transcriptId"] as? String,
            deletedAt: (object["deletedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    public static func listeningMap(at url: URL) throws -> ListeningMap {
        let object = try object(at: url)
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

    public static func session(at url: URL) throws -> Session {
        let object = try object(at: url)
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

    public static func interjection(at url: URL) throws -> Interjection {
        let object = try object(at: url)
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

    public static func turns(at url: URL) throws -> [ConversationTurn] {
        try array(at: url).map { object in
            ConversationTurn(
                id: object["id"] as? String ?? "",
                sessionId: object["sessionId"] as? String ?? "",
                role: object["role"] as? String ?? "",
                turnType: object["turnType"] as? String ?? "",
                status: object["status"] as? String ?? "",
                summary: object["summary"] as? String,
                text: object["text"] as? String,
                rawText: object["rawText"] as? String,
                chapters: (object["chapters"] as? [[String: Any]])?.map { chapter in
                    Chapter(
                        id: chapter["id"] as? String ?? "",
                        title: chapter["title"] as? String ?? "",
                        startChar: chapter["startChar"] as? Int ?? 0,
                        endChar: chapter["endChar"] as? Int ?? 0,
                        percent: chapter["percent"] as? Int ?? 0
                    )
                },
                sourceInterjectionIds: object["sourceInterjectionIds"] as? [String] ?? []
            )
        }
    }

    public static func profile(at url: URL) throws -> RuntimeCapabilityProfile {
        let object = try object(at: url)
        return RuntimeCapabilityProfile(
            id: object["id"] as? String ?? "",
            displayName: object["displayName"] as? String ?? "",
            capabilities: object["capabilities"] as? [String: [String]] ?? [:],
            forbiddenCapabilities: object["forbiddenCapabilities"] as? [String] ?? []
        )
    }

    public static func watchAudioPackage(at url: URL) throws -> WatchAudioPackage {
        let object = try object(at: url)
        let itemObject = object["item"] as? [String: Any] ?? [:]
        let transcriptObject = object["transcript"] as? [String: Any] ?? [:]
        let settingsObject = object["settings"] as? [String: Any] ?? [:]
        return WatchAudioPackage(
            schemaVersion: object["schemaVersion"] as? String ?? "watch-audio-package.v1",
            id: object["id"] as? String ?? "",
            itemId: object["itemId"] as? String ?? "",
            sessionId: object["sessionId"] as? String ?? "",
            createdAt: date(from: object["createdAt"] as? String),
            expiresAt: (object["expiresAt"] as? String).map(date(from:)),
            item: WatchPackageItem(
                title: itemObject["title"] as? String ?? "",
                mediaType: itemObject["mediaType"] as? String ?? "text",
                externalReference: itemObject["externalReference"] as? String
            ),
            audioAssets: (object["audioAssets"] as? [[String: Any]] ?? []).map { asset in
                WatchPackageAudioAsset(
                    audioAssetId: asset["audioAssetId"] as? String ?? "",
                    fileName: asset["fileName"] as? String ?? "",
                    durationMs: asset["durationMs"] as? Int ?? 0,
                    sha256: asset["sha256"] as? String
                )
            },
            transcript: WatchPackageTranscript(
                transcriptId: transcriptObject["transcriptId"] as? String ?? "",
                segments: (transcriptObject["segments"] as? [[String: Any]] ?? []).map(mediaSegment)
            ),
            chapters: (object["chapters"] as? [[String: Any]] ?? []).map(mediaChapter),
            settings: WatchPackageSettings(
                rollbackUnit: settingsObject["rollbackUnit"] as? String ?? "previous_segment",
                defaultPlaybackRate: settingsObject["defaultPlaybackRate"] as? Double ?? 1
            )
        )
    }

    public static func watchSyncEvent(at url: URL) throws -> WatchSyncEvent {
        let object = try object(at: url)
        let payload = object["payload"] as? [String: Any] ?? [:]
        return WatchSyncEvent(
            schemaVersion: object["schemaVersion"] as? String ?? "watch-sync-event.v1",
            id: object["id"] as? String ?? "",
            watchPackageId: object["watchPackageId"] as? String ?? "",
            sessionId: object["sessionId"] as? String ?? "",
            itemId: object["itemId"] as? String,
            eventType: object["eventType"] as? String ?? "",
            createdAt: date(from: object["createdAt"] as? String),
            payload: WatchSyncEventPayload(
                mediaTimeMs: payload["mediaTimeMs"] as? Int,
                chapterId: payload["chapterId"] as? String,
                transcriptSegmentId: payload["transcriptSegmentId"] as? String,
                playbackRate: payload["playbackRate"] as? Double,
                audioFileName: payload["audioFileName"] as? String,
                audioDurationMs: payload["audioDurationMs"] as? Int,
                error: payload["error"] as? String
            )
        )
    }

    private static func object(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func array(at url: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }

    private static func mediaSegment(_ object: [String: Any]) -> MediaTimelineSegment {
        MediaTimelineSegment(
            id: object["id"] as? String ?? "",
            startMs: object["startMs"] as? Int ?? 0,
            endMs: object["endMs"] as? Int ?? 0,
            startChar: object["startChar"] as? Int,
            endChar: object["endChar"] as? Int,
            text: object["text"] as? String ?? ""
        )
    }

    private static func mediaChapter(_ object: [String: Any]) -> MediaTimelineChapter {
        MediaTimelineChapter(
            id: object["id"] as? String ?? "",
            title: object["title"] as? String ?? "",
            description: object["description"] as? String,
            startMs: object["startMs"] as? Int ?? 0,
            transcriptSegmentId: object["transcriptSegmentId"] as? String ?? ""
        )
    }

    private static func date(from raw: String?) -> Date {
        guard let raw else { return Date(timeIntervalSince1970: 0) }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter().date(from: raw) ?? Date(timeIntervalSince1970: 0)
    }
}
