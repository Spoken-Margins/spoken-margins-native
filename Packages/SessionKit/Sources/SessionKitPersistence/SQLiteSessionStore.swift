import Foundation
import SessionKit
import SQLite3

public final class SQLiteSessionStore: SessionRepositoryTransaction, @unchecked Sendable {
    /// Schema 5 adds record kinds and optional payload fields to the generic
    /// records table; it does not change the SQLite table layout. Sharing builds
    /// must accept it so installing this lane over another active lane does not
    /// make the existing library appear empty.
    public static let currentSchemaVersion = 5
    private static let sessionScopedRecordKinds: Set<String> = ["interjection", "turn", "ai_job"]
    private var db: OpaquePointer?
    private let connectionLock = NSRecursiveLock()
    /// How many `withTransaction` calls are open on this connection. Guarded by `connectionLock`.
    private var transactionDepth = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(path: String) throws {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        guard sqlite3_open_v2(
            path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("sqlite_open")
        }
        // WAL permits concurrent readers, but only one connection may write.
        // Allow brief independent transactions to finish instead of dropping a save.
        sqlite3_busy_timeout(db, 1_000)
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public func migrate() throws {
        try withConnectionLock {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("""
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
        let existingVersion = try metadataValue(forKey: "schema_version").flatMap(Int.init)
        guard existingVersion.map({ [1, 2, 3, 4, Self.currentSchemaVersion].contains($0) }) ?? true else {
            throw SessionKitError.persistenceFailed("unsupported_schema_version:\(existingVersion ?? -1)")
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS records (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            session_id TEXT,
            item_id TEXT,
            payload TEXT NOT NULL,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY(kind, id)
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS quarantined_records (
            kind TEXT NOT NULL,
            id TEXT NOT NULL,
            payload TEXT NOT NULL,
            decode_error TEXT NOT NULL,
            quarantined_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY(kind, id)
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS records_session_idx ON records(kind, session_id);")
        try execute("CREATE INDEX IF NOT EXISTS records_item_idx ON records(kind, item_id);")
        if existingVersion == 1 || existingVersion == 2 {
            try migrateSessionTimestamps()
        }
        if let existingVersion, existingVersion < 4 {
            try migrateSessionScopedRecordKeys()
        }
            try setMetadataValue("\(Self.currentSchemaVersion)", forKey: "schema_version")
        }
    }

    public func reset() throws {
        try withTransaction {
            try execute("DELETE FROM records;")
            try execute("DELETE FROM quarantined_records;")
        }
    }

    public func quarantinedRecordCount() throws -> Int {
        try withConnectionLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM quarantined_records;", -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_quarantine_count")
            }
            defer { if statement != nil { sqlite3_finalize(statement) } }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SessionKitError.persistenceFailed("step_quarantine_count")
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func loadItem(id: String) throws -> Item {
        try load(kind: "item", id: id)
    }

    public func saveItem(_ item: Item) throws {
        try save(kind: "item", id: item.id, sessionId: nil, itemId: item.id, value: item)
    }

    public func loadListeningMap(itemId: String) throws -> ListeningMap? {
        let maps: [ListeningMap] = try loadByItem(kind: "listening_map", itemId: itemId)
        return maps.first
    }

    public func saveListeningMap(_ map: ListeningMap) throws {
        try withTransaction {
            try deleteRecords(kind: "listening_map", itemId: map.itemId)
            try save(kind: "listening_map", id: map.id, sessionId: nil, itemId: map.itemId, value: map)
        }
    }

    public func saveSession(_ session: Session) throws {
        try save(kind: "session", id: session.id, sessionId: session.id, itemId: session.itemId, value: session)
    }

    public func loadSession(id: String) throws -> Session? {
        try loadOptional(kind: "session", id: id)
    }

    public func loadSessions(itemId: String) throws -> [Session] {
        let sessions: [Session] = try loadByItem(kind: "session", itemId: itemId)
        return sessions.sorted(by: Self.isNewerSession)
    }

    public func loadSessions() throws -> [Session] {
        let sessions: [Session] = try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id DESC;",
            ["session"]
        )
        return sessions.sorted(by: Self.isNewerSession)
    }

    public func saveInterjection(_ interjection: Interjection) throws {
        try save(kind: "interjection", id: interjection.id, sessionId: interjection.sessionId, itemId: interjection.itemId, value: interjection)
    }

    public func loadInterjections(sessionId: String) throws -> [Interjection] {
        try loadBySession(kind: "interjection", sessionId: sessionId)
    }

    public func saveInterjectionShareRevision(_ revision: InterjectionShareRevision) throws {
        try withTransaction {
            let existing: InterjectionShareRevision? = try loadOptional(
                kind: "interjection_share_revision",
                id: revision.id
            )
            if let existing {
                guard try encoder.encode(existing) == encoder.encode(revision) else {
                    throw SessionKitError.persistenceFailed("interjection_share_revision_immutable_conflict")
                }
                return
            }
            try save(
                kind: "interjection_share_revision",
                id: revision.id,
                sessionId: revision.sessionId,
                itemId: revision.itemId,
                value: revision
            )
        }
    }

    public func loadInterjectionShareRevisions(interjectionId: String) throws -> [InterjectionShareRevision] {
        let revisions: [InterjectionShareRevision] = try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at ASC, id ASC;",
            ["interjection_share_revision"]
        )
        return revisions.filter { $0.interjectionId == interjectionId }
    }

    public func importCommentaryLayer(
        _ layer: ImportedCommentaryLayer,
        interjections: [ImportedCommentaryInterjection]
    ) throws -> ImportedCommentaryImportDisposition {
        var disposition: ImportedCommentaryImportDisposition?
        try withTransaction {
            let existing: ImportedCommentaryLayer? = try loadImportedCommentaryLayer(packageDigest: layer.packageDigest)
            if let existing {
                disposition = .duplicate(existingLayerId: existing.id)
                return
            }
            let conflictingLayer: ImportedCommentaryLayer? = try loadOptional(
                kind: "imported_commentary_layer",
                id: layer.id
            )
            guard conflictingLayer == nil else {
                throw SessionKitError.persistenceFailed("imported_commentary_local_id_conflict")
            }
            for interjection in interjections {
                let conflict: ImportedCommentaryInterjection? = try loadOptional(
                    kind: "imported_commentary_interjection",
                    id: interjection.id
                )
                guard conflict == nil else {
                    throw SessionKitError.persistenceFailed("imported_commentary_local_id_conflict")
                }
            }
            try save(
                kind: "imported_commentary_layer",
                id: layer.id,
                sessionId: nil,
                itemId: layer.itemId,
                value: layer
            )
            for interjection in interjections {
                try save(
                    kind: "imported_commentary_interjection",
                    id: interjection.id,
                    sessionId: nil,
                    itemId: layer.itemId,
                    value: interjection
                )
            }
            disposition = .imported(layerId: layer.id, interjectionIds: interjections.map(\.id))
        }
        guard let disposition else {
            throw SessionKitError.persistenceFailed("imported_commentary_disposition_missing")
        }
        return disposition
    }

    public func loadImportedCommentaryLayer(id: String) throws -> ImportedCommentaryLayer? {
        try loadOptional(kind: "imported_commentary_layer", id: id)
    }

    public func loadImportedCommentaryLayer(packageDigest: String) throws -> ImportedCommentaryLayer? {
        let layers: [ImportedCommentaryLayer] = try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at ASC, id ASC;",
            ["imported_commentary_layer"]
        )
        return layers.first { $0.packageDigest == packageDigest }
    }

    public func loadImportedCommentaryLayers() throws -> [ImportedCommentaryLayer] {
        try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at ASC, id ASC;",
            ["imported_commentary_layer"]
        )
    }

    public func loadImportedCommentaryLayers(itemId: String) throws -> [ImportedCommentaryLayer] {
        try loadByItem(kind: "imported_commentary_layer", itemId: itemId)
    }

    public func loadImportedCommentaryInterjections(layerId: String) throws -> [ImportedCommentaryInterjection] {
        // Filter before decoding: opening one layer must not materialize every
        // imported recording, transcript and anchor in the Library.
        try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? AND CASE WHEN json_valid(payload) THEN json_extract(payload, '$.layerId') = ? ELSE 1 END ORDER BY updated_at ASC, id ASC;",
            ["imported_commentary_interjection", layerId]
        )
    }

    public func saveImportedCommentaryLayer(_ layer: ImportedCommentaryLayer) throws {
        try save(
            kind: "imported_commentary_layer",
            id: layer.id,
            sessionId: nil,
            itemId: layer.itemId,
            value: layer
        )
    }

    public func saveImportedCommentaryInterjection(_ interjection: ImportedCommentaryInterjection) throws {
        let layer = try loadImportedCommentaryLayer(id: interjection.layerId)
        try save(
            kind: "imported_commentary_interjection",
            id: interjection.id,
            sessionId: nil,
            itemId: layer?.itemId,
            value: interjection
        )
    }

    public func saveTurn(_ turn: ConversationTurn) throws {
        try save(kind: "turn", id: turn.id, sessionId: turn.sessionId, itemId: nil, value: turn)
    }

    public func loadTurns(sessionId: String) throws -> [ConversationTurn] {
        try loadBySession(kind: "turn", sessionId: sessionId)
    }

    public func saveAIJob(_ job: AIJob) throws {
        try save(kind: "ai_job", id: job.id, sessionId: job.sessionId, itemId: job.itemId, value: job)
    }

    public func loadAIJobs(sessionId: String) throws -> [AIJob] {
        try loadBySession(kind: "ai_job", sessionId: sessionId)
    }

    public func updateAIJob(_ job: AIJob) throws {
        try saveAIJob(job)
    }

    public func saveWatchAudioPackage(_ package: WatchAudioPackage) throws {
        try save(kind: "watch_audio_package", id: package.id, sessionId: package.sessionId, itemId: package.itemId, value: package)
    }

    public func loadWatchAudioPackage(id: String) throws -> WatchAudioPackage? {
        try loadOptional(kind: "watch_audio_package", id: id)
    }

    public func loadWatchAudioPackages(itemId: String) throws -> [WatchAudioPackage] {
        try loadByItem(kind: "watch_audio_package", itemId: itemId)
    }

    public func saveWatchSyncEvent(_ event: WatchSyncEvent) throws {
        try save(kind: "watch_sync_event", id: event.id, sessionId: event.sessionId, itemId: event.itemId, value: event)
    }

    public func loadWatchSyncEvents(sessionId: String) throws -> [WatchSyncEvent] {
        try loadBySession(kind: "watch_sync_event", sessionId: sessionId)
    }

    public func loadWatchSyncEvent(id: String) throws -> WatchSyncEvent? {
        try loadOptional(kind: "watch_sync_event", id: id)
    }

    public func markWatchSyncEventImported(id: String) throws {
        let marker = ImportedWatchSyncEvent(id: id, importedAt: Date())
        try save(kind: "imported_watch_sync_event", id: id, sessionId: nil, itemId: nil, value: marker)
    }

    public func hasImportedWatchSyncEvent(id: String) throws -> Bool {
        let marker: ImportedWatchSyncEvent? = try loadOptional(kind: "imported_watch_sync_event", id: id)
        return marker != nil
    }

    public func saveWatchPackageRequest(_ request: WatchPackageRequestEvent) throws {
        try save(kind: "watch_package_request", id: request.id, sessionId: nil, itemId: request.itemId, value: request)
    }

    public func loadWatchPackageRequests(itemId: String) throws -> [WatchPackageRequestEvent] {
        try loadByItem(kind: "watch_package_request", itemId: itemId)
    }

    public func saveTranscriptTimeline(_ transcript: SourceTranscriptTimeline) throws {
        try save(kind: "source_transcript_timeline", id: transcript.id, sessionId: nil, itemId: transcript.itemId, value: transcript)
    }

    public func loadTranscriptTimeline(id: String) throws -> SourceTranscriptTimeline? {
        try loadOptional(kind: "source_transcript_timeline", id: id)
    }

    public func loadTranscriptTimeline(itemId: String) throws -> SourceTranscriptTimeline? {
        let transcripts: [SourceTranscriptTimeline] = try loadByItem(kind: "source_transcript_timeline", itemId: itemId)
        return transcripts.last
    }

    public func saveAudioAsset(_ asset: AudioAsset) throws {
        try save(kind: "audio_asset", id: asset.id, sessionId: nil, itemId: asset.itemId, value: asset)
    }

    public func loadAudioAssets(itemId: String) throws -> [AudioAsset] {
        try loadByItem(kind: "audio_asset", itemId: itemId)
    }

    public func deleteAudioAsset(id: String) throws {
        try deleteRecord(kind: "audio_asset", id: id)
    }

    public func savePodcastDownload(_ record: PodcastDownloadRecord) throws {
        try save(kind: "podcast_download", id: record.id, sessionId: nil, itemId: record.itemId, value: record)
    }

    public func loadPodcastDownload(itemId: String) throws -> PodcastDownloadRecord? {
        let records: [PodcastDownloadRecord] = try loadByItem(kind: "podcast_download", itemId: itemId)
        return records.last
    }

    public func loadPodcastDownloads() throws -> [PodcastDownloadRecord] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id;", ["podcast_download"])
    }

    public func deletePodcastDownload(id: String) throws {
        try deleteRecord(kind: "podcast_download", id: id)
    }

    public func saveCanonicalSource(_ source: CanonicalSourcePackage) throws {
        try withTransaction {
            try deleteRecords(kind: "canonical_source", itemId: source.itemId)
            try save(kind: "canonical_source", id: source.id, sessionId: nil, itemId: source.itemId, value: source)
        }
    }

    public func loadCanonicalSource(itemId: String) throws -> CanonicalSourcePackage? {
        let values: [CanonicalSourcePackage] = try loadByItem(kind: "canonical_source", itemId: itemId)
        return values.last
    }

    public func publishImportedSource(item: Item, canonicalSource: CanonicalSourcePackage?, listeningMap: ListeningMap?, audioAsset: AudioAsset?, ownedAsset: OwnedOfflineAsset) throws {
        try withTransaction {
            try saveItem(item)
            if let canonicalSource {
                try deleteRecords(kind: "canonical_source", itemId: item.id)
                try save(kind: "canonical_source", id: canonicalSource.id, sessionId: nil, itemId: item.id, value: canonicalSource)
            }
            if let listeningMap {
                try deleteRecords(kind: "listening_map", itemId: item.id)
                try save(kind: "listening_map", id: listeningMap.id, sessionId: nil, itemId: item.id, value: listeningMap)
            }
            if let audioAsset { try saveAudioAsset(audioAsset) }
            try saveOwnedOfflineAsset(ownedAsset)
        }
    }

    public func savePreparedAudioManifest(_ manifest: PreparedAudioManifest) throws {
        try save(kind: "prepared_audio_manifest", id: manifest.id, sessionId: nil, itemId: manifest.itemId, value: manifest)
    }

    public func loadPreparedAudioManifest(id: String) throws -> PreparedAudioManifest? {
        try loadOptional(kind: "prepared_audio_manifest", id: id)
    }

    public func loadPreparedAudioManifests(itemId: String) throws -> [PreparedAudioManifest] {
        try loadByItem(kind: "prepared_audio_manifest", itemId: itemId)
    }

    /// Loads every manifest in one query for Library presentation. Callers that
    /// already have the concrete SQLite store can avoid issuing one query per item.
    public func loadPreparedAudioManifests() throws -> [PreparedAudioManifest] {
        try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;",
            ["prepared_audio_manifest"]
        )
    }

    public func deletePreparedAudioManifest(id: String) throws { try deleteRecord(kind: "prepared_audio_manifest", id: id) }

    public func saveAudioPreparationJob(_ job: AudioPreparationJob) throws {
        try save(kind: "audio_preparation_job", id: job.id, sessionId: nil, itemId: job.itemId, value: job)
    }

    public func loadAudioPreparationJobs() throws -> [AudioPreparationJob] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;", ["audio_preparation_job"])
    }

    public func deleteAudioPreparationJob(id: String) throws { try deleteRecord(kind: "audio_preparation_job", id: id) }

    public func deleteAudioPreparationJobs(ids: [String]) throws {
        let uniqueIds = Array(Set(ids))
        guard !uniqueIds.isEmpty else { return }
        try withTransaction {
            for id in uniqueIds {
                try deleteRecord(kind: "audio_preparation_job", id: id)
            }
        }
    }

    public func saveEditionFingerprintSpine(_ spine: EditionFingerprintSpineArtifact) throws {
        try withTransaction {
            try deleteRecords(kind: "edition_fingerprint_spine", itemId: spine.itemId)
            try save(kind: "edition_fingerprint_spine", id: spine.id, sessionId: nil, itemId: spine.itemId, value: spine)
        }
    }

    public func loadEditionFingerprintSpine(itemId: String) throws -> EditionFingerprintSpineArtifact? {
        let values: [EditionFingerprintSpineArtifact] = try loadByItem(kind: "edition_fingerprint_spine", itemId: itemId)
        return values.last
    }

    public func saveTranscriptPhraseSketch(_ sketch: TranscriptPhraseSketchArtifact) throws {
        try withTransaction {
            try deleteRecords(kind: "transcript_phrase_sketch", itemId: sketch.itemId)
            try save(kind: "transcript_phrase_sketch", id: sketch.id, sessionId: nil, itemId: sketch.itemId, value: sketch)
        }
    }

    public func loadTranscriptPhraseSketch(itemId: String) throws -> TranscriptPhraseSketchArtifact? {
        let values: [TranscriptPhraseSketchArtifact] = try loadByItem(kind: "transcript_phrase_sketch", itemId: itemId)
        return values.last
    }

    public func savePortableListeningMapProposal(_ proposal: PortableListeningMapProposalArtifact, itemId: String) throws {
        try save(kind: "portable_listening_map_proposal", id: proposal.id, sessionId: nil, itemId: itemId, value: proposal)
    }

    public func loadPortableListeningMapProposals(itemId: String) throws -> [PortableListeningMapProposalArtifact] {
        try loadByItem(kind: "portable_listening_map_proposal", itemId: itemId)
    }

    public func saveResolvedListeningMapProjection(_ projection: ResolvedListeningMapProjection) throws {
        try withTransaction {
            try deleteRecords(kind: "resolved_listening_map_projection", itemId: projection.itemId)
            try save(kind: "resolved_listening_map_projection", id: projection.id, sessionId: nil, itemId: projection.itemId, value: projection)
        }
    }

    public func loadResolvedListeningMapProjection(itemId: String) throws -> ResolvedListeningMapProjection? {
        let values: [ResolvedListeningMapProjection] = try loadByItem(kind: "resolved_listening_map_projection", itemId: itemId)
        return values.last
    }

    public func saveEpisodeMapPreparationJob(_ job: EpisodeMapPreparationJob) throws {
        try save(kind: "episode_map_preparation_job", id: job.id, sessionId: nil, itemId: job.itemId, value: job)
    }

    public func loadEpisodeMapPreparationJobs() throws -> [EpisodeMapPreparationJob] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;", ["episode_map_preparation_job"])
    }

    public func deleteEpisodeMapPreparationJob(id: String) throws {
        try deleteRecord(kind: "episode_map_preparation_job", id: id)
    }

    public func saveOfflineStorageBudget(_ budget: OfflineStorageBudget) throws {
        try save(kind: "offline_storage_budget", id: "default", sessionId: nil, itemId: nil, value: budget)
    }

    public func loadOfflineStorageBudget() throws -> OfflineStorageBudget {
        try loadOptional(kind: "offline_storage_budget", id: "default") ?? OfflineStorageBudget()
    }

    public func saveOwnedOfflineAsset(_ asset: OwnedOfflineAsset) throws {
        try save(kind: "owned_offline_asset", id: asset.id, sessionId: nil, itemId: asset.itemId, value: asset)
    }

    public func loadOwnedOfflineAssets() throws -> [OwnedOfflineAsset] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;", ["owned_offline_asset"])
    }

    public func deleteOwnedOfflineAsset(id: String) throws { try deleteRecord(kind: "owned_offline_asset", id: id) }

    @discardableResult
    public func updateOwnedOfflineAsset(id: String, _ change: (inout OwnedOfflineAsset) -> Void) throws -> OwnedOfflineAsset? {
        try withTransaction {
            guard var asset: OwnedOfflineAsset = try loadOptional(kind: "owned_offline_asset", id: id) else { return nil }
            change(&asset)
            try saveOwnedOfflineAsset(asset)
            return asset
        }
    }

    public func saveOfflineStorageReservation(_ reservation: OfflineStorageReservation) throws {
        try save(kind: "offline_storage_reservation", id: reservation.id, sessionId: nil, itemId: nil, value: reservation)
    }

    public func loadOfflineStorageReservations() throws -> [OfflineStorageReservation] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at, id;", ["offline_storage_reservation"])
    }

    public func deleteOfflineStorageReservation(id: String) throws { try deleteRecord(kind: "offline_storage_reservation", id: id) }

    public func saveFeedSubscription(_ subscription: FeedSubscription) throws {
        try save(kind: "feed_subscription", id: subscription.id, sessionId: nil, itemId: nil, value: subscription)
    }

    /// Collections are their own record kind with no item_id, so Build 29 (which reads every
    /// record by an explicit kind) never sees them, and deleting an item never deletes one (#489).
    public func saveItemCollection(_ collection: ItemCollection) throws {
        try save(kind: "item_collection", id: collection.id, sessionId: nil, itemId: nil, value: collection)
    }

    /// Oldest first, so the listener's collections keep a stable order.
    public func loadItemCollections() throws -> [ItemCollection] {
        let collections: [ItemCollection] = try query(
            "SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY id;",
            ["item_collection"]
        )
        return collections.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func deleteItemCollection(id: String) throws {
        try deleteRecord(kind: "item_collection", id: id)
    }

    public func loadFeedSubscriptions() throws -> [FeedSubscription] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id;", ["feed_subscription"])
    }

    public func deleteFeedSubscription(id: String) throws {
        let entries: [FeedEntry] = try loadFeedEntries(subscriptionId: id)
        try withTransaction {
            for entry in entries where entry.state != .imported { try deleteRecord(kind: "feed_entry", id: entry.id) }
            try deleteRecord(kind: "feed_subscription", id: id)
        }
    }

    public func saveFeedEntry(_ entry: FeedEntry) throws {
        try save(kind: "feed_entry", id: entry.id, sessionId: nil, itemId: nil, value: entry)
    }

    public func loadFeedEntries(subscriptionId: String?) throws -> [FeedEntry] {
        let entries: [FeedEntry] = try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id;", ["feed_entry"])
        return entries.filter { subscriptionId == nil || $0.subscriptionId == subscriptionId }
    }

    public func deleteFeedEntry(id: String) throws { try deleteRecord(kind: "feed_entry", id: id) }

    public func saveFeedRefreshState(_ state: FeedRefreshState) throws {
        try save(kind: "feed_refresh_state", id: state.subscriptionId, sessionId: nil, itemId: nil, value: state)
    }

    public func loadFeedRefreshState(subscriptionId: String) throws -> FeedRefreshState? {
        try loadOptional(kind: "feed_refresh_state", id: subscriptionId)
    }

    public func saveSourceSuggestionDecision(_ decision: SourceSuggestionDecision) throws {
        try save(kind: "source_suggestion_decision", id: decision.sourceId, sessionId: nil, itemId: nil, value: decision)
    }

    public func loadSourceSuggestionDecision(sourceId: String) throws -> SourceSuggestionDecision? {
        try loadOptional(kind: "source_suggestion_decision", id: sourceId)
    }

    public func seed(item: Item) throws {
        try saveItem(item)
    }

    public func seed(map: ListeningMap) throws {
        try saveListeningMap(map)
    }

    public func seed(interjection: Interjection) throws {
        try saveInterjection(interjection)
    }

    public func seed(turn: ConversationTurn) throws {
        try saveTurn(turn)
    }

    public func listItems(includeDeleted: Bool = false) throws -> [Item] {
        let items: [Item] = try query("SELECT kind, id, payload FROM records WHERE kind = ? ORDER BY updated_at DESC, id;", ["item"])
        return includeDeleted ? items : items.filter { $0.deletedAt == nil }
    }

    public func listDeletedItems() throws -> [Item] {
        try listItems(includeDeleted: true)
            .filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    public func moveItemToTrash(id: String, at date: Date = Date()) throws {
        var item = try loadItem(id: id)
        item.deletedAt = date
        try saveItem(item)
    }

    public func restoreItem(id: String) throws {
        var item = try loadItem(id: id)
        item.deletedAt = nil
        try saveItem(item)
    }

    public func deleteItem(id: String) throws {
        try withConnectionLock {
            var statement: OpaquePointer?
            let sql = "DELETE FROM records WHERE item_id = ? OR (kind = 'item' AND id = ?);"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_delete_item")
            }
            defer { if statement != nil { sqlite3_finalize(statement) } }
            bind(statement, index: 1, value: id)
            bind(statement, index: 2, value: id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_delete_item")
            }
        }
    }

    /// Permanently removes several item graphs as one database operation. Callers
    /// validate the trash boundary before invoking this method; the transaction
    /// prevents a bulk-empty action from leaving only part of the selection behind.
    public func deleteItems(ids: [String]) throws {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard !uniqueIDs.isEmpty else { return }
        try withTransaction {
            for id in uniqueIDs {
                try deleteItem(id: id)
            }
        }
    }

    private func deleteRecords(kind: String, itemId: String) throws {
        try withConnectionLock {
            var statement: OpaquePointer?
            let sql = "DELETE FROM records WHERE kind = ? AND item_id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_delete_records")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: kind)
            bind(statement, index: 2, value: itemId)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_delete_records")
            }
        }
    }

    private func deleteRecord(kind: String, id: String) throws {
        try withConnectionLock {
            var statement: OpaquePointer?
            let sql = "DELETE FROM records WHERE kind = ? AND id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_delete_record")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: kind)
            bind(statement, index: 2, value: id)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_delete_record")
            }
        }
    }

    private func save<T: Encodable>(kind: String, id: String, sessionId: String?, itemId: String?, value: T) throws {
        try withConnectionLock {
            let data = try encoder.encode(value)
            guard let payload = String(data: data, encoding: .utf8) else {
                throw SessionKitError.persistenceFailed("json_encoding")
            }
            var statement: OpaquePointer?
            let sql = """
            INSERT INTO records(kind, id, session_id, item_id, payload)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(kind, id) DO UPDATE SET
                session_id = excluded.session_id,
                item_id = excluded.item_id,
                payload = excluded.payload,
                updated_at = CURRENT_TIMESTAMP;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_save")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: kind)
            bind(statement, index: 2, value: storageID(kind: kind, id: id, sessionId: sessionId))
            bind(statement, index: 3, value: sessionId)
            bind(statement, index: 4, value: itemId)
            bind(statement, index: 5, value: payload)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_save:\(sqlite3_extended_errcode(db)):\(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    private func load<T: Decodable>(kind: String, id: String) throws -> T {
        guard let value: T = try loadOptional(kind: kind, id: id) else {
            throw SessionKitError.missingFixture("\(kind):\(id)")
        }
        return value
    }

    private func loadOptional<T: Decodable>(kind: String, id: String) throws -> T? {
        let values: [T] = try query("SELECT kind, id, payload FROM records WHERE kind = ? AND id = ?;", [kind, id])
        return values.first
    }

    private func loadBySession<T: Decodable>(kind: String, sessionId: String) throws -> [T] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? AND session_id = ? ORDER BY updated_at, id;", [kind, sessionId])
    }

    private func loadByItem<T: Decodable>(kind: String, itemId: String) throws -> [T] {
        try query("SELECT kind, id, payload FROM records WHERE kind = ? AND item_id = ? ORDER BY updated_at, id;", [kind, itemId])
    }

    private func query<T: Decodable>(_ sql: String, _ values: [String]) throws -> [T] {
        try withConnectionLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_query")
            }
            defer { if statement != nil { sqlite3_finalize(statement) } }
            for (index, value) in values.enumerated() {
                bind(statement, index: Int32(index + 1), value: value)
            }
            var decoded: [T] = []
            var corrupt: [(kind: String, id: String, payload: String, error: String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawKind = sqlite3_column_text(statement, 0),
                      let rawID = sqlite3_column_text(statement, 1),
                      let raw = sqlite3_column_text(statement, 2) else { continue }
                let kind = String(cString: rawKind)
                let id = String(cString: rawID)
                let payload = String(cString: raw)
                guard let data = payload.data(using: .utf8) else { continue }
                do {
                    decoded.append(try decoder.decode(T.self, from: data))
                } catch {
                    corrupt.append((kind: kind, id: id, payload: payload, error: String(describing: error)))
                }
            }
            sqlite3_finalize(statement)
            statement = nil
            if !corrupt.isEmpty {
                try withTransaction {
                    for record in corrupt {
                        try quarantine(kind: record.kind, id: record.id, payload: record.payload, error: record.error)
                    }
                }
            }
            return decoded
        }
    }

    private static func isNewerSession(_ lhs: Session, _ rhs: Session) -> Bool {
        let lhsDate = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
        let rhsDate = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
        return lhsDate == rhsDate ? lhs.id > rhs.id : lhsDate > rhsDate
    }

    private func migrateSessionTimestamps() throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, payload, updated_at FROM records WHERE kind = 'session';",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_session_timestamp_migration")
        }
        var updates: [(id: String, payload: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = sqlite3_column_text(statement, 0),
                  let rawPayload = sqlite3_column_text(statement, 1),
                  let rawUpdatedAt = sqlite3_column_text(statement, 2),
                  let data = String(cString: rawPayload).data(using: .utf8),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let id = String(cString: rawID)
            let timestamp = Self.iso8601Timestamp(fromSQLite: String(cString: rawUpdatedAt))
            if object["createdAt"] == nil { object["createdAt"] = timestamp }
            if object["updatedAt"] == nil { object["updatedAt"] = timestamp }
            if object["completedAt"] == nil {
                object["completedAt"] = object["status"] as? String == "finished" ? timestamp : NSNull()
            }
            guard let migrated = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let payload = String(data: migrated, encoding: .utf8) else { continue }
            updates.append((id, payload))
        }
        sqlite3_finalize(statement)
        statement = nil

        try withTransaction {
            for update in updates {
                var updateStatement: OpaquePointer?
                guard sqlite3_prepare_v2(
                    db,
                    "UPDATE records SET payload = ? WHERE kind = 'session' AND id = ?;",
                    -1,
                    &updateStatement,
                    nil
                ) == SQLITE_OK else {
                    throw SessionKitError.persistenceFailed("prepare_session_timestamp_update")
                }
                bind(updateStatement, index: 1, value: update.payload)
                bind(updateStatement, index: 2, value: update.id)
                let result = sqlite3_step(updateStatement)
                sqlite3_finalize(updateStatement)
                guard result == SQLITE_DONE else {
                    throw SessionKitError.persistenceFailed("step_session_timestamp_update")
                }
            }
        }
    }

    /// Turns, interjections, and AI jobs use IDs that are intentionally local to a
    /// listening session (for example, `turn-response-001`). The records table has
    /// a `(kind, id)` primary key, so storing those logical IDs directly allowed a
    /// later session to move and overwrite an earlier session's record. Keep the
    /// payload IDs unchanged while making only the internal SQLite key session-scoped.
    private func migrateSessionScopedRecordKeys() throws {
        for kind in Self.sessionScopedRecordKinds.sorted() {
            var statement: OpaquePointer?
            let sql = """
            UPDATE records
            SET id = session_id || '::' || id
            WHERE kind = ?
              AND session_id IS NOT NULL
              AND id NOT LIKE session_id || '::%';
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_session_scoped_key_migration")
            }
            bind(statement, index: 1, value: kind)
            let result = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else {
                throw SessionKitError.persistenceFailed("step_session_scoped_key_migration")
            }
        }
    }

    private func storageID(kind: String, id: String, sessionId: String?) -> String {
        guard Self.sessionScopedRecordKinds.contains(kind), let sessionId else { return id }
        return "\(sessionId)::\(id)"
    }

    private static func iso8601Timestamp(fromSQLite value: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = parser.date(from: value) else { return value }
        return ISO8601DateFormatter().string(from: date)
    }

    public static func schemaVersion(atPath path: String) -> Int? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM metadata WHERE key = 'schema_version';",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return Int(String(cString: raw))
    }

    private func quarantine(kind: String, id: String, payload: String, error: String) throws {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO quarantined_records(kind, id, payload, decode_error)
        VALUES(?, ?, ?, ?)
        ON CONFLICT(kind, id) DO UPDATE SET
            payload = excluded.payload,
            decode_error = excluded.decode_error,
            quarantined_at = CURRENT_TIMESTAMP;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_quarantine")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: kind)
        bind(statement, index: 2, value: id)
        bind(statement, index: 3, value: payload)
        bind(statement, index: 4, value: String(error.prefix(2_000)))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed("step_quarantine")
        }
        try deleteQuarantinedSource(kind: kind, id: id)
    }

    private func deleteQuarantinedSource(kind: String, id: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM records WHERE kind = ? AND id = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_quarantine_delete")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: kind)
        bind(statement, index: 2, value: id)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed("step_quarantine_delete")
        }
    }

    /// Runs `operation` in one transaction. A call made inside another joins the open transaction, because
    /// SQLite can't nest them: a read inside `updateOwnedOfflineAsset` that meets a malformed row quarantines
    /// it in the update's transaction (#529 audit). If anything in the outer transaction throws, all of it
    /// rolls back, the quarantine included, and the next read quarantines the row again.
    public func withSessionTransaction<T>(_ operation: () throws -> T) throws -> T {
        try withTransaction(operation)
    }

    private func withTransaction<T>(_ operation: () throws -> T) throws -> T {
        try withConnectionLock {
            guard transactionDepth == 0 else { return try operation() }
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            do {
                let result = try operation()
                try execute("COMMIT;")
                return result
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    private func metadataValue(forKey key: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE key = ?;", -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_metadata_read")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: key)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    private func setMetadataValue(_ value: String, forKey key: String) throws {
        var statement: OpaquePointer?
        let sql = "INSERT INTO metadata(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SessionKitError.persistenceFailed("prepare_metadata_write")
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: key)
        bind(statement, index: 2, value: value)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SessionKitError.persistenceFailed("step_metadata_write")
        }
    }

    private func execute(_ sql: String) throws {
        try withConnectionLock {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw SessionKitError.persistenceFailed(message)
            }
        }
    }

    private func withConnectionLock<T>(_ operation: () throws -> T) rethrows -> T {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return try operation()
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct ImportedWatchSyncEvent: Codable {
    var id: String
    var importedAt: Date
}

/// I13 documents live in the existing records table as kind
/// "structured_document", one row per item and extraction version. No table or
/// column changes, and schema_version stays 5: Build 29 selects records by kind
/// and never reads this one, and deleting the item removes its rows.
extension SQLiteSessionStore: StructuredDocumentRepository {
    static let structuredDocumentKind = "structured_document"

    public func saveStructuredDocument(_ document: StructuredDocument, itemId: String) throws {
        try save(
            kind: Self.structuredDocumentKind,
            id: "\(itemId)#v\(document.extraction.version)",
            sessionId: nil,
            itemId: itemId,
            value: document
        )
    }

    public func loadStructuredDocument(itemId: String) throws -> StructuredDocument? {
        let documents: [StructuredDocument] = try loadByItem(kind: Self.structuredDocumentKind, itemId: itemId)
        return documents.max { $0.extraction.version < $1.extraction.version }
    }

    /// The items that have a structured document, read without decoding the
    /// documents, so the Library can mark new-reader PDFs cheaply (#359).
    public func loadStructuredDocumentItemIds() throws -> Set<String> {
        try withConnectionLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT DISTINCT item_id FROM records WHERE kind = ? AND item_id IS NOT NULL;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else {
                throw SessionKitError.persistenceFailed("prepare_structured_document_item_ids")
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, index: 1, value: Self.structuredDocumentKind)
            var itemIds: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = sqlite3_column_text(statement, 0) else { continue }
                itemIds.insert(String(cString: raw))
            }
            return itemIds
        }
    }

    public func applyStructuredDocumentUpgrade(_ upgrade: StructuredDocumentUpgrade) throws {
        let itemId = upgrade.item.id
        try withTransaction {
            try upgrade.validateBaseline(repository: self)
            try saveItem(upgrade.item)
            try deleteRecords(kind: "listening_map", itemId: itemId)
            if let map = upgrade.listeningMap {
                try save(kind: "listening_map", id: map.id, sessionId: nil, itemId: itemId, value: map)
            }
            for interjection in upgrade.interjections { try saveInterjection(interjection) }
            for session in upgrade.sessions { try saveSession(session) }
            for manifest in try loadPreparedAudioManifests(itemId: itemId) {
                try deletePreparedAudioManifest(id: manifest.id)
            }
            for job in try loadAudioPreparationJobs() where job.itemId == itemId {
                try deleteAudioPreparationJob(id: job.id)
            }
            try saveStructuredDocument(upgrade.document, itemId: itemId)
        }
    }
}
