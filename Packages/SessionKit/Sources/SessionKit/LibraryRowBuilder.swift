import Foundation

/// The app state `LibraryRowBuilder` needs to say where an item's opening audio stands (#980).
/// The model builds one per call from its own properties, so the rules stay pure.
public struct StartupAudioContext: Sendable {
    /// The listener has accepted the current terms; no voice work starts before that.
    public var hasAcceptedCurrentTerms: Bool
    /// A Supertonic voice is selected (the iOS system voice has no prepared audio).
    public var hasSupertonicVoice: Bool
    /// Items the listener removed from automatic audio preparation.
    public var suppressedItemIds: Set<String>
    /// Items that fell back to live speech.
    public var liveSpeechFallbackItemIds: Set<String>
    /// Items whose opening-audio preparation failed this run.
    public var failedItemIds: Set<String>
    /// The item the preparation passes are working on now.
    public var preparingItemId: String?
    /// The item that is playing now, or nil when playback is paused (a paused session isn't prepared).
    public var playingItemId: String?
    /// The current Supertonic render signature; manifests made with another one are ignored.
    public var renderSignature: TTSRenderSignature?
    /// `SupertonicResourcePolicy.allowsRendering()`: live heat, read in the app because it reads ProcessInfo.
    public var allowsRendering: Bool
    /// How many chunks make the opening buffer.
    public var startupChunkCount: Int

    public init(
        hasAcceptedCurrentTerms: Bool,
        hasSupertonicVoice: Bool,
        suppressedItemIds: Set<String> = [],
        liveSpeechFallbackItemIds: Set<String> = [],
        failedItemIds: Set<String> = [],
        preparingItemId: String? = nil,
        playingItemId: String? = nil,
        renderSignature: TTSRenderSignature? = nil,
        allowsRendering: Bool = true,
        startupChunkCount: Int = LibraryRowBuilder.startupAudioChunkCount
    ) {
        self.hasAcceptedCurrentTerms = hasAcceptedCurrentTerms
        self.hasSupertonicVoice = hasSupertonicVoice
        self.suppressedItemIds = suppressedItemIds
        self.liveSpeechFallbackItemIds = liveSpeechFallbackItemIds
        self.failedItemIds = failedItemIds
        self.preparingItemId = preparingItemId
        self.playingItemId = playingItemId
        self.renderSignature = renderSignature
        self.allowsRendering = allowsRendering
        self.startupChunkCount = startupChunkCount
    }
}

/// Builds the Library's rows from a store snapshot (#980). Pure: the model passes in what it knows
/// (`StartupAudioContext`) and assigns the result; reading the store stays with the caller.
public enum LibraryRowBuilder {
    /// The opening buffer is two chunks.
    public static let startupAudioChunkCount = 2

    /// One row per Library item that isn't in the trash, in storage order.
    public static func rows(from data: LibraryReadSnapshot, context: StartupAudioContext) -> [LibraryItemRow] {
        let items = data.items.filter { $0.deletedAt == nil }
        let sessionsByItemId = Dictionary(grouping: data.sessions, by: \.itemId)
        let manifestsByItemId = Dictionary(grouping: data.manifests, by: \.itemId)
        let preparationJobsByManifestId = Dictionary(
            grouping: data.jobs.filter { !$0.isCancelled },
            by: \.manifestId
        ).compactMapValues { jobs in
            jobs.max { $0.requestedAt < $1.requestedAt }
        }
        let podcastDownloadsByItemId = Dictionary(
            grouping: data.downloads,
            by: \.itemId
        ).compactMapValues { records in
            records.max { $0.updatedAt < $1.updatedAt }
        }
        return items.enumerated().map { storageRank, item in
            let sessions = sessionsByItemId[item.id] ?? []
            let continuation = SessionContinuation.preferredContinuationSession(in: sessions)
            let isCompleted = item.sourceCompletedAt != nil || PreparationChunkGate.itemAlreadyListened(sessions)
            let compatibleManifests = manifestsByItemId[item.id]?.filter { manifest in
                context.renderSignature.map { manifest.signature == $0 } ?? true
            }
            let latestManifest = compatibleManifests?.max { $0.updatedAt < $1.updatedAt }
            let preparationJob = latestManifest.flatMap { preparationJobsByManifestId[$0.id] }
            let startupAudio: (state: NativeTextStartupAudioState, completed: Int, target: Int) = isCompleted ? (.notRequired, 0, 0) : startupAudioPresentation(
                item: item,
                manifest: latestManifest,
                job: preparationJob,
                context: context
            )
            let effectivePreparedState: PreparedAudioState? = {
                guard [.preparing, .pausedForThermal].contains(latestManifest?.state), preparationJob == nil else { // no job left: nothing will resume it
                    return latestManifest?.state
                }
                return .notPrepared
            }()
            let offlineState = LibraryOfflineStateFilter.forItem(
                preparedState: effectivePreparedState,
                mediaSourceType: item.media?.sourceType,
                podcastDownloadState: podcastDownloadsByItemId[item.id]?.state
            )
            var row = LibraryItemRow(
                id: item.id,
                title: item.title,
                status: statusLabel(for: item),
                canDelete: true,
                hasContinuationSession: continuation != nil,
                continuationProgressPercent: continuation?.completionPercent,
                isCompleted: isCompleted,
                mediaType: item.mediaType,
                hasNativeAudio: item.media?.sourceType == .nativeMediaFile || item.media?.sourceType == .remoteStream,
                sourceTitle: item.sourceTitle ?? item.externalReference,
                sourceURL: item.sourceURL,
                author: item.author,
                sourceReference: item.externalReference,
                sourceReferenceType: item.externalReferenceType,
                offlineState: offlineState,
                startupAudioState: startupAudio.state,
                startupAudioCompletedChunkCount: startupAudio.completed,
                startupAudioTargetChunkCount: startupAudio.target,
                addedAt: item.createdAt,
                lastListenedAt: sessions.compactMap { $0.updatedAt ?? $0.createdAt }.max(),
                storageRecencyRank: storageRank
            )
            row.publishedAt = ItemMetadata.publishedDate(item.publishedAt)
            row.usesNewReader = data.structuredDocumentItemIds.contains(item.id)
            row.sharedMargins = data.sharedMarginsByItemId[item.id] ?? .none
            row.canMarkUnfinished = item.sourceCompletedAt != nil && !PreparationChunkGate.itemAlreadyListened(sessions)
            row.textCharacterCount = row.hasNativeAudio ? nil : item.textCharacterCount
            return row
        }
    }

    /// Where an item's opening audio stands: waiting, preparing, ready, paused (the device is too
    /// hot), failed, or not required, with the chunks done and the target.
    public static func startupAudioPresentation<Fields: LibraryItemFields>(
        item: Fields,
        manifest: PreparedAudioManifest?,
        job: AudioPreparationJob?,
        context: StartupAudioContext
    ) -> (state: NativeTextStartupAudioState, completed: Int, target: Int) {
        guard context.hasAcceptedCurrentTerms,
              context.hasSupertonicVoice,
              !context.suppressedItemIds.contains(item.id),
              !context.liveSpeechFallbackItemIds.contains(item.id),
              item.hasListenableText else {
            return (.notRequired, 0, 0)
        }
        if item.media?.sourceType == .generatedTTSPrerendered,
           !PreparedNarrationFallback.isMissing(item.media),
           !isStarterPreparedTextMedia(item.media) {
            return (.ready, context.startupChunkCount, context.startupChunkCount)
        }
        guard shouldPrewarmTextAudio(for: item) else { return (.notRequired, 0, 0) }
        let inTurn: NativeTextStartupAudioState = item.id == context.preparingItemId || item.id == context.playingItemId ? .preparing : .waiting
        guard let manifest else {
            return context.failedItemIds.contains(item.id)
                ? (.failed, 0, context.startupChunkCount)
                : (inTurn, 0, context.startupChunkCount)
        }
        let target = min(context.startupChunkCount, max(1, manifest.plannedChunkCount))
        let completed = min(target, manifest.chunks.filter { $0.index < target }.count)
        if manifest.state == .readyOffline || completed >= target {
            return (.ready, completed, target)
        }
        if context.failedItemIds.contains(item.id)
            || job?.lastFailureCode?.isEmpty == false
            || manifest.state == .failed
            || manifest.state == .needsRepreparation
            || manifest.state == .stopped {
            return (.failed, completed, target)
        }
        if !context.allowsRendering { // live heat, not a stale pausedForThermal (#64)
            return (.paused, completed, target)
        }
        return (inTurn, completed, target)
    }

    /// The status line under a Library row's title.
    public static func statusLabel<Fields: LibraryItemFields>(for item: Fields) -> String {
        guard item.status == "ready" else {
            switch item.status {
            case "needs_listening_map": return "Ready to listen · map optional"
            case "in_progress": return "In progress"
            case "finished": return "Finished"
            case "map_needs_repair": return "Listening map needs attention"
            default: return item.status.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
        if item.media != nil || item.mediaType == TargetType.transcriptBackedMedia.rawValue {
            return "Audio ready"
        }
        return "Ready to listen"
    }

    /// Whether the item's text should be narrated ahead of time: it has text, doesn't play its own
    /// audio, and has no (or only a starter, or a missing) prepared narration file.
    public static func shouldPrewarmTextAudio<Fields: LibraryItemFields>(for item: Fields) -> Bool {
        guard item.hasListenableText,
              !LibraryAudioPreparationAdmission.playsItsOwnAudio(item) else { return false }
        guard item.media?.sourceType == .generatedTTSPrerendered else { return true }
        return PreparedNarrationFallback.isMissing(item.media) || isStarterPreparedTextMedia(item.media)
    }

    /// Narration that is only the short starter clip, not the full audio.
    public static func isStarterPreparedTextMedia(_ media: ItemMedia?) -> Bool {
        guard media?.sourceType == .generatedTTSPrerendered else { return false }
        let identifier = media?.nativeMediaId ?? media?.url ?? ""
        return identifier.contains("-starter.caf") || identifier.contains("-starter.")
    }

    /// The items to recover opening audio for at launch: unfinished and not ready, newest added first.
    public static func startupPreparationCandidates(_ rows: [LibraryItemRow]) -> [String] {
        rows.filter { !$0.isCompleted && $0.startupAudioState != .ready }
            .sorted {
                let lhsDate = $0.addedAt ?? .distantPast
                let rhsDate = $1.addedAt ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                if $0.storageRecencyRank != $1.storageRecencyRank { return $0.storageRecencyRank < $1.storageRecencyRank }
                return $0.id < $1.id
            }
            .map(\.id)
    }
}
