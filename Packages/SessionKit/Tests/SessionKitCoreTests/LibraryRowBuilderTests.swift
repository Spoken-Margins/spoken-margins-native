import Foundation
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// #980: the Library row rules, moved out of Gate1AppModel so they run on Linux.
final class LibraryRowBuilderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "row-builder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func context(
        terms: Bool = true,
        voice: Bool = true,
        suppressed: Set<String> = [],
        fallback: Set<String> = [],
        failed: Set<String> = [],
        preparing: String? = nil,
        playing: String? = nil,
        signature: TTSRenderSignature? = nil,
        allowsRendering: Bool = true
    ) -> StartupAudioContext {
        StartupAudioContext(
            hasAcceptedCurrentTerms: terms, hasSupertonicVoice: voice, suppressedItemIds: suppressed,
            liveSpeechFallbackItemIds: fallback, failedItemIds: failed, preparingItemId: preparing,
            playingItemId: playing, renderSignature: signature, allowsRendering: allowsRendering)
    }

    private func article(_ id: String = "a", text: String? = "Some words to read aloud.", status: String = "ready",
                         media: ItemMedia? = nil, mediaType: String = "text") -> Item {
        Item(id: id, title: "Title \(id)", mediaType: mediaType, text: text, externalReference: nil, status: status, media: media)
    }

    private func signature(_ digest: String = "digest") -> TTSRenderSignature {
        TTSRenderSignature(
            engine: "supertonic", modelRevision: "3", assetManifestHash: "a", voiceStyleHash: "v",
            synthesisParametersHash: "p", normalizationVersion: "n", chunkingVersion: "c", digest: digest)
    }

    private func manifest(
        _ item: String, state: PreparedAudioState, planned: Int, committed: Int, updatedAt: TimeInterval = 0,
        signature: TTSRenderSignature? = nil, id: String? = nil
    ) -> PreparedAudioManifest {
        let source = SourceLocator(documentId: "doc", spineItemId: nil, segmentId: "seg", utf8Start: 0, utf8End: 10)
        let chunks = (0..<committed).map {
            PreparedAudioChunk(id: "c\($0)", index: $0, sourceRange: source, relativePath: "c\($0).m4a", byteCount: 1, checksumSHA256: "x", durationMs: 1000)
        }
        return PreparedAudioManifest(
            id: id ?? "manifest-\(item)", itemId: item, sourcePackageId: "source", signature: signature ?? self.signature(),
            state: state, plannedChunkCount: planned, chunks: chunks, updatedAt: date(updatedAt))
    }

    private func startup(_ item: Item, manifest: PreparedAudioManifest? = nil, job: AudioPreparationJob? = nil,
                         _ context: StartupAudioContext) -> (state: NativeTextStartupAudioState, completed: Int, target: Int) {
        LibraryRowBuilder.startupAudioPresentation(item: item, manifest: manifest?.summary, job: job, context: context)
    }

    // MARK: Startup audio state

    func testNotRequiredWhenTheListenerHasNotAcceptedTermsHasNoSupertonicVoiceOrOptedTheItemOut() {
        let item = article()
        for (name, ctx) in [
            ("terms not accepted", context(terms: false)),
            ("system voice", context(voice: false)),
            ("removed from automatic preparation", context(suppressed: ["a"])),
            ("live speech fallback", context(fallback: ["a"])),
        ] {
            let result = startup(item, ctx)
            XCTAssertEqual(result.state, .notRequired, name)
            XCTAssertEqual(result.completed, 0, name)
            XCTAssertEqual(result.target, 0, name)
        }
        XCTAssertEqual(startup(article(text: "  \n "), context()).state, .notRequired, "no text to read")
        XCTAssertEqual(startup(article(text: nil), context()).state, .notRequired)
    }

    func testAnItemThatPlaysItsOwnAudioNeedsNoPreparedAudio() {
        let podcast = article("p", media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/e.mp3"), mediaType: "podcast")
        XCTAssertEqual(startup(podcast, context()).state, .notRequired)
    }

    func testWaitingThenPreparingWhenItIsTheItemInTurnOrPlaying() {
        let item = article()
        XCTAssertEqual(startup(item, context()).state, .waiting)
        XCTAssertEqual(startup(item, context()).target, 2)
        XCTAssertEqual(startup(item, context(preparing: "a")).state, .preparing, "the item the passes are on")
        XCTAssertEqual(startup(item, context(playing: "a")).state, .preparing, "the item that is playing")
        XCTAssertEqual(startup(item, context(preparing: "other", playing: "other")).state, .waiting)
    }

    func testFailedWithoutAManifestWhenPreparationFailedThisRun() {
        let result = startup(article(), context(failed: ["a"]))
        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.target, 2)
    }

    func testReadyWhenTheFullNarrationFileIsOnDiskButNotForAStarterOrAMissingFile() throws {
        let full = directory.appending(path: "full.caf")
        let starter = directory.appending(path: "item-starter.caf")
        try Data([1]).write(to: full)
        try Data([1]).write(to: starter)
        func narrated(_ file: URL) -> Item {
            article(media: ItemMedia(sourceType: .generatedTTSPrerendered, url: file.absoluteString))
        }
        let ready = startup(narrated(full), context())
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(ready.completed, 2)
        XCTAssertEqual(ready.target, 2)
        XCTAssertEqual(startup(narrated(starter), context()).state, .waiting, "a starter clip is not the full audio")
        XCTAssertEqual(startup(narrated(directory.appending(path: "gone.caf")), context()).state, .waiting, "a missing file is prepared again")
    }

    func testReadyOnceTheOpeningChunksAreInOrTheManifestIsReadyOffline() {
        let item = article()
        let partial = startup(item, manifest: manifest("a", state: .preparing, planned: 6, committed: 1), context())
        XCTAssertEqual(partial.state, .waiting, "one of two opening chunks")
        XCTAssertEqual(partial.completed, 1)
        XCTAssertEqual(partial.target, 2)
        let opening = startup(item, manifest: manifest("a", state: .preparing, planned: 6, committed: 2), context())
        XCTAssertEqual(opening.state, .ready)
        XCTAssertEqual(opening.completed, 2)
        let done = startup(item, manifest: manifest("a", state: .readyOffline, planned: 6, committed: 6), context())
        XCTAssertEqual(done.state, .ready)
        XCTAssertEqual(done.completed, 2, "counts only the opening chunks")
    }

    func testTheTargetNeverExceedsAShortArticlesPlan() {
        let short = startup(article(), manifest: manifest("a", state: .preparing, planned: 1, committed: 0), context())
        XCTAssertEqual(short.target, 1)
        let empty = startup(article(), manifest: manifest("a", state: .preparing, planned: 0, committed: 0), context())
        XCTAssertEqual(empty.target, 1, "at least one chunk")
    }

    func testFailedWhenTheJobTheManifestOrThisRunFailed() {
        let item = article()
        var failedJob = AudioPreparationJob(id: "j", itemId: "a", manifestId: "manifest-a", policy: .explicit)
        failedJob.lastFailureCode = "render_failed"
        XCTAssertEqual(startup(item, manifest: manifest("a", state: .preparing, planned: 6, committed: 1), job: failedJob, context()).state, .failed)
        XCTAssertEqual(startup(item, manifest: manifest("a", state: .preparing, planned: 6, committed: 1), context(failed: ["a"])).state, .failed)
        for state in [PreparedAudioState.failed, .needsRepreparation, .stopped] {
            XCTAssertEqual(startup(item, manifest: manifest("a", state: state, planned: 6, committed: 1), context()).state, .failed, "\(state)")
        }
        var emptyCode = failedJob
        emptyCode.lastFailureCode = ""
        XCTAssertEqual(startup(item, manifest: manifest("a", state: .preparing, planned: 6, committed: 1), job: emptyCode, context()).state, .waiting, "an empty code is no failure")
    }

    func testPausedWhenTheDeviceCannotRenderRightNowAndOtherwiseInTurn() {
        let item = article()
        let partial = manifest("a", state: .preparing, planned: 6, committed: 1)
        let hot = startup(item, manifest: partial, context(allowsRendering: false))
        XCTAssertEqual(hot.state, .paused)
        XCTAssertEqual(hot.completed, 1)
        XCTAssertEqual(startup(item, manifest: partial, context(preparing: "a")).state, .preparing)
        // A manifest left as paused-for-thermal does not say paused once the device has cooled.
        XCTAssertEqual(startup(item, manifest: manifest("a", state: .pausedForThermal, planned: 6, committed: 1), context()).state, .waiting)
        XCTAssertEqual(startup(item, manifest: manifest("a", state: .readyOffline, planned: 6, committed: 6), context(allowsRendering: false)).state, .ready, "ready beats paused")
    }

    func testPrewarmAndStarterRulesForNeighbouringInputs() {
        let starterNames = ["x-starter.caf", "x-starter.m4a", "dir/x-starter.caf"]
        for name in starterNames {
            XCTAssertTrue(LibraryRowBuilder.isStarterPreparedTextMedia(ItemMedia(sourceType: .generatedTTSPrerendered, url: name)), name)
            XCTAssertTrue(LibraryRowBuilder.isStarterPreparedTextMedia(ItemMedia(sourceType: .generatedTTSPrerendered, nativeMediaId: name)), name)
        }
        XCTAssertFalse(LibraryRowBuilder.isStarterPreparedTextMedia(ItemMedia(sourceType: .generatedTTSPrerendered, url: "x-full.caf")))
        XCTAssertFalse(LibraryRowBuilder.isStarterPreparedTextMedia(ItemMedia(sourceType: .generatedTTSPrerendered)))
        XCTAssertFalse(LibraryRowBuilder.isStarterPreparedTextMedia(ItemMedia(sourceType: .nativeMediaFile, url: "x-starter.caf")), "only generated narration")
        XCTAssertFalse(LibraryRowBuilder.isStarterPreparedTextMedia(nil))

        XCTAssertTrue(LibraryRowBuilder.shouldPrewarmTextAudio(for: article()))
        XCTAssertFalse(LibraryRowBuilder.shouldPrewarmTextAudio(for: article(text: "")))
        XCTAssertFalse(LibraryRowBuilder.shouldPrewarmTextAudio(for: article(media: ItemMedia(sourceType: .nativeMediaFile, url: "f.mp3"))))
        XCTAssertTrue(LibraryRowBuilder.shouldPrewarmTextAudio(for: article(media: ItemMedia(sourceType: .generatedTTSPrerendered, url: "x-starter.caf"))))
        XCTAssertTrue(LibraryRowBuilder.shouldPrewarmTextAudio(for: article(media: ItemMedia(sourceType: .generatedTTSPrerendered, url: directory.appending(path: "missing.caf").absoluteString))))
    }

    // MARK: Status labels and symbols

    func testStatusLabelsAreTheExactListenerText() {
        func label(_ status: String, media: ItemMedia? = nil, mediaType: String = "text") -> String {
            LibraryRowBuilder.statusLabel(for: article(status: status, media: media, mediaType: mediaType))
        }
        XCTAssertEqual(label("needs_listening_map"), "Ready to listen · map optional")
        XCTAssertEqual(label("in_progress"), "In progress")
        XCTAssertEqual(label("finished"), "Finished")
        XCTAssertEqual(label("map_needs_repair"), "Listening map needs attention")
        XCTAssertEqual(label("some_new_status"), "Some New Status", "unknown statuses are tidied")
        XCTAssertEqual(label("ready"), "Ready to listen")
        XCTAssertEqual(label("ready", media: ItemMedia(sourceType: .nativeMediaFile)), "Audio ready")
        XCTAssertEqual(label("ready", mediaType: TargetType.transcriptBackedMedia.rawValue), "Audio ready")
        XCTAssertEqual(label("in_progress", media: ItemMedia(sourceType: .nativeMediaFile)), "In progress", "a status beats the media")
    }

    func testMediaSymbolNamesForEveryMediaTypeWithoutNativeAudio() {
        func symbol(_ type: String, native: Bool = false) -> String {
            LibraryItemRow(id: "i", title: "T", status: "s", canDelete: true, mediaType: type, hasNativeAudio: native).mediaSymbol
        }
        for type in ["podcast", "audio", "audiobook", "m4a", "m4b", "mp3", "Podcast", "MP3", "AuDiO"] {
            XCTAssertEqual(symbol(type), "headphones", type)
        }
        XCTAssertEqual(symbol("pdf"), "doc.richtext")
        XCTAssertEqual(symbol("PDF"), "doc.richtext")
        XCTAssertEqual(symbol("epub"), "book.closed")
        XCTAssertEqual(symbol("EPUB"), "book.closed")
        for type in ["text", "html", "markdown", "", "unknown"] {
            XCTAssertEqual(symbol(type), "doc.text", type)
        }
        XCTAssertEqual(symbol("pdf", native: true), "headphones", "native audio wins")
    }

    func testTheRowInitializerClampsCountsAndDefaultsTheRank() {
        let row = LibraryItemRow(
            id: "i", title: "T", status: "s", canDelete: false,
            startupAudioCompletedChunkCount: -3, startupAudioTargetChunkCount: -1)
        XCTAssertEqual(row.startupAudioCompletedChunkCount, 0)
        XCTAssertEqual(row.startupAudioTargetChunkCount, 0)
        XCTAssertEqual(row.storageRecencyRank, .max)
        XCTAssertEqual(row.mediaType, "text")
        XCTAssertEqual(row.offlineState, .onlineOnly)
        XCTAssertEqual(row.startupAudioState, .notRequired)
        XCTAssertFalse(row.usesNewReader)
        XCTAssertFalse(row.canMarkUnfinished)
        XCTAssertNil(row.textCharacterCount)
    }

    func testStartupStateRawValuesAreStable() {
        XCTAssertEqual(
            [NativeTextStartupAudioState.notRequired, .waiting, .preparing, .ready, .paused, .failed].map(\.rawValue),
            ["not_required", "waiting", "preparing", "ready", "paused", "failed"])
    }

    // MARK: Startup candidates

    func testStartupCandidatesAreUnfinishedAndNotReadyNewestFirstThenStorageOrderThenId() {
        func row(_ id: String, added: TimeInterval?, rank: Int, completed: Bool = false, state: NativeTextStartupAudioState = .waiting) -> LibraryItemRow {
            LibraryItemRow(id: id, title: id, status: "s", canDelete: true, isCompleted: completed, startupAudioState: state,
                           addedAt: added.map(date), storageRecencyRank: rank)
        }
        let rows = [
            row("old", added: 1, rank: 0), row("done", added: 9, rank: 1, completed: true), row("ready", added: 8, rank: 2, state: .ready),
            row("new", added: 5, rank: 3), row("tie-b", added: 3, rank: 4), row("tie-a", added: 3, rank: 4),
            row("tie-first", added: 3, rank: 2), row("undated", added: nil, rank: 5),
        ]
        XCTAssertEqual(LibraryRowBuilder.startupPreparationCandidates(rows), ["new", "tie-first", "tie-a", "tie-b", "old", "undated"])
        XCTAssertEqual(LibraryRowBuilder.startupPreparationCandidates([]), [])
    }

    // MARK: Rows

    private func session(_ id: String, item: String, status: String = "in_progress", percent: Int = 10, updatedAt: TimeInterval = 1) -> Session {
        Session(
            id: id, itemId: item, updatedAt: date(updatedAt), status: status, phase: status == "finished" ? .finished : .itemPlayback,
            currentTargetType: .itemTextTTS, currentTargetId: item, position: Position(charOffset: 1),
            completionPercent: percent, playbackRate: 1)
    }

    func testRowsSkipTrashedItemsKeepStorageOrderAndCarryTheItemsFields() throws {
        var item = article("a", text: "Hello there", status: "in_progress")
        item.createdAt = date(100)
        item.author = "Ada"
        item.sourceTitle = "Site"
        item.sourceURL = "https://example.com/a"
        item.externalReference = "ref-1"
        item.externalReferenceType = "url"
        var trashed = article("b")
        trashed.deletedAt = date(5)
        let snapshot = LibraryReadSnapshot(
            items: [item, trashed, article("c")], sessions: [session("s", item: "a", percent: 40, updatedAt: 7)],
            manifests: [], jobs: [], downloads: [], structuredDocumentItemIds: ["c"])
        let rows = LibraryRowBuilder.rows(from: snapshot, context: context())
        XCTAssertEqual(rows.map(\.id), ["a", "c"])
        XCTAssertEqual(rows.map(\.storageRecencyRank), [0, 1], "rank counts the shown rows")
        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(first.status, "In progress")
        XCTAssertEqual(first.author, "Ada")
        XCTAssertEqual(first.sourceTitle, "Site")
        XCTAssertEqual(first.sourceURL, "https://example.com/a")
        XCTAssertEqual(first.sourceReference, "ref-1")
        XCTAssertEqual(first.sourceReferenceType, "url")
        XCTAssertEqual(first.addedAt, date(100))
        XCTAssertEqual(first.lastListenedAt, date(7))
        XCTAssertTrue(first.hasContinuationSession)
        XCTAssertEqual(first.continuationProgressPercent, 40)
        XCTAssertEqual(first.textCharacterCount, 11)
        XCTAssertFalse(first.usesNewReader)
        XCTAssertTrue(rows[1].usesNewReader, "a structured-document PDF")
        XCTAssertFalse(rows[1].hasContinuationSession)
    }

    func testTheSourceTitleFallsBackToTheExternalReference() throws {
        var item = article("a")
        item.externalReference = "ref-only"
        let row = try XCTUnwrap(LibraryRowBuilder.rows(
            from: LibraryReadSnapshot(items: [item], sessions: [], manifests: [], jobs: [], downloads: []), context: context()).first)
        XCTAssertEqual(row.sourceTitle, "ref-only")
    }

    func testAFinishedItemNeedsNoStartupAudioAndCanBeMarkedUnfinishedOnlyWhenMarkedByHand() throws {
        var marked = article("marked")
        marked.sourceCompletedAt = date(3)
        let listened = article("listened")
        var markedAndListened = article("both")
        markedAndListened.sourceCompletedAt = date(3)
        let snapshot = LibraryReadSnapshot(
            items: [marked, listened, article("open"), markedAndListened],
            sessions: [
                session("s", item: "listened", status: "finished", percent: 100),
                session("s2", item: "both", status: "finished", percent: 100),
            ],
            manifests: [], jobs: [], downloads: [])
        let rows = LibraryRowBuilder.rows(from: snapshot, context: context())
        XCTAssertEqual(rows.map(\.isCompleted), [true, true, false, true])
        XCTAssertEqual(rows.map(\.startupAudioState), [.notRequired, .notRequired, .waiting, .notRequired])
        XCTAssertEqual(rows.map(\.canMarkUnfinished), [true, false, false, false], "listened to the end can't be unmarked by hand")
        XCTAssertEqual(startup(marked, context()).state, .waiting, "the rule alone would ask for it; the finished row skips it")
    }

    func testNativeAudioRowsHaveNoTextLength() throws {
        let podcast = article("p", media: ItemMedia(sourceType: .remoteStream, url: "https://example.com/e.mp3"), mediaType: "podcast")
        let row = try XCTUnwrap(LibraryRowBuilder.rows(
            from: LibraryReadSnapshot(items: [podcast], sessions: [], manifests: [], jobs: [], downloads: []), context: context()).first)
        XCTAssertTrue(row.hasNativeAudio)
        XCTAssertNil(row.textCharacterCount)
        XCTAssertEqual(row.status, "Audio ready")
    }

    func testOfflineStateFollowsPodcastDownloadsThenTheNewestCompatibleManifest() throws {
        let ours = signature("ours")
        let item = article("a")
        func state(_ manifests: [PreparedAudioManifest], jobs: [AudioPreparationJob] = [], downloads: [PodcastDownloadRecord] = [],
                   signature: TTSRenderSignature? = ours) throws -> LibraryOfflineStateFilter {
            let snapshot = LibraryReadSnapshot(items: [item], sessions: [], manifests: manifests.map(\.summary), jobs: jobs, downloads: downloads)
            return try XCTUnwrap(LibraryRowBuilder.rows(from: snapshot, context: context(signature: signature)).first).offlineState
        }
        XCTAssertEqual(try state([]), .onlineOnly)
        XCTAssertEqual(try state([manifest("a", state: .readyOffline, planned: 2, committed: 2, signature: ours)]), .readyOffline)
        XCTAssertEqual(
            try state([manifest("a", state: .readyOffline, planned: 2, committed: 2, signature: signature("old"))]), .onlineOnly,
            "audio made with another voice or version doesn't count")
        XCTAssertEqual(
            try state([manifest("a", state: .readyOffline, planned: 2, committed: 2, signature: signature("old"))], signature: nil), .readyOffline,
            "with no current signature every manifest counts")
        XCTAssertEqual(
            try state([
                manifest("a", state: .readyOffline, planned: 2, committed: 2, updatedAt: 1, signature: ours, id: "older"),
                manifest("a", state: .failed, planned: 2, committed: 0, updatedAt: 9, signature: ours, id: "newer"),
            ]), .needsRepreparation, "the newest manifest decides")
        // A manifest still "preparing" with no job left will never resume, so it reads as not prepared.
        let orphan = manifest("a", state: .preparing, planned: 4, committed: 1, signature: ours)
        XCTAssertEqual(try state([orphan]), .onlineOnly)
        let job = AudioPreparationJob(id: "j", itemId: "a", manifestId: orphan.id, policy: .whileCharging)
        XCTAssertEqual(try state([orphan], jobs: [job]), .preparing)
        var cancelled = job
        cancelled.isCancelled = true
        XCTAssertEqual(try state([orphan], jobs: [cancelled]), .onlineOnly, "a cancelled job is no job")
        let download = PodcastDownloadRecord(id: "d", itemId: "a", remoteURL: "https://example.com/a.mp3", state: .availableOffline)
        XCTAssertEqual(try state([], downloads: [download]), .readyOffline, "a finished download")
    }

    func testTheNewestPodcastDownloadRecordWins() throws {
        let item = article("a")
        let downloads = [
            PodcastDownloadRecord(id: "old", itemId: "a", remoteURL: "https://example.com/a.mp3", state: .availableOffline, updatedAt: date(1)),
            PodcastDownloadRecord(id: "new", itemId: "a", remoteURL: "https://example.com/a.mp3", state: .failed, updatedAt: date(2)),
        ]
        let row = try XCTUnwrap(LibraryRowBuilder.rows(
            from: LibraryReadSnapshot(items: [item], sessions: [], manifests: [], jobs: [], downloads: downloads), context: context()).first)
        XCTAssertEqual(row.offlineState, .needsRepreparation)
    }

    func testTheRowCarriesTheStartupStateOfItsNewestCompatibleManifestAndItsJob() throws {
        let ours = signature("ours")
        var item = article("a")
        item.id = "a"
        let partial = manifest("a", state: .preparing, planned: 6, committed: 1, signature: ours)
        var job = AudioPreparationJob(id: "j", itemId: "a", manifestId: partial.id, policy: .explicit)
        let waiting = try XCTUnwrap(LibraryRowBuilder.rows(
            from: LibraryReadSnapshot(items: [item], sessions: [], manifests: [partial.summary], jobs: [job], downloads: []),
            context: context(signature: ours)).first)
        XCTAssertEqual(waiting.startupAudioState, .waiting)
        XCTAssertEqual(waiting.startupAudioCompletedChunkCount, 1)
        XCTAssertEqual(waiting.startupAudioTargetChunkCount, 2)
        job.lastFailureCode = "boom"
        let failed = try XCTUnwrap(LibraryRowBuilder.rows(
            from: LibraryReadSnapshot(items: [item], sessions: [], manifests: [partial.summary], jobs: [job], downloads: []),
            context: context(signature: ours)).first)
        XCTAssertEqual(failed.startupAudioState, .failed)
    }

    func testTheReadSnapshotReadsEverythingTheRowsNeedFromARealStore() throws {
        let store = try SQLiteSessionStore(path: directory.appending(path: "library.sqlite").path)
        var gone = article("gone")
        gone.deletedAt = date(2)
        try store.saveItem(article("a"))
        try store.saveItem(gone)
        try store.saveSession(session("s", item: "a"))
        let snapshot = try LibraryReadSnapshot.read(store: store)
        XCTAssertEqual(Set(snapshot.items.map(\.id)), ["a", "gone"], "trashed items are read too; the builder drops them")
        XCTAssertEqual(snapshot.sessions.map(\.id), ["s"])
        let rows = LibraryRowBuilder.rows(from: snapshot, context: context())
        XCTAssertEqual(rows.map(\.id), ["a"])
        XCTAssertTrue(rows[0].hasContinuationSession)
    }

    func testTheOpeningBufferIsTwoChunks() {
        XCTAssertEqual(LibraryRowBuilder.startupAudioChunkCount, 2)
        XCTAssertEqual(context().startupChunkCount, 2)
    }
}
