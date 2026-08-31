import Foundation

public enum WatchCaptureDeliveryState: String, Codable, Equatable, Hashable, Sendable {
    case savedLocally = "saved_locally"
    case queuedForPhone = "queued_for_phone"
    case transferringAudio = "transferring_audio"
    case awaitingImport = "awaiting_import"
    case synced
    case failed
}

public struct WatchCaptureAnchorReceipt: Codable, Equatable, Sendable {
    public var sessionId: String
    public var itemId: String
    public var targetType: TargetType
    public var targetId: String
    public var sourceRevision: String?
    public var snapshotRevision: String
    public var mediaTimeMs: Int?
    public var chapterId: String?
    public var transcriptSegmentId: String?
    public var playbackRateObserved: Double
    public var observedAt: Date

    public init(
        sessionId: String,
        itemId: String,
        targetType: TargetType,
        targetId: String,
        sourceRevision: String? = nil,
        snapshotRevision: String,
        mediaTimeMs: Int? = nil,
        chapterId: String? = nil,
        transcriptSegmentId: String? = nil,
        playbackRateObserved: Double = 1,
        observedAt: Date
    ) {
        self.sessionId = sessionId
        self.itemId = itemId
        self.targetType = targetType
        self.targetId = targetId
        self.sourceRevision = sourceRevision
        self.snapshotRevision = snapshotRevision
        self.mediaTimeMs = mediaTimeMs.map { max(0, $0) }
        self.chapterId = chapterId
        self.transcriptSegmentId = transcriptSegmentId
        self.playbackRateObserved = min(4, max(0.25, playbackRateObserved))
        self.observedAt = observedAt
    }
}

public struct WatchCaptureEvent: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: String
    public var id: String
    public var createdAt: Date
    public var audioFileName: String
    public var audioDurationMs: Int?
    public var anchorReceipt: WatchCaptureAnchorReceipt?

    public init(
        schemaVersion: String = "watch-capture-event.v1",
        id: String,
        createdAt: Date,
        audioFileName: String,
        audioDurationMs: Int? = nil,
        anchorReceipt: WatchCaptureAnchorReceipt?
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.audioFileName = audioFileName
        self.audioDurationMs = audioDurationMs.map { max(0, $0) }
        self.anchorReceipt = anchorReceipt
    }
}

public struct WatchCaptureOutboxRecord: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: String
    public var event: WatchCaptureEvent
    public var state: WatchCaptureDeliveryState
    public var attemptCount: Int
    public var updatedAt: Date
    public var lastAttemptAt: Date?
    public var acknowledgedAt: Date?
    public var lastError: String?

    public var id: String { event.id }

    public init(
        schemaVersion: String = "watch-capture-outbox-record.v1",
        event: WatchCaptureEvent,
        state: WatchCaptureDeliveryState = .savedLocally,
        attemptCount: Int = 0,
        updatedAt: Date,
        lastAttemptAt: Date? = nil,
        acknowledgedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.event = event
        self.state = state
        self.attemptCount = max(0, attemptCount)
        self.updatedAt = updatedAt
        self.lastAttemptAt = lastAttemptAt
        self.acknowledgedAt = acknowledgedAt
        self.lastError = lastError
    }

    public var retainsAudio: Bool {
        state != .synced
    }
}

public enum WatchCaptureOutboxError: Error, Equatable, Sendable {
    case missingEvent(String)
    case invalidTransition(eventId: String, from: WatchCaptureDeliveryState, to: WatchCaptureDeliveryState)
}

public struct WatchCaptureOutbox: Codable, Equatable, Sendable {
    public private(set) var records: [WatchCaptureOutboxRecord]

    public init(records: [WatchCaptureOutboxRecord] = []) {
        var byID: [String: WatchCaptureOutboxRecord] = [:]
        for record in records.sorted(by: Self.precedes) {
            byID[record.id] = record
        }
        self.records = byID.values.sorted(by: Self.precedes)
    }

    public func record(id: String) -> WatchCaptureOutboxRecord? {
        records.first { $0.id == id }
    }

    public var retryableRecords: [WatchCaptureOutboxRecord] {
        records.filter { [.savedLocally, .queuedForPhone, .failed].contains($0.state) }
    }

    public var unacknowledgedRecords: [WatchCaptureOutboxRecord] {
        records.filter { $0.state != .synced }
    }

    @discardableResult
    public mutating func enqueue(
        _ event: WatchCaptureEvent,
        at date: Date
    ) -> WatchCaptureOutboxRecord {
        if let existing = record(id: event.id) {
            return existing
        }
        let record = WatchCaptureOutboxRecord(event: event, updatedAt: date)
        records.append(record)
        records.sort(by: Self.precedes)
        return record
    }

    public mutating func markQueued(eventId: String, at date: Date) throws {
        try transition(eventId: eventId, to: .queuedForPhone, at: date)
    }

    public mutating func markTransferStarted(eventId: String, at date: Date) throws {
        try transition(eventId: eventId, to: .transferringAudio, at: date) { record in
            record.attemptCount += 1
            record.lastAttemptAt = date
        }
    }

    public mutating func markAwaitingImport(eventId: String, at date: Date) throws {
        try transition(eventId: eventId, to: .awaitingImport, at: date)
    }

    public mutating func markFailed(eventId: String, error: String, at date: Date) throws {
        try transition(eventId: eventId, to: .failed, at: date) { record in
            record.lastError = error
        }
    }

    public mutating func acknowledge(eventId: String, at date: Date) throws {
        guard let index = records.firstIndex(where: { $0.id == eventId }) else {
            throw WatchCaptureOutboxError.missingEvent(eventId)
        }
        if records[index].state == .synced {
            return
        }
        records[index].state = .synced
        records[index].updatedAt = date
        records[index].acknowledgedAt = date
        records[index].lastError = nil
        records.sort(by: Self.precedes)
    }

    private mutating func transition(
        eventId: String,
        to state: WatchCaptureDeliveryState,
        at date: Date,
        mutation: (inout WatchCaptureOutboxRecord) -> Void = { _ in }
    ) throws {
        guard let index = records.firstIndex(where: { $0.id == eventId }) else {
            throw WatchCaptureOutboxError.missingEvent(eventId)
        }
        let current = records[index].state
        guard Self.allowedTransitions[current, default: []].contains(state) else {
            throw WatchCaptureOutboxError.invalidTransition(eventId: eventId, from: current, to: state)
        }
        records[index].state = state
        records[index].updatedAt = date
        if state != .failed {
            records[index].lastError = nil
        }
        mutation(&records[index])
        records.sort(by: Self.precedes)
    }

    private static let allowedTransitions: [WatchCaptureDeliveryState: Set<WatchCaptureDeliveryState>] = [
        .savedLocally: [.queuedForPhone, .failed],
        .queuedForPhone: [.transferringAudio, .failed],
        .transferringAudio: [.awaitingImport, .failed],
        .awaitingImport: [.failed],
        .failed: [.queuedForPhone, .transferringAudio],
        .synced: []
    ]

    private static func precedes(_ lhs: WatchCaptureOutboxRecord, _ rhs: WatchCaptureOutboxRecord) -> Bool {
        if lhs.event.createdAt != rhs.event.createdAt {
            return lhs.event.createdAt < rhs.event.createdAt
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.id < rhs.id
    }
}

public enum WatchCaptureAnchorDecision: String, Codable, Equatable, Sendable {
    case ready
    case missingReceipt = "missing_receipt"
    case sessionMismatch = "session_mismatch"
    case itemMismatch = "item_mismatch"
    case sourceRevisionMissing = "source_revision_missing"
    case sourceRevisionMismatch = "source_revision_mismatch"
}

public enum WatchCaptureAnchorValidator {
    public static func evaluate(
        _ receipt: WatchCaptureAnchorReceipt?,
        expectedSessionId: String,
        expectedItemId: String,
        expectedSourceRevision: String?
    ) -> WatchCaptureAnchorDecision {
        guard let receipt else { return .missingReceipt }
        guard receipt.sessionId == expectedSessionId else { return .sessionMismatch }
        guard receipt.itemId == expectedItemId else { return .itemMismatch }
        if let expectedSourceRevision {
            guard let sourceRevision = receipt.sourceRevision else {
                return .sourceRevisionMissing
            }
            guard sourceRevision == expectedSourceRevision else {
                return .sourceRevisionMismatch
            }
        }
        return .ready
    }
}

public struct WatchCaptureImportLedger: Codable, Equatable, Sendable {
    public private(set) var importedEventIds: [String]

    public init(importedEventIds: [String] = []) {
        self.importedEventIds = Array(Set(importedEventIds)).sorted()
    }

    @discardableResult
    public mutating func markImported(eventId: String) -> Bool {
        guard !importedEventIds.contains(eventId) else { return false }
        importedEventIds.append(eventId)
        importedEventIds.sort()
        return true
    }

    public func contains(eventId: String) -> Bool {
        importedEventIds.contains(eventId)
    }
}
