import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
#if KOKORO_DEVICE && !targetEnvironment(simulator)
import SessionKitKokoro
#endif
import SessionKitPersistence
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

enum Gate1Screen: Hashable {
    case home
    case item
    case playback
    case settings
    case export
}

struct LibraryItemRow: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
    let canDelete: Bool
}

struct ItemDetailState {
    var id = ""
    var title = ""
    var status = ""
    var text = ""
    var externalReference = ""
    var overview = ""
    var chapters: [Chapter] = []
    var sessions: [Session] = []
    var interjections: [Interjection] = []
    var turns: [ConversationTurn] = []
}

struct SpeechVoiceChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let quality: String
}

private enum AppSpeechPreviewMode {
    case spokenContent
    case appVoice(voiceIdentifier: String?, rate: Float)
    case assistiveTechnology
}

@MainActor
final class Gate1AppModel: ObservableObject {
    @Published var screen: Gate1Screen = .home
    @Published var snapshot = SessionSnapshot() {
        didSet {
            reconcilePlaybackProgressTicker()
        }
    }
    @Published var diagnostics: [String: String] = [:]
    @Published var statusMessage = "Ready."
    @Published var lastError: String?
    @Published var exportPreview = ""
    @Published var libraryItems: [LibraryItemRow] = []
    @Published var selectedItem = ItemDetailState()
    @Published var selectedProfileId = "phone-tablet-online"
    @Published var importTitle = "Gate 1 Article With Links"
    @Published var importText = "Read the background at https://example.com/long/url before continuing. A labeled [reference](https://example.com/essay) should stay readable while raw URLs are skipped."
    @Published var listeningMapJSON = ""
    @Published var isGeneratingListeningMap = false
    @Published var providerBaseURL = UserDefaults.standard.string(forKey: "providerBaseURL") ?? "https://api.openai.com/v1"
    @Published var listeningMapModel = UserDefaults.standard.string(forKey: "listeningMapModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-4.1-mini"
    @Published var summaryModel = UserDefaults.standard.string(forKey: "summaryModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-4.1-mini"
    @Published var conversationModel = UserDefaults.standard.string(forKey: "conversationModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-4.1-mini"
    @Published var skipUnit = UserDefaults.standard.string(forKey: "skipUnit") ?? "paragraph"
    @Published var speechRate = UserDefaults.standard.double(forKey: "speechRate") == 0 ? 0.5 : UserDefaults.standard.double(forKey: "speechRate")
    @Published var speechVoiceIdentifier = UserDefaults.standard.string(forKey: "speechVoiceIdentifier") ?? ""
    @Published var ttsMode = UserDefaults.standard.string(forKey: "ttsMode") ?? "systemImmediate"
    @Published var kokoroVoiceName = UserDefaults.standard.string(forKey: "kokoroVoiceName") ?? "am_echo"
    @Published var kokoroChunkCharacters = min(140, max(80, UserDefaults.standard.double(forKey: "kokoroChunkCharacters") == 0 ? 110 : UserDefaults.standard.double(forKey: "kokoroChunkCharacters")))
    @Published var kokoroStatus = "Not checked"
    @Published var isRenderingKokoroPreview = false
    @Published var isRunningKokoroMemoryCheck = false
    @Published var providerAPIKey = KeychainStore.load(service: "SpokenMargins", account: "OpenAICompatibleAPIKey") ?? ""
    @Published var providerProbeStatus = "Not checked"
    @Published var knownIssues = [
        "Gate 1 simulator app builds; signed device installation still requires local team/provisioning configuration.",
        "Now Playing metadata and remote command handling still need the next device pass."
    ]

    private var engine: SessionEngine?
    private var store: SQLiteSessionStore?
    private var activeItemId = "item-pill"
    private var providerModel = UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-4.1-mini"
    private var playbackProgressTask: Task<Void, Never>?
    private var pendingAutoPlayTurnId: String?
    private let transcriptionClient = SystemSpeechTranscriptionClient()
    #if canImport(AVFoundation)
    private let speechPreviewSynthesizer = AVSpeechSynthesizer()
    private var kokoroPreviewPlayer: AVAudioPlayer?
    #endif
    let speechVoiceOptions = Gate1AppModel.availableSpeechVoiceOptions()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static func availableSpeechVoiceOptions() -> [SpeechVoiceChoice] {
        #if canImport(AVFoundation)
        return AVSpeechSynthesisVoice.speechVoices()
            .sorted { lhs, rhs in
                if lhs.language == rhs.language {
                    return lhs.name < rhs.name
                }
                return lhs.language < rhs.language
            }
            .map { voice in
                SpeechVoiceChoice(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: voiceQualityName(voice)
                )
            }
        #else
        return []
        #endif
    }

    deinit {
        playbackProgressTask?.cancel()
    }

    private func reconcilePlaybackProgressTicker() {
        if snapshot.status == .playing {
            startPlaybackProgressTicker()
        } else {
            stopPlaybackProgressTicker()
        }
    }

    private func startPlaybackProgressTicker() {
        guard playbackProgressTask == nil else { return }
        playbackProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    guard let self else { return }
                    guard self.snapshot.status == .playing else {
                        self.stopPlaybackProgressTicker()
                        return
                    }
                    guard let engine = self.engine else { return }
                    do {
                        let updated = try engine.syncPlaybackProgress()
                        if updated != self.snapshot {
                            self.snapshot = updated
                        }
                        self.playPendingTurnIfReady()
                    } catch {
                        self.diagnostics["playbackProgressSyncError"] = String(describing: error)
                    }
                }
            }
        }
    }

    private func stopPlaybackProgressTicker() {
        playbackProgressTask?.cancel()
        playbackProgressTask = nil
    }

    func resetAndSeed() {
        do {
            let databaseURL = try databaseURL()
            let store = try SQLiteSessionStore(path: databaseURL.path)
            try store.reset()
            let item = try loadFixtureItem(name: "text-with-listening-map")
            let map = try loadFixtureMap(name: "valid-listening-map")
            try store.seed(item: item)
            try store.seed(map: map)
            self.store = store
            self.engine = try makeEngine(store: store)
            activeItemId = item.id
            snapshot = SessionSnapshot()
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: item.id, store: store)
            diagnostics = [
                "runtimeProfile": selectedProfileId,
                "seededItems": "1",
                "database": databaseURL.lastPathComponent
            ]
            exportPreview = ""
            reportSuccess("Listening queue ready.")
        } catch {
            reportFailure(error, context: "Reset and seed failed")
        }
    }

    func importTextItem() {
        do {
            let store = try requireStore()
            let item = Item(
                id: "item-import-\(Int(Date().timeIntervalSince1970))",
                title: importTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Text" : importTitle,
                mediaType: "text",
                text: importText,
                externalReference: "manual-import",
                status: "needs_listening_map"
            )
            try store.seed(item: item)
            self.engine = try makeEngine(store: store)
            activeItemId = item.id
            snapshot = try engine?.startSession(itemId: item.id) ?? SessionSnapshot()
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: item.id, store: store)
            diagnostics["lastImport"] = item.id
            screen = .playback
            reportSuccess("Imported and started \(item.title).")
        } catch {
            reportFailure(error, context: "Import failed")
        }
    }

    func importObsidianMarkdownFiles(urls: [URL]) {
        do {
            let store = try requireStore()
            var imported: [Item] = []
            var failures: [String] = []
            for (index, url) in urls.enumerated() {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let raw = try String(contentsOf: url, encoding: .utf8)
                    let parsed = try ObsidianMarkdownParser.parse(fileName: url.lastPathComponent, contents: raw)
                    let item = Item(
                        id: obsidianItemId(fileName: url.lastPathComponent, index: index),
                        title: parsed.title,
                        mediaType: "text",
                        text: parsed.text,
                        externalReference: parsed.source ?? url.lastPathComponent,
                        status: "needs_listening_map"
                    )
                    try store.saveItem(item)
                    imported.append(item)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error)")
                }
            }
            guard !imported.isEmpty else {
                reportFailure(failures.isEmpty ? "No Markdown files were imported." : failures.joined(separator: "\n"))
                return
            }
            self.engine = try makeEngine(store: store)
            activeItemId = imported.first?.id ?? activeItemId
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: activeItemId, store: store)
            diagnostics["lastObsidianImportCount"] = "\(imported.count)"
            diagnostics["lastObsidianImportFailures"] = "\(failures.count)"
            screen = .home
            let suffix = failures.isEmpty ? "" : " \(failures.count) failed."
            reportSuccess("Imported \(imported.count) Obsidian file\(imported.count == 1 ? "" : "s").\(suffix)")
        } catch {
            reportFailure(error, context: "Obsidian import failed")
        }
    }

    func reportImportFailure(_ error: Error) {
        reportFailure(error, context: "File import failed")
    }

    func importKokoroAssets(urls: [URL]) {
        guard !urls.isEmpty else {
            reportFailure("No Kokoro asset files were selected.")
            return
        }

        do {
            let assetsDirectory = try kokoroAssetsDirectory()
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

            var copiedModel = false
            var copiedVoices = false
            var ignored: [String] = []

            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let lowercasedName = url.lastPathComponent.lowercased()
                let destinationName: String?
                if lowercasedName == "kokoro-v1_0.safetensors" || url.pathExtension.lowercased() == "safetensors" {
                    destinationName = "kokoro-v1_0.safetensors"
                } else if lowercasedName == "voices.npz" || url.pathExtension.lowercased() == "npz" {
                    destinationName = "voices.npz"
                } else {
                    destinationName = nil
                }

                guard let destinationName else {
                    ignored.append(url.lastPathComponent)
                    continue
                }

                let destinationURL = assetsDirectory.appending(path: destinationName)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: url, to: destinationURL)
                copiedModel = copiedModel || destinationName == "kokoro-v1_0.safetensors"
                copiedVoices = copiedVoices || destinationName == "voices.npz"
            }

            refreshKokoroAssetStatus()
            let ignoredSuffix = ignored.isEmpty ? "" : " Ignored: \(ignored.joined(separator: ", "))."
            if copiedModel || copiedVoices {
                reportSuccess("Imported Kokoro asset\(copiedModel && copiedVoices ? "s" : "").\(ignoredSuffix)")
            } else {
                reportFailure("No Kokoro assets were imported. Select kokoro-v1_0.safetensors and voices.npz.\(ignoredSuffix)")
            }
        } catch {
            reportFailure(error, context: "Kokoro asset import failed")
        }
    }

    func start() {
        stopSpeechPreviews()
        run { engine in
            snapshot = try engine.startSession(itemId: activeItemId)
            if let store {
                selectedItem = try loadItemDetail(id: activeItemId, store: store)
            }
            screen = .playback
            reportSuccess("Started \(snapshot.title ?? "session").")
        }
    }

    func playPause() {
        if snapshot.status == .playing {
            pause()
        } else if hasActiveSession {
            resumePlayback()
        } else {
            start()
        }
    }

    func pause() {
        run { engine in
            snapshot = try engine.pause()
            refreshSelectedItem()
            reportSuccess("Paused.")
        }
    }

    func resumePlayback() {
        stopSpeechPreviews()
        run { engine in
            snapshot = try engine.resumePlayback()
            refreshSelectedItem()
            reportSuccess("Resumed.")
        }
    }

    func generateListeningMap() {
        guard !isGeneratingListeningMap else { return }
        isGeneratingListeningMap = true
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            run { engine in
                snapshot = try engine.generateListeningMap(itemId: activeItemId)
                if let store {
                    libraryItems = try loadLibraryRows(store: store)
                }
                refreshSelectedItem()
                diagnostics["lastGeneratedMapItem"] = activeItemId
                diagnostics["lastListeningMapMode"] = "local_deterministic"
                reportSuccess("Generated local Listening Map.")
            }
            isGeneratingListeningMap = false
            return
        }

        statusMessage = "Calling \(modelForAIJob(kind: "listening_map")) for Listening Map."
        lastError = nil
        Task {
            await generateProviderListeningMap()
        }
    }

    private func generateProviderListeningMap() async {
        defer { isGeneratingListeningMap = false }
        do {
            let store = try requireStore()
            var item = try store.loadItem(id: activeItemId)
            guard let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.itemHasNoText
            }
            let model = modelForAIJob(kind: "listening_map")
            diagnostics["lastListeningMapModel"] = model
            let firstPrompt = listeningMapPrompt(sourceText: text)
            let firstResponse = try await callProvider(messages: [firstPrompt], model: model, systemPrompt: systemPromptForAIJob(kind: "listening_map"))
            do {
                try saveProviderListeningMapResponse(firstResponse, item: &item, store: store)
                diagnostics["lastListeningMapRepairAttempt"] = "0"
                reportSuccess("Generated Listening Map with \(model).")
            } catch {
                let repairPrompt = listeningMapRepairPrompt(sourceText: text, invalidResponse: firstResponse, error: String(describing: error))
                let repairedResponse = try await callProvider(messages: [repairPrompt], model: model, systemPrompt: systemPromptForAIJob(kind: "listening_map"))
                try saveProviderListeningMapResponse(repairedResponse, item: &item, store: store)
                diagnostics["lastListeningMapRepairAttempt"] = "1"
                diagnostics["lastListeningMapInitialError"] = String(describing: error)
                reportSuccess("Generated repaired Listening Map with \(model).")
            }
        } catch {
            reportFailure(error, context: "Listening Map generation failed")
        }
    }

    private func saveProviderListeningMapResponse(_ response: String, item: inout Item, store: SQLiteSessionStore) throws {
        let map = try parseListeningMapJSON(response, item: item)
        try store.saveListeningMap(map)
        item.status = "ready"
        try store.saveItem(item)
        libraryItems = try loadLibraryRows(store: store)
        selectedItem = try loadItemDetail(id: item.id, store: store)
        diagnostics["lastGeneratedMapItem"] = item.id
        diagnostics["lastListeningMapMode"] = "provider"
    }

    private func generateLocalListeningMap() {
        run { engine in
            snapshot = try engine.generateListeningMap(itemId: activeItemId)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
            }
            refreshSelectedItem()
            diagnostics["lastGeneratedMapItem"] = activeItemId
            reportSuccess("Generated Listening Map.")
        }
    }

    func applyListeningMapJSON() {
        do {
            let store = try requireStore()
            var item = try store.loadItem(id: activeItemId)
            let map = try parseListeningMapJSON(listeningMapJSON, item: item)
            try store.saveListeningMap(map)
            item.status = "ready"
            try store.saveItem(item)
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: activeItemId, store: store)
            diagnostics["lastAppliedMap"] = map.id
            diagnostics["lastAppliedMapChapters"] = "\(map.chapters.count)"
            reportSuccess("Applied Listening Map.")
        } catch {
            reportFailure(error, context: "Listening Map validation failed")
        }
    }

    func jumpToChapter(_ chapter: Chapter) {
        stopSpeechPreviews()
        pendingAutoPlayTurnId = nil
        run { engine in
            if !hasActiveSession {
                snapshot = try engine.startSession(itemId: activeItemId)
            }
            snapshot = try engine.jumpToChapter(chapterId: chapter.id)
            refreshSelectedItem()
            screen = .playback
            reportSuccess("Jumped to \(chapter.title).")
        }
    }

    func playSourceFromBeginning() {
        stopSpeechPreviews()
        pendingAutoPlayTurnId = nil
        run { engine in
            if !hasActiveSession {
                snapshot = try engine.startSession(itemId: activeItemId)
            } else {
                snapshot = try engine.playSourceFromBeginning()
            }
            refreshSelectedItem()
            screen = .playback
            reportSuccess("Playing source from the beginning.")
        }
    }

    func openHome() {
        if hasActiveSession {
            run { engine in
                snapshot = try engine.stopPlayback()
            }
        }
        screen = .home
    }

    func openSettings() {
        screen = .settings
    }

    func openExport() {
        if hasActiveSession {
            buildExport()
        }
        screen = .export
    }

    func openItem(id: String) {
        do {
            let store = try requireStore()
            activeItemId = id
            selectedItem = try loadItemDetail(id: id, store: store)
            listeningMapJSON = ""
            screen = .item
            reportSuccess("Opened \(selectedItem.title).")
        } catch {
            reportFailure(error, context: "Open item failed")
        }
    }

    func startItem(id: String) {
        activeItemId = id
        start()
    }

    func openSession(_ session: Session) {
        stopSpeechPreviews()
        do {
            let store = try requireStore()
            activeItemId = session.itemId
            if engine == nil {
                engine = try makeEngine(store: store)
            }
            guard let engine else { return }
            if hasActiveSession {
                _ = try? engine.stopPlayback()
            }
            snapshot = try engine.inspectSession(sessionId: session.id)
            selectedItem = try loadItemDetail(id: session.itemId, store: store)
            screen = .playback
            reportSuccess("Opened session at \(session.completionPercent)% complete.")
        } catch {
            reportFailure(error, context: "Open session failed")
        }
    }

    func resumeSession(_ session: Session) {
        stopSpeechPreviews()
        do {
            let store = try requireStore()
            activeItemId = session.itemId
            if engine == nil {
                engine = try makeEngine(store: store)
            }
            guard let engine else { return }
            if hasActiveSession {
                _ = try? engine.stopPlayback()
            }
            _ = try engine.inspectSession(sessionId: session.id)
            snapshot = try engine.resumePlayback()
            selectedItem = try loadItemDetail(id: session.itemId, store: store)
            screen = .playback
            reportSuccess("Resumed session at \(session.completionPercent)% complete.")
        } catch {
            reportFailure(error, context: "Resume session failed")
        }
    }

    func deleteItem(id: String) {
        do {
            let store = try requireStore()
            guard isUserImportedItem(id) else {
                reportFailure("Seeded fixture items cannot be deleted. Use reset to restore the Gate 1 fixture set.")
                return
            }
            try store.deleteItem(id: id)
            libraryItems = try loadLibraryRows(store: store)
            if activeItemId == id {
                activeItemId = libraryItems.first?.id ?? "item-pill"
                snapshot = SessionSnapshot()
                exportPreview = ""
                selectedItem = libraryItems.first.map { (try? loadItemDetail(id: $0.id, store: store)) ?? ItemDetailState() } ?? ItemDetailState()
            }
            screen = .home
            reportSuccess("Deleted imported item.")
        } catch {
            reportFailure(error, context: "Delete failed")
        }
    }

    func skipBack() {
        run { engine in
            snapshot = try engine.skipBack(unit: skipUnit)
            refreshSelectedItem()
            reportSuccess("Skipped back.")
        }
    }

    func skipForward() {
        run { engine in
            if ttsMode == "kokoro" {
                snapshot = try engine.skipForward(unit: skipUnit, minimumDistance: kokoroSkipForwardMinimumDistance)
            } else {
                snapshot = try engine.skipForward(unit: skipUnit)
            }
            refreshSelectedItem()
            reportSuccess("Skipped forward.")
        }
    }

    func beginInterjection() {
        Task {
            let granted = await SystemRecordingClient.requestRecordPermission()
            guard granted else {
                reportFailure("Microphone access is required to record interjections. Enable microphone access in Settings and try again.")
                return
            }
            run { engine in
                snapshot = try engine.beginInterjection()
                refreshSelectedItem()
                reportSuccess("Recording interjection.")
            }
        }
    }

    func finishInterjection() {
        run { engine in
            snapshot = try engine.finishInterjection(audioRef: nil)
            refreshSelectedItem()
            if let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
            }
            reportSuccess("Saved interjection. Transcribing.")
        }
    }

    func cancelInterjection() {
        run { engine in
            snapshot = try engine.cancelInterjection()
            refreshSelectedItem()
            reportSuccess("Cancelled interjection.")
        }
    }

    func endSession() {
        run { engine in
            snapshot = try engine.endSession()
            refreshSelectedItem()
            reportSuccess("Ended session.")
        }
    }

    func summarize() {
        guard canSummarizeInterjections else {
            reportFailure("An interjection summary already exists for this session.")
            return
        }
        run { engine in
            snapshot = try engine.generateInterjectionSummary(scope: summaryScopeForCurrentTarget())
            let turnId = latestPendingSummaryTurnId() ?? "turn-summary-001"
            submitProviderJobIfNeeded(kind: "interjection_summary", turnId: turnId, messages: [summaryPrompt(interjections: engine.lastSummaryCandidates)])
            refreshSelectedItem()
            reportSuccess(snapshot.pendingAiJobStatus == "deferred" ? "Summary queued for later." : "Summary job started.")
        }
    }

    func discuss(followUp: String) {
        let trimmed = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        self.followUp(trimmed.isEmpty ? "Respond to my interjections and addenda in this listening session." : trimmed)
    }

    func playTurn(_ turn: ConversationTurn) {
        stopSpeechPreviews()
        run { engine in
            try playTurn(turn.id, engine: engine)
            reportSuccess("Playing \(turnTitleText(turn)).")
        }
    }

    func jumpToTurnChapter(turn: ConversationTurn, chapter: Chapter) {
        stopSpeechPreviews()
        pendingAutoPlayTurnId = nil
        run { engine in
            snapshot = try engine.jumpToTurnChapter(turnId: turn.id, chapterId: chapter.id)
            refreshSelectedItem()
            screen = .playback
            reportSuccess("Jumped to \(chapter.title).")
        }
    }

    private func playTurn(_ turnId: String, engine: SessionEngine) throws {
        stopSpeechPreviews()
        pendingAutoPlayTurnId = nil
        snapshot = try engine.playTurn(turnId: turnId)
        refreshSelectedItem()
        screen = .playback
    }

    private func autoPlayCompletedTurn(kind: String, turnId: String, engine: SessionEngine) throws {
        guard kind == "interjection_summary" || kind == "assistant_response" else { return }
        if shouldDeferGeneratedTurnPlayback(turnId: turnId) {
            pendingAutoPlayTurnId = turnId
            diagnostics["pendingAutoPlayTurnId"] = turnId
            diagnostics["pendingAutoPlayReason"] = "waiting_for_current_audio"
            return
        }
        try playTurn(turnId, engine: engine)
    }

    private func playPendingTurnIfReady() {
        guard let turnId = pendingAutoPlayTurnId,
              let engine else {
            return
        }
        guard snapshot.phase == .finished else {
            return
        }
        do {
            try playTurn(turnId, engine: engine)
            reportSuccess("Playing generated response.")
        } catch {
            reportFailure(error, context: "Auto-play generated response failed")
        }
    }

    private func shouldDeferGeneratedTurnPlayback(turnId: String) -> Bool {
        snapshot.status == .playing && snapshot.targetId != turnId
    }

    private func latestPendingJob(kind: String) -> AIJob? {
        guard let sessionId = snapshot.sessionId,
              let jobs = try? store?.loadAIJobs(sessionId: sessionId) else {
            return nil
        }
        return jobs.last { $0.kind == kind && $0.status != "complete" }
    }

    func followUp(_ text: String) {
        run { engine in
            snapshot = try engine.submitFollowup(text: text)
            let turnId = latestPendingJob(kind: "assistant_response")?.turnId ?? "turn-response-001"
            submitProviderJobIfNeeded(kind: "assistant_response", turnId: turnId, messages: [conversationPrompt(followUp: text)])
            refreshSelectedItem()
            reportSuccess(snapshot.pendingAiJobStatus == "deferred" ? "Follow-up queued for later." : "Follow-up submitted.")
        }
    }

    func retryPendingAI() {
        run { engine in
            guard let sessionId = snapshot.sessionId,
                  let job = try store?.loadAIJobs(sessionId: sessionId)
                    .last(where: { $0.status == "retryable" || $0.status == "pending" || $0.status == "deferred" }) else {
                reportFailure("No retryable AI job is available.")
                return
            }
            snapshot = try engine.retryAIJob(jobId: job.id)
            let turnId = job.turnId ?? (job.kind == "interjection_summary" ? "turn-summary-001" : "turn-response-001")
            let messages = job.messages.isEmpty ? [job.kind == "interjection_summary" ? summaryPrompt(interjections: engine.lastSummaryCandidates) : "Continue the discussion."] : job.messages
            submitProviderJobIfNeeded(kind: job.kind, turnId: turnId, messages: messages, force: true)
            refreshSelectedItem()
            reportSuccess("Retrying \(job.kind).")
        }
    }

    func buildExport() {
        run { engine in
            let export = try engine.buildExport(options: ExportOptions(includeFullText: true, includeReference: true, includeListeningMap: true, includeInterjections: true))
            let data = try encoder.encode(export)
            exportPreview = String(data: data, encoding: .utf8) ?? ""
            screen = .export
            reportSuccess("Built session export.")
        }
    }

    func copyPlainTextExport() {
        guard !exportPreview.isEmpty else {
            reportFailure("No export text is available yet.")
            return
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = exportPreview
        reportSuccess("Copied plain-text JSON export.")
        #else
        reportFailure("Clipboard is unavailable on this platform.")
        #endif
    }

    func deleteTranscript(interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteRepresentation(interjectionId: interjection.id, representation: "transcript")
            refreshSelectedItem()
            reportSuccess("Deleted transcript.")
        }
    }

    func deleteInterjection(_ interjection: Interjection) {
        run { engine in
            snapshot = try engine.deleteInterjection(interjectionId: interjection.id)
            refreshSelectedItem()
            reportSuccess("Deleted interjection.")
        }
    }

    func refreshDiagnostics() {
        run { engine in
            diagnostics = try engine.diagnostics()
            diagnostics["providerProbe"] = providerProbeStatus
            settingsValueChanged()
            refreshKokoroAssetStatus()
            reportSuccess("Diagnostics refreshed.")
        }
    }

    func saveProviderSettings() {
        providerModel = fallbackProviderModel()
        UserDefaults.standard.set(providerBaseURL, forKey: "providerBaseURL")
        UserDefaults.standard.set(providerModel, forKey: "providerModel")
        UserDefaults.standard.set(listeningMapModel, forKey: "listeningMapModel")
        UserDefaults.standard.set(summaryModel, forKey: "summaryModel")
        UserDefaults.standard.set(conversationModel, forKey: "conversationModel")
        UserDefaults.standard.set(skipUnit, forKey: "skipUnit")
        UserDefaults.standard.set(speechRate, forKey: "speechRate")
        UserDefaults.standard.set(speechVoiceIdentifier, forKey: "speechVoiceIdentifier")
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        UserDefaults.standard.set(kokoroVoiceName, forKey: "kokoroVoiceName")
        UserDefaults.standard.set(kokoroChunkCharacters, forKey: "kokoroChunkCharacters")
        KeychainStore.save(providerAPIKey, service: "SpokenMargins", account: "OpenAICompatibleAPIKey")
        diagnostics["providerBaseURL"] = providerBaseURL
        diagnostics["fallbackModel"] = providerModel
        diagnostics["listeningMapModel"] = listeningMapModel
        diagnostics["summaryModel"] = summaryModel
        diagnostics["conversationModel"] = conversationModel
        diagnostics["skipUnit"] = skipUnit
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsMode"] = ttsMode
        diagnostics["kokoroVoice"] = kokoroVoiceName
        diagnostics["kokoroCacheLimitMB"] = String(kokoroCacheLimitMB)
        diagnostics["kokoroChunkCharacters"] = String(format: "%.0f", kokoroChunkCharacters)
        diagnostics["apiKeyConfigured"] = providerAPIKey.isEmpty ? "false" : "true"
        if rebuildEngineForCurrentSettings() {
            screen = .settings
            reportSuccess("Provider settings saved.")
        }
    }

    func saveSpeechSettings() {
        UserDefaults.standard.set(speechRate, forKey: "speechRate")
        UserDefaults.standard.set(speechVoiceIdentifier, forKey: "speechVoiceIdentifier")
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        UserDefaults.standard.set(kokoroVoiceName, forKey: "kokoroVoiceName")
        UserDefaults.standard.set(kokoroChunkCharacters, forKey: "kokoroChunkCharacters")
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsMode"] = ttsMode
        diagnostics["kokoroVoice"] = kokoroVoiceName
        diagnostics["kokoroCacheLimitMB"] = String(kokoroCacheLimitMB)
        diagnostics["kokoroChunkCharacters"] = String(format: "%.0f", kokoroChunkCharacters)
    }

    func speechSettingsChanged() {
        if ttsMode == "kokoro", !isKokoroDeviceBuild {
            ttsMode = "systemImmediate"
            reportFailure("Kokoro requires the SpokenMarginsAppDevice scheme on a physical device.")
        }
        settingsValueChanged()
        saveSpeechSettings()
        _ = rebuildEngineForCurrentSettings()
    }

    func previewSpokenContentVoice() {
        previewSpeech(label: "Spoken Content settings", mode: .spokenContent)
    }

    func previewAppVoice() {
        saveSpeechSettings()
        previewSpeech(
            label: "app voice and rate",
            mode: .appVoice(
                voiceIdentifier: speechVoiceIdentifier.isEmpty ? nil : speechVoiceIdentifier,
                rate: Float(speechRate)
            )
        )
    }

    func previewAssistiveTechnologyVoice() {
        previewSpeech(label: "assistive technology settings", mode: .assistiveTechnology)
    }

    func refreshKokoroAssetStatus() {
        #if KOKORO_DEVICE && !targetEnvironment(simulator)
        do {
            let applicationSupportURL = try applicationSupportDirectory()
            let assets = KokoroNarrationRenderer.installedAssets(applicationSupportDirectory: applicationSupportURL)
            let hasModel = assets.modelURL != nil
            let hasVoices = assets.voicesURL != nil
            diagnostics["kokoroModel"] = hasModel ? "installed" : "missing"
            diagnostics["kokoroVoices"] = hasVoices ? "installed" : "missing"
            if hasModel && hasVoices {
                kokoroStatus = "Assets installed."
            } else if hasModel {
                kokoroStatus = "Model installed; voices.npz missing."
            } else if hasVoices {
                kokoroStatus = "Voices installed; kokoro-v1_0.safetensors missing."
            } else {
                kokoroStatus = "Import kokoro-v1_0.safetensors and voices.npz."
            }
            diagnostics["kokoroStatus"] = kokoroStatus
        } catch {
            kokoroStatus = "Asset check failed: \(error.localizedDescription)"
            diagnostics["kokoroStatus"] = kokoroStatus
        }
        #else
        kokoroStatus = "Kokoro renderer is not linked in this build."
        diagnostics["kokoroStatus"] = kokoroStatus
        #endif
    }

    func previewKokoroVoice() {
        guard !isRenderingKokoroPreview else { return }
        saveSpeechSettings()
        isRenderingKokoroPreview = true
        kokoroStatus = "Preparing Kokoro preview..."
        diagnostics["kokoroStatus"] = kokoroStatus

        let voiceName = kokoroVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "am_echo" : kokoroVoiceName
        let cacheLimitBytes = kokoroCacheLimitBytes
        let kokoroSpeed = Float(speechRate / 0.5)
        let itemId = selectedItem.id.isEmpty ? activeItemId : selectedItem.id
        let sourceText = "Spoken Margins Kokoro preview. This is a short on-device voice test."

        Task.detached { [voiceName, cacheLimitBytes, kokoroSpeed, itemId, sourceText] in
            #if KOKORO_DEVICE && !targetEnvironment(simulator) && canImport(AVFoundation)
            do {
                guard KokoroNarrationRenderer.isRuntimeSupported else {
                    throw KokoroNarrationError.unavailableOnSimulator
                }
                let applicationSupportURL = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let assets = KokoroNarrationRenderer.installedAssets(applicationSupportDirectory: applicationSupportURL)
                guard let modelURL = assets.modelURL else {
                    throw KokoroNarrationError.missingModel
                }
                guard let voicesURL = assets.voicesURL else {
                    throw KokoroNarrationError.missingVoices
                }
                await MainActor.run {
                    self.kokoroStatus = "Kokoro assets found. Rendering short preview..."
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                }
                let cachesURL = try FileManager.default.url(
                    for: .cachesDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let outputDirectory = cachesURL.appending(path: "KokoroPreview", directoryHint: .isDirectory)
                let configured = KokoroNarrationRenderer.configureMemoryForDiagnostics(cacheLimitBytes: cacheLimitBytes)
                NSLog("SpokenMargins Kokoro preview memory configured %@", configured.description)
                let renderer = try KokoroNarrationRenderer(
                    modelURL: modelURL,
                    voicesURL: voicesURL,
                    outputDirectory: outputDirectory
                )
                let before = KokoroNarrationRenderer.memorySnapshot()
                let result = try renderer.render(
                    text: sourceText,
                    itemId: itemId,
                    chunkId: "preview",
                    voiceName: voiceName,
                    speed: kokoroSpeed
                )
                let after = KokoroNarrationRenderer.memorySnapshot()
                let final = KokoroNarrationRenderer.clearMemoryCache()
                NSLog("SpokenMargins Kokoro preview memory before=%@ after=%@ final=%@", before.description, after.description, final.description)
                await MainActor.run {
                    do {
                        self.kokoroStatus = "Kokoro rendered. Starting playback..."
                        self.diagnostics["kokoroStatus"] = self.kokoroStatus
                        self.diagnostics["kokoroMemory.preview.configured"] = configured.description
                        self.diagnostics["kokoroMemory.preview.before"] = before.description
                        self.diagnostics["kokoroMemory.preview.after"] = after.description
                        self.diagnostics["kokoroMemory.preview.final"] = final.description
                        try self.playKokoroPreview(url: result.audioURL)
                        self.kokoroStatus = "Rendered \(String(format: "%.1f", result.duration))s with \(voiceName)"
                        self.diagnostics["kokoroStatus"] = self.kokoroStatus
                        self.diagnostics["lastSpeechPreview"] = "Kokoro \(voiceName)"
                        self.reportSuccess("Previewing Kokoro \(voiceName).")
                    } catch {
                        self.kokoroStatus = "Playback failed: \(error.localizedDescription)"
                        self.diagnostics["kokoroStatus"] = self.kokoroStatus
                        self.reportFailure(error, context: "Kokoro preview playback failed")
                    }
                    self.isRenderingKokoroPreview = false
                }
            } catch {
                await MainActor.run {
                    self.kokoroStatus = error.localizedDescription
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                    self.isRenderingKokoroPreview = false
                    self.reportFailure(error, context: "Kokoro preview failed")
                }
            }
            #else
            await MainActor.run {
                self.kokoroStatus = "Kokoro renderer is not linked in this build."
                self.diagnostics["kokoroStatus"] = self.kokoroStatus
                self.isRenderingKokoroPreview = false
                self.reportFailure("Kokoro renderer is not linked in this build.")
            }
            #endif
        }
    }

    func runKokoroMemoryCheck() {
        guard !isRunningKokoroMemoryCheck else { return }
        saveSpeechSettings()
        isRunningKokoroMemoryCheck = true
        kokoroStatus = "Starting Kokoro memory check..."
        diagnostics["kokoroStatus"] = kokoroStatus

        let voiceName = kokoroVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "am_echo" : kokoroVoiceName
        let cacheLimitBytes = kokoroCacheLimitBytes
        let itemId = selectedItem.id.isEmpty ? activeItemId : selectedItem.id
        let sourceText = "Spoken Margins Kokoro memory check. This renders twice without playback."

        Task.detached { [voiceName, cacheLimitBytes, itemId, sourceText] in
            #if KOKORO_DEVICE && !targetEnvironment(simulator)
            do {
                guard KokoroNarrationRenderer.isRuntimeSupported else {
                    throw KokoroNarrationError.unavailableOnSimulator
                }
                let applicationSupportURL = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let assets = KokoroNarrationRenderer.installedAssets(applicationSupportDirectory: applicationSupportURL)
                guard let modelURL = assets.modelURL else {
                    throw KokoroNarrationError.missingModel
                }
                guard let voicesURL = assets.voicesURL else {
                    throw KokoroNarrationError.missingVoices
                }
                let cachesURL = try FileManager.default.url(
                    for: .cachesDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let outputDirectory = cachesURL.appending(path: "KokoroMemoryCheck", directoryHint: .isDirectory)
                let configured = KokoroNarrationRenderer.configureMemoryForDiagnostics(cacheLimitBytes: cacheLimitBytes)
                NSLog("SpokenMargins Kokoro memory check configured %@", configured.description)
                await MainActor.run {
                    self.kokoroStatus = "Memory check configured: \(configured)"
                    self.diagnostics["kokoroMemory.configured"] = configured.description
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                }

                let renderer = try KokoroNarrationRenderer(
                    modelURL: modelURL,
                    voicesURL: voicesURL,
                    outputDirectory: outputDirectory
                )

                await MainActor.run {
                    self.kokoroStatus = "Memory check rendering pass 1 of 2..."
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                }
                let first = try renderer.render(
                    text: sourceText,
                    itemId: itemId,
                    chunkId: "memory-check-1",
                    voiceName: voiceName,
                    speed: 1.0
                )
                let afterFirst = KokoroNarrationRenderer.memorySnapshot()
                await MainActor.run {
                    self.kokoroStatus = "Pass 1 rendered \(String(format: "%.1f", first.duration))s. Clearing cache..."
                    self.diagnostics["kokoroMemory.afterFirst"] = afterFirst.description
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                }

                let afterClear = KokoroNarrationRenderer.clearMemoryCache()
                await MainActor.run {
                    self.kokoroStatus = "Memory check rendering pass 2 of 2..."
                    self.diagnostics["kokoroMemory.afterClear"] = afterClear.description
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                }
                let second = try renderer.render(
                    text: sourceText,
                    itemId: itemId,
                    chunkId: "memory-check-2",
                    voiceName: voiceName,
                    speed: 1.0
                )
                let afterSecond = KokoroNarrationRenderer.memorySnapshot()
                let final = KokoroNarrationRenderer.clearMemoryCache()

                await MainActor.run {
                    self.kokoroStatus = "Memory check passed. Passes: \(String(format: "%.1f", first.duration))s, \(String(format: "%.1f", second.duration))s. Final \(final)"
                    self.diagnostics["kokoroMemory.afterSecond"] = afterSecond.description
                    self.diagnostics["kokoroMemory.final"] = final.description
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                    self.isRunningKokoroMemoryCheck = false
                    self.reportSuccess("Kokoro memory check completed.")
                }
            } catch {
                await MainActor.run {
                    self.kokoroStatus = "Memory check failed: \(error.localizedDescription)"
                    self.diagnostics["kokoroStatus"] = self.kokoroStatus
                    self.isRunningKokoroMemoryCheck = false
                    self.reportFailure(error, context: "Kokoro memory check failed")
                }
            }
            #else
            await MainActor.run {
                self.kokoroStatus = "Kokoro renderer is not linked in this build."
                self.diagnostics["kokoroStatus"] = self.kokoroStatus
                self.isRunningKokoroMemoryCheck = false
                self.reportFailure("Kokoro renderer is not linked in this build.")
            }
            #endif
        }
    }

    func runtimeProfileChanged() {
        diagnostics["runtimeProfile"] = selectedProfileId
        if rebuildEngineForCurrentSettings() {
            reportSuccess("Runtime profile set to \(selectedProfileId).")
        }
    }

    func settingsValueChanged() {
        diagnostics["providerBaseURL"] = providerBaseURL
        diagnostics["fallbackModel"] = fallbackProviderModel()
        diagnostics["listeningMapModel"] = listeningMapModel
        diagnostics["summaryModel"] = summaryModel
        diagnostics["conversationModel"] = conversationModel
        diagnostics["skipUnit"] = skipUnit
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsMode"] = ttsMode
        diagnostics["kokoroVoice"] = kokoroVoiceName
        diagnostics["kokoroCacheLimitMB"] = String(kokoroCacheLimitMB)
        diagnostics["kokoroChunkCharacters"] = String(format: "%.0f", kokoroChunkCharacters)
    }

    func probeProvider() {
        saveProviderSettings()
        providerProbeStatus = "Checking..."
        guard let url = URL(string: providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else {
            providerProbeStatus = "Invalid URL"
            reportFailure("Invalid provider URL.")
            return
        }
        var request = URLRequest(url: url)
        if !providerAPIKey.isEmpty {
            request.setValue("Bearer \(providerAPIKey)", forHTTPHeaderField: "Authorization")
        }
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                await MainActor.run {
                    providerProbeStatus = (200..<300).contains(status) ? "Reachable (\(status))" : "HTTP \(status)"
                    diagnostics["providerProbe"] = providerProbeStatus
                    reportSuccess("Provider probe completed: \(providerProbeStatus).")
                }
            } catch {
                await MainActor.run {
                    providerProbeStatus = "Failed: \(error.localizedDescription)"
                    reportFailure(error, context: "Provider probe failed")
                }
            }
        }
    }

    var hasActiveSession: Bool {
        snapshot.sessionId != nil
    }

    var canFinishInterjection: Bool {
        snapshot.isRecording
    }

    var canSummarizeInterjections: Bool {
        hasActiveSession && !unsummarizedInterjectionsForCurrentTarget().isEmpty
    }

    var interjectionButtonTitle: String {
        snapshot.phase == .finished || snapshot.progressPercent >= 100 || selectedItem.turns.contains(where: { $0.turnType == "interjection_summary" }) ? "Add Addendum" : "Interject"
    }

    var speechVoiceDescription: String {
        guard !speechVoiceIdentifier.isEmpty else {
            return "System Spoken Content Voice (Siri falls back)"
        }
        if let voice = speechVoiceOptions.first(where: { $0.id == speechVoiceIdentifier }) {
            return "\(voice.name) (\(voice.language), \(voice.quality))"
        }
        return speechVoiceIdentifier
    }

    var speechRateDescription: String {
        if ttsMode == "kokoro" {
            return String(format: "Kokoro %.2fx", max(0.65, min(1.75, speechRate / 0.5)))
        }
        return String(format: "System %.2f", speechRate)
    }

    var isKokoroDeviceBuild: Bool {
        #if KOKORO_DEVICE && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    var kokoroCacheLimitBytes: Int {
        kokoroCacheLimitMB * 1024 * 1024
    }

    var kokoroCacheLimitMB: Int {
        256
    }

    var kokoroChunkCharacterLimit: Int {
        Int(max(80, min(140, kokoroChunkCharacters)).rounded())
    }

    var kokoroSkipForwardMinimumDistance: Int {
        max(220, kokoroChunkCharacterLimit * 2)
    }

    var currentChapter: Chapter? {
        selectedItem.chapters.last { $0.percent <= snapshot.sourceProgressPercent } ?? selectedItem.chapters.first
    }

    private func run(_ operation: (SessionEngine) throws -> Void) {
        if engine == nil {
            resetAndSeed()
        }
        guard let engine else { return }
        do {
            try operation(engine)
        } catch {
            reportFailure(error)
        }
    }

    private func previewSpeech(label: String, mode: AppSpeechPreviewMode) {
        #if canImport(AVFoundation)
        do {
            kokoroPreviewPlayer?.stop()
            if speechPreviewSynthesizer.isSpeaking {
                speechPreviewSynthesizer.stopSpeaking(at: .immediate)
            }
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let utterance = AVSpeechUtterance(string: "Spoken Margins preview. This is the \(label) path.")
            switch mode {
            case .spokenContent:
                utterance.rate = Float(speechRate)
            case .appVoice(let voiceIdentifier, let rate):
                utterance.rate = rate
                if let voiceIdentifier,
                   let configuredVoice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
                    utterance.voice = configuredVoice
                }
            case .assistiveTechnology:
                utterance.rate = Float(speechRate)
                utterance.prefersAssistiveTechnologySettings = true
            }
            speechPreviewSynthesizer.speak(utterance)
            diagnostics["lastSpeechPreview"] = label
            reportSuccess("Previewing \(label).")
        } catch {
            reportFailure(error, context: "Speech preview failed")
        }
        #else
        reportFailure("Speech preview unavailable on this platform.")
        #endif
    }

    #if canImport(AVFoundation)
    private func stopSpeechPreviews() {
        if speechPreviewSynthesizer.isSpeaking {
            speechPreviewSynthesizer.stopSpeaking(at: .immediate)
        }
        kokoroPreviewPlayer?.stop()
    }

    private func playKokoroPreview(url: URL) throws {
        if speechPreviewSynthesizer.isSpeaking {
            speechPreviewSynthesizer.stopSpeaking(at: .immediate)
        }
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        kokoroPreviewPlayer = try AVAudioPlayer(contentsOf: url)
        kokoroPreviewPlayer?.prepareToPlay()
        kokoroPreviewPlayer?.play()
    }
    #else
    private func stopSpeechPreviews() {}
    #endif

    private func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private func kokoroAssetsDirectory() throws -> URL {
        try applicationSupportDirectory().appending(path: "Kokoro", directoryHint: .isDirectory)
    }

    private func summaryScopeForCurrentTarget() -> SummaryScope {
        switch currentPlaybackTargetType {
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            return SummaryScope(targetType: "turn", turnId: currentPlaybackTargetId)
        default:
            return SummaryScope(targetType: "item")
        }
    }

    private func latestPendingSummaryTurnId() -> String? {
        guard let sessionId = snapshot.sessionId,
              let turns = try? store?.loadTurns(sessionId: sessionId) else { return nil }
        return turns
            .filter { $0.turnType == "interjection_summary" && $0.status != "complete" }
            .last?.id
    }

    private func unsummarizedInterjectionsForCurrentTarget() -> [Interjection] {
        let summarized = Set(selectedItem.turns
            .filter { $0.turnType == "interjection_summary" && $0.status != "failed" }
            .flatMap(\.sourceInterjectionIds))
        let targetType = currentPlaybackTargetType
        let targetId = currentPlaybackTargetId
        return selectedItem.interjections.filter { interjection in
            guard !summarized.contains(interjection.id) else { return false }
            switch targetType {
            case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
                return interjection.targetId == targetId && interjection.targetType != .item
            default:
                return interjection.targetType == .item
            }
        }
    }

    private var currentPlaybackTargetType: String {
        (engine?.currentSession?.currentTargetType).map(\.rawValue) ?? snapshot.targetType ?? TargetType.itemTextTTS.rawValue
    }

    private var currentPlaybackTargetId: String? {
        engine?.currentSession?.currentTargetId ?? snapshot.itemId
    }

    private func rebuildEngineForCurrentSettings() -> Bool {
        guard let store else { return true }
        do {
            engine = try makeEngine(store: store)
            return true
        } catch {
            reportFailure(error, context: "Runtime profile update failed")
            return false
        }
    }

    private func makeEngine(store: SQLiteSessionStore) throws -> SessionEngine {
        let profile = try loadProfile(id: selectedProfileId)
        let provider: AIProviderClient
        if let url = URL(string: providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            provider = OpenAICompatibleProvider(baseURL: url, model: fallbackProviderModel(), apiKeyReference: providerAPIKey.isEmpty ? nil : "keychain:SpokenMargins/OpenAICompatibleAPIKey")
        } else {
            provider = FixtureAIProvider()
        }
        return SessionEngine(
            profile: profile,
            repository: store,
            audio: try makeAudioPlaybackClient(),
            recorder: SystemRecordingClient(),
            aiProvider: provider
        )
    }

    private func makeAudioPlaybackClient() throws -> AudioPlaybackClient {
        #if targetEnvironment(simulator)
        if ttsMode == "kokoro" {
            diagnostics["sessionTTS"] = "Kokoro simulator stub"
            return FakeGeneratedSpeechPlaybackClient()
        }
        #endif
        #if KOKORO_DEVICE && !targetEnvironment(simulator) && canImport(AVFoundation)
        if ttsMode == "kokoro" {
            let supportDirectory = try applicationSupportDirectory()
            let cachesDirectory = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            diagnostics["sessionTTS"] = "Kokoro bounded pre-render"
            return KokoroSpeechPlaybackClient(
                applicationSupportDirectory: supportDirectory,
                outputDirectory: cachesDirectory.appending(path: "KokoroPlayback", directoryHint: .isDirectory),
                voiceName: kokoroVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "am_echo" : kokoroVoiceName,
                speed: Float(speechRate / 0.5),
                cacheLimitBytes: kokoroCacheLimitBytes,
                maxCharacters: kokoroChunkCharacterLimit
            )
        }
        #endif
        if ttsMode == "kokoro" {
            diagnostics["sessionTTS"] = "Kokoro unavailable in this build; using system speech"
        } else {
            diagnostics["sessionTTS"] = "System speech"
        }
        return SystemSpeechPlaybackClient()
    }

    private func loadLibraryRows(store: SQLiteSessionStore) throws -> [LibraryItemRow] {
        try store.listItems().map { item in
            LibraryItemRow(
                id: item.id,
                title: item.title,
                status: item.status,
                canDelete: isUserImportedItem(item.id)
            )
        }
    }

    private func isUserImportedItem(_ id: String) -> Bool {
        id.hasPrefix("item-import-") || id.hasPrefix("item-obsidian-")
    }

    private func submitProviderJobIfNeeded(kind: String, turnId: String, messages: [String], force: Bool = false) {
        guard force || snapshot.pendingAiJobStatus == "pending" else { return }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            markProviderFailure("provider_api_key_missing", userMessage: "AI provider API key required.")
            screen = .settings
            return
        }
        let selectedModel = modelForAIJob(kind: kind)
        recordModelForPendingJob(kind: kind, model: selectedModel)
        guard let request = makeChatCompletionsRequest(messages: messages, model: selectedModel, systemPrompt: systemPromptForAIJob(kind: kind)) else {
            markProviderFailure("provider_url_invalid", userMessage: "AI provider URL is invalid.")
            screen = .settings
            return
        }
        statusMessage = "Calling \(selectedModel) for \(kind)."
        lastError = nil
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    let body = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                    throw ProviderCallError.http(status, body)
                }
                let text = try decodeProviderText(data)
                await MainActor.run {
                    do {
                        guard let engine else { return }
                        let shouldDeferPlayback = shouldDeferGeneratedTurnPlayback(turnId: turnId)
                        snapshot = try engine.aiStreamDelta(turnId: turnId, content: text)
                        snapshot = try engine.aiJobCompleted(turnId: turnId)
                        refreshSelectedItem()
                        if shouldDeferPlayback {
                            pendingAutoPlayTurnId = turnId
                            diagnostics["pendingAutoPlayTurnId"] = turnId
                            diagnostics["pendingAutoPlayReason"] = "waiting_for_current_audio"
                        } else {
                            try autoPlayCompletedTurn(kind: kind, turnId: turnId, engine: engine)
                        }
                        reportSuccess(pendingAutoPlayTurnId == turnId ? "Provider response saved. Playback will start when the item finishes." : "Provider response saved.")
                    } catch {
                        reportFailure(error, context: "Provider response persistence failed")
                    }
                }
            } catch {
                await MainActor.run {
                    markProviderFailure(String(describing: error), userMessage: "Provider call failed.")
                }
            }
        }
    }

    private func callProvider(messages: [String], model: String, systemPrompt: String) async throws -> String {
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCallError.missingAPIKey
        }
        guard let request = makeChatCompletionsRequest(messages: messages, model: model, systemPrompt: systemPrompt) else {
            throw ProviderCallError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw ProviderCallError.http(status, body)
        }
        return try decodeProviderText(data)
    }

    private func makeChatCompletionsRequest(messages: [String], model: String, systemPrompt: String) -> URLRequest? {
        let trimmed = providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(providerAPIKey)", forHTTPHeaderField: "Authorization")
        let payload = ChatCompletionRequest(
            model: model,
            messages: [ChatMessage(role: "system", content: systemPrompt)] +
                messages.map { ChatMessage(role: "user", content: $0) },
            temperature: 0.2
        )
        request.httpBody = try? JSONEncoder().encode(payload)
        return request
    }

    private func modelForAIJob(kind: String) -> String {
        let configured: String
        switch kind {
        case "listening_map":
            configured = listeningMapModel
        case "interjection_summary":
            configured = summaryModel
        case "assistant_response":
            configured = conversationModel
        default:
            configured = fallbackProviderModel()
        }
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackProviderModel() : trimmed
    }

    private func fallbackProviderModel() -> String {
        let listeningMapFallback = listeningMapModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !listeningMapFallback.isEmpty {
            return listeningMapFallback
        }
        let storedFallback = providerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return storedFallback.isEmpty ? "gpt-4.1-mini" : storedFallback
    }

    private func systemPromptForAIJob(kind: String) -> String {
        switch kind {
        case "listening_map":
            return "Return only strict JSON for the requested Listening Map. Do not wrap the response in Markdown."
        case "interjection_summary":
            return """
            You are having a Spoken Margins listening-session debrief with the user.
            Summarize patterns in the user's interjections and identify the key points they are making in relation to the source.
            Do not merely summarize the source. Use the source text as context.

            Respond exactly:
            <sm_summary>
            A short spoken introduction to the response.
            </sm_summary>
            <sm_response>
            A text-to-speech friendly synthesis of the user's engagement with the source.
            </sm_response>
            <sm_chapters_json>
            {"schemaVersion":"assistant-response-map.v1","chapters":[...]}
            </sm_chapters_json>

            Chapter anchors must be exact phrases from your response.
            """
        case "assistant_response":
            return """
            You are continuing a Spoken Margins listening session.

            Respond exactly:
            <sm_summary>
            A short spoken introduction to the response.
            </sm_summary>
            <sm_response>
            Your full spoken response.
            </sm_response>
            <sm_chapters_json>
            {"schemaVersion":"assistant-response-map.v1","chapters":[...]}
            </sm_chapters_json>

            The response should be useful for immediate text-to-speech.
            Chapter anchors must be exact phrases from the full response.
            """
        default:
            return "You are the Spoken Margins Gate 1 assistant. Preserve user source meaning, answer concisely, and make failures explicit."
        }
    }

    private func recordModelForPendingJob(kind: String, model: String) {
        guard let sessionId = snapshot.sessionId,
              let store,
              var job = try? store.loadAIJobs(sessionId: sessionId).last(where: { $0.kind == kind && $0.status != "complete" }) else {
            return
        }
        job.model = model
        try? store.updateAIJob(job)
        diagnostics["last\(kind.replacingOccurrences(of: "_", with: " ").capitalized.replacingOccurrences(of: " ", with: ""))Model"] = model
    }

    private func decodeProviderText(_ data: Data) throws -> String {
        if let response = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
           let content = response.choices.first?.message.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        if let raw = String(data: data, encoding: .utf8),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return raw
        }
        throw ProviderCallError.emptyResponse
    }

    private func listeningMapPrompt(sourceText: String) -> String {
        """
        Create a Listening Map for the item content below.
        The user will listen to this content through text-to-speech. The interface may eventually be as small as an Apple Watch, so the map must support quick navigation and situational awareness.
        Return only strict JSON. Use schemaVersion "listening-map.v1".
        Required object shape:
        {
          "schemaVersion": "listening-map.v1",
          "overview": "one or two sentence overview",
          "claims": [{"id":"claim-1","text":"main claim"}],
          "chapters": [
            {
              "id": "ch-1",
              "title": "short navigation title",
              "description": "what this chapter covers",
              "anchor": "exact contiguous phrase copied from ITEM CONTENT"
            }
          ]
        }
        Requirements: brief overview, main claims, navigable chapters, exact contiguous anchors copied from source, no invented anchors, no percent estimates, no start/end character offsets.
        JSON syntax rules: use ASCII double quotes for object keys and string delimiters. Preserve source punctuation, including curly quotes and apostrophes, only inside string values.
        Anchor quality rules: every anchor must be at least five words when possible; copy ordinary prose from the source, not headings; do not paraphrase; do not use ellipses.
        ITEM CONTENT:
        <<<
        \(sourceText)
        >>>
        """
    }

    private func listeningMapRepairPrompt(sourceText: String, invalidResponse: String, error: String) -> String {
        """
        Repair the Listening Map JSON below. Return only strict JSON with schemaVersion "listening-map.v1".

        Parser/validator error:
        \(error)

        Requirements:
        - Keep only JSON. No Markdown fences.
        - Use ASCII double quotes for JSON object keys and string delimiters.
        - Preserve source punctuation, including curly quotes and apostrophes, only inside string values.
        - Every chapter must have id, title, description, and anchor.
        - Every anchor must be an exact contiguous phrase copied from ITEM CONTENT, preferably at least five words.
        - Do not include percent estimates.
        - Prefer preserving the previous chapter intent if the anchor can be fixed.

        INVALID RESPONSE:
        <<<
        \(invalidResponse)
        >>>

        ITEM CONTENT:
        <<<
        \(sourceText)
        >>>
        """
    }

    private func markProviderFailure(_ error: String, userMessage: String) {
        do {
            if let engine {
                snapshot = try engine.aiProviderFailed(error: error)
                refreshSelectedItem()
            }
        } catch {
            diagnostics["providerFailurePersistence"] = String(describing: error)
        }
        providerProbeStatus = userMessage
        diagnostics["providerProbe"] = providerProbeStatus
        reportFailure(userMessage)
    }

    private func latestInterjectionNeedingTranscription() -> Interjection? {
        guard let sessionId = snapshot.sessionId,
              let interjections = try? store?.loadInterjections(sessionId: sessionId) else { return nil }
        return interjections.last { $0.transcriptionStatus == "pending" && $0.audioPath != nil }
    }

    private func scheduleTranscription(for interjection: Interjection) {
        guard let audioPath = interjection.audioPath else { return }
        Task {
            do {
                let transcript = try await transcriptionClient.transcribe(audioPath: audioPath)
                await MainActor.run {
                    run { engine in
                        snapshot = try engine.transcriptionCompleted(interjectionId: interjection.id, transcript: transcript)
                        refreshSelectedItem()
                        reportSuccess("Transcribed interjection.")
                    }
                }
            } catch {
                await MainActor.run {
                    run { engine in
                        snapshot = try engine.transcriptionFailed(interjectionId: interjection.id, error: String(describing: error))
                        refreshSelectedItem()
                        reportFailure("Audio saved. Transcript failed.")
                    }
                }
            }
        }
    }

    private func summaryPrompt(interjections: [Interjection]) -> String {
        """
        I would like to have a session with you, the article, and my interjections below.
        \(sessionContextJSON(interjections: interjections, currentFollowUp: nil))
        """
    }

    private func conversationPrompt(followUp: String) -> String {
        """
        Respond to the user's current follow-up in the context of the source, Listening Map, interjections, and recent session turns.
        Focus on the user's thinking and questions. Do not summarize the source unless needed.
        \(sessionContextJSON(interjections: selectedItem.interjections, currentFollowUp: followUp))
        """
    }

    private func sessionContextJSON(interjections: [Interjection], currentFollowUp: String?) -> String {
        let map: [String: Any] = [
            "schemaVersion": currentFollowUp == nil ? "session-export.v1" : "conversation-context.v1",
            "item": [
                "id": selectedItem.id,
                "title": selectedItem.title,
                "externalReference": selectedItem.externalReference,
                "text": selectedItem.text
            ],
            "listeningMap": [
                "overview": selectedItem.overview,
                "chapters": selectedItem.chapters.map { chapter in
                    [
                        "id": chapter.id,
                        "title": chapter.title,
                        "startChar": chapter.startChar,
                        "endChar": chapter.endChar
                    ]
                }
            ],
            "interjections": interjections.map { interjection in
                [
                    "id": interjection.id,
                    "targetType": interjection.targetType.rawValue,
                    "targetId": interjection.targetId,
                    "anchorBefore": interjection.anchor.anchorBefore,
                    "anchorAfter": interjection.anchor.anchorAfter,
                    "transcriptionStatus": interjection.transcriptionStatus,
                    "transcript": interjection.cleanedTranscript ?? interjection.transcript ?? "pending",
                    "audioPath": interjection.audioPath ?? ""
                ]
            },
            "recentTurns": selectedItem.turns.suffix(6).map { turn in
                [
                    "id": turn.id,
                    "role": turn.role,
                    "turnType": turn.turnType,
                    "status": turn.status,
                    "text": turn.summary ?? turn.text ?? turn.rawText ?? ""
                ]
            },
            "currentFollowUp": currentFollowUp.map { $0 as Any } ?? NSNull()
        ]
        let data = (try? JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func turnTitleText(_ turn: ConversationTurn) -> String {
        switch turn.turnType {
        case "interjection_summary":
            return "summary"
        case "assistant_response":
            return "AI response"
        default:
            return "turn"
        }
    }

    private func obsidianItemId(fileName: String, index: Int) -> String {
        let base = (fileName as NSString).deletingPathExtension
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "item-obsidian-\(Int(Date().timeIntervalSince1970))-\(index)-\(base.isEmpty ? "clip" : base)"
    }

    private func parseListeningMapJSON(_ raw: String, item: Item) throws -> ListeningMap {
        let trimmed = repairedJSONObjectString(from: raw)
        guard !trimmed.isEmpty else {
            throw ManualListeningMapError.empty
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ManualListeningMapError.invalidUTF8
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ManualListeningMapError.jsonParseFailed(String(describing: error))
        }
        guard let root = parsed as? [String: Any] else {
            throw ManualListeningMapError.rootMustBeObject
        }
        guard root["schemaVersion"] as? String == "listening-map.v1" else {
            throw ManualListeningMapError.invalidSchema
        }
        guard let overview = root["overview"] as? String,
              !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManualListeningMapError.missingOverview
        }
        guard let rawChapters = root["chapters"] as? [[String: Any]], !rawChapters.isEmpty else {
            throw ManualListeningMapError.missingChapters
        }
        guard let text = item.text, !text.isEmpty else {
            throw ManualListeningMapError.itemHasNoText
        }

        var ids = Set<String>()
        let chapters = try rawChapters.map { chapterObject in
            guard let id = chapterObject["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterId
            }
            guard ids.insert(id).inserted else {
                throw ManualListeningMapError.duplicateChapterId(id)
            }
            guard let title = chapterObject["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterTitle(id)
            }
            guard let description = chapterObject["description"] as? String,
                  !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterDescription(id)
            }
            if let start = chapterObject["startChar"] as? Int,
               let end = chapterObject["endChar"] as? Int {
                return try validatedChapter(id: id, title: title, start: start, end: end, text: text)
            }
            guard let anchor = (chapterObject["anchor"] as? String) ?? (chapterObject["anchorText"] as? String),
                  !anchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManualListeningMapError.missingChapterAnchor(id)
            }
            let range = try resolveAnchor(anchor, in: text, chapterId: id)
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            return try validatedChapter(id: id, title: title, start: start, end: end, text: text)
        }
        .sorted { lhs, rhs in
            if lhs.startChar == rhs.startChar {
                return lhs.id < rhs.id
            }
            return lhs.startChar < rhs.startChar
        }

        return ListeningMap(
            id: "map-\(item.id)-manual",
            itemId: item.id,
            overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
            chapters: chapters
        )
    }

    private func repairedJSONObjectString(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first <= last {
            text = String(text[first...last])
        }
        text = normalizingJSONDelimitersOutsideStrings(in: text)
        text = removingJSONCommentsOutsideStrings(from: text)
        text = escapingControlCharactersInsideJSONStringLiterals(in: text)
        text = text
            .replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizingJSONDelimitersOutsideStrings(in text: String) -> String {
        var output = ""
        var inString = false
        var escaped = false

        for scalar in text.unicodeScalars {
            if inString {
                output.unicodeScalars.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                continue
            }

            if scalar == "\"" || scalar == "“" || scalar == "”" {
                output += "\""
                inString = true
            } else {
                output.unicodeScalars.append(scalar)
            }
        }

        return output
    }

    private func removingJSONCommentsOutsideStrings(from text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = ""
        var index = 0
        var inString = false
        var escaped = false

        while index < scalars.count {
            let scalar = scalars[index]
            if inString {
                output.unicodeScalars.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if scalar == "\"" {
                inString = true
                output.unicodeScalars.append(scalar)
                index += 1
            } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                index += 2
                while index < scalars.count, scalars[index] != "\n" {
                    index += 1
                }
            } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                index += 2
                while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, scalars.count)
            } else {
                output.unicodeScalars.append(scalar)
                index += 1
            }
        }

        return output
    }

    private func escapingControlCharactersInsideJSONStringLiterals(in text: String) -> String {
        var output = ""
        var inString = false
        var escaped = false

        for scalar in text.unicodeScalars {
            if inString {
                if escaped {
                    output.unicodeScalars.append(scalar)
                    escaped = false
                } else if scalar == "\\" {
                    output.unicodeScalars.append(scalar)
                    escaped = true
                } else if scalar == "\"" {
                    output.unicodeScalars.append(scalar)
                    inString = false
                } else if scalar.value < 0x20 {
                    switch scalar {
                    case "\n":
                        output += "\\n"
                    case "\r":
                        output += "\\r"
                    case "\t":
                        output += "\\t"
                    default:
                        output += String(format: "\\u%04X", scalar.value)
                    }
                } else {
                    output.unicodeScalars.append(scalar)
                }
            } else {
                output.unicodeScalars.append(scalar)
                if scalar == "\"" {
                    inString = true
                }
            }
        }

        return output
    }

    private func validatedChapter(id: String, title: String, start: Int, end: Int, text: String) throws -> Chapter {
        guard start >= 0, end > start, end <= text.count else {
            throw ManualListeningMapError.invalidChapterRange(id)
        }
        let percent = text.isEmpty ? 0 : Int((Double(start) / Double(text.count)) * 100)
        return Chapter(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            startChar: start,
            endChar: end,
            percent: min(100, max(0, percent))
        )
    }

    private func resolveAnchor(_ anchor: String, in text: String, chapterId: String) throws -> Range<String.Index> {
        let trimmedAnchor = anchor.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = text.range(of: trimmedAnchor) {
            return exact
        }
        if let folded = text.range(of: trimmedAnchor, options: [.caseInsensitive, .diacriticInsensitive]) {
            return folded
        }
        if let normalized = normalizedAnchorRange(trimmedAnchor, in: text) {
            return normalized
        }
        if let ngram = ngramAnchorRange(trimmedAnchor, in: text) {
            return ngram
        }
        throw ManualListeningMapError.anchorNotFound(chapterId)
    }

    private func ngramAnchorRange(_ anchor: String, in text: String) -> Range<String.Index>? {
        let words = anchor
            .replacingOccurrences(of: #"[^A-Za-z0-9']+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
        guard words.count >= 5 else { return nil }
        let maxWindow = min(12, words.count)
        for size in stride(from: maxWindow, through: 5, by: -1) {
            guard words.count >= size else { continue }
            for start in 0...(words.count - size) {
                let phrase = words[start..<(start + size)].joined(separator: " ")
                if let range = normalizedAnchorRange(phrase, in: text) {
                    return range
                }
            }
        }
        return nil
    }

    private func normalizedAnchorRange(_ anchor: String, in text: String) -> Range<String.Index>? {
        let source = normalizedSearchIndex(for: text)
        let target = normalizedSearchIndex(for: anchor).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, let range = source.text.range(of: target) else { return nil }
        let lowerOffset = source.text.distance(from: source.text.startIndex, to: range.lowerBound)
        let upperOffset = source.text.distance(from: source.text.startIndex, to: range.upperBound)
        guard lowerOffset < source.indices.count, upperOffset > 0 else { return nil }
        let lower = source.indices[lowerOffset]
        let last = source.indices[min(source.indices.count - 1, upperOffset - 1)]
        let upper = text.index(after: last)
        return lower..<upper
    }

    private func normalizedSearchIndex(for text: String) -> (text: String, indices: [String.Index]) {
        var normalized = ""
        var indices: [String.Index] = []
        var lastWasSpace = true
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            let folded = String(char).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if folded.range(of: #"^[A-Za-z0-9']+$"#, options: .regularExpression) != nil {
                normalized.append(folded.lowercased())
                indices.append(index)
                lastWasSpace = false
            } else if !lastWasSpace {
                normalized.append(" ")
                indices.append(index)
                lastWasSpace = true
            }
            index = text.index(after: index)
        }
        if normalized.last == " " {
            normalized.removeLast()
            indices.removeLast()
        }
        return (normalized, indices)
    }

    private func reportSuccess(_ message: String) {
        statusMessage = message
        lastError = nil
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    private func reportFailure(_ error: Error, context: String? = nil) {
        let message: String
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            message = description
        } else {
            message = String(describing: error)
        }
        reportFailure([context, message].compactMap { $0 }.joined(separator: ": "))
    }

    private func reportFailure(_ message: String) {
        statusMessage = "Error"
        lastError = message
        diagnostics["recentFailure"] = message
    }

    private func refreshSelectedItem() {
        guard let store, !activeItemId.isEmpty else { return }
        if let detail = try? loadItemDetail(id: activeItemId, store: store) {
            selectedItem = detail
        }
    }

    private func loadItemDetail(id: String, store: SQLiteSessionStore) throws -> ItemDetailState {
        let item = try store.loadItem(id: id)
        let map = try store.loadListeningMap(itemId: id)
        let sessions = try store.loadSessions(itemId: id)
        let activeSessionId = snapshot.sessionId ?? sessions.first?.id
        let interjections = activeSessionId.flatMap { try? store.loadInterjections(sessionId: $0).filter { $0.status == "active" } } ?? []
        let turns = activeSessionId.flatMap { try? store.loadTurns(sessionId: $0) } ?? []
        return ItemDetailState(
            id: item.id,
            title: item.title,
            status: item.status,
            text: item.text ?? "",
            externalReference: item.externalReference ?? "",
            overview: map?.overview ?? "",
            chapters: map?.chapters ?? [],
            sessions: sessions,
            interjections: interjections,
            turns: turns
        )
    }

    private func requireStore() throws -> SQLiteSessionStore {
        if let store { return store }
        let store = try SQLiteSessionStore(path: databaseURL().path)
        self.store = store
        return store
    }

    private func databaseURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: "SpokenMarginsGate1.sqlite")
    }

    private func loadFixtureItem(name: String) throws -> Item {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures/items") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.item(at: url)
    }

    private func loadFixtureMap(name: String) throws -> ListeningMap {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures/maps") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.listeningMap(at: url)
    }

    private func loadProfile(id: String) throws -> RuntimeCapabilityProfile {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "fixtures/capabilities") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.profile(at: url)
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

private enum ProviderCallError: Error, CustomStringConvertible {
    case http(Int, String)
    case emptyResponse
    case invalidURL
    case missingAPIKey

    var description: String {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(body.prefix(240))"
        case .emptyResponse:
            return "empty_response"
        case .invalidURL:
            return "provider_url_invalid"
        case .missingAPIKey:
            return "provider_api_key_missing"
        }
    }
}

private enum ManualListeningMapError: Error, CustomStringConvertible {
    case empty
    case invalidUTF8
    case rootMustBeObject
    case invalidSchema
    case missingOverview
    case missingChapters
    case itemHasNoText
    case missingChapterId
    case duplicateChapterId(String)
    case missingChapterTitle(String)
    case missingChapterDescription(String)
    case missingChapterAnchor(String)
    case anchorNotFound(String)
    case invalidChapterRange(String)
    case jsonParseFailed(String)

    var description: String {
        switch self {
        case .empty:
            return "manual_map_empty"
        case .invalidUTF8:
            return "manual_map_invalid_utf8"
        case .rootMustBeObject:
            return "manual_map_root_must_be_object"
        case .invalidSchema:
            return "manual_map_schemaVersion_must_be_listening-map.v1"
        case .missingOverview:
            return "manual_map_missing_overview"
        case .missingChapters:
            return "manual_map_missing_chapters"
        case .itemHasNoText:
            return "manual_map_item_has_no_text"
        case .missingChapterId:
            return "manual_map_missing_chapter_id"
        case .duplicateChapterId(let id):
            return "manual_map_duplicate_chapter_id:\(id)"
        case .missingChapterTitle(let id):
            return "manual_map_missing_chapter_title:\(id)"
        case .missingChapterDescription(let id):
            return "manual_map_missing_chapter_description:\(id)"
        case .missingChapterAnchor(let id):
            return "manual_map_missing_chapter_anchor:\(id)"
        case .anchorNotFound(let id):
            return "manual_map_anchor_not_found:\(id)"
        case .invalidChapterRange(let id):
            return "manual_map_invalid_chapter_range:\(id)"
        case .jsonParseFailed(let error):
            return "manual_map_json_parse_failed:\(error)"
        }
    }
}

#if KOKORO_DEVICE && !targetEnvironment(simulator) && canImport(AVFoundation)
private final class KokoroSpeechPlaybackClient: NSObject, AudioPlaybackClient, AVAudioPlayerDelegate, @unchecked Sendable {
    private let fallback = SystemSpeechPlaybackClient()
    private let applicationSupportDirectory: URL
    private let outputDirectory: URL
    private let voiceName: String
    private let speed: Float
    private let cacheLimitBytes: Int
    private let maxCharacters: Int
    private let renderQueue = DispatchQueue(label: "spoken-margins.kokoro.playback", qos: .userInitiated)
    private let lock = NSLock()

    private var preparedSourceText = ""
    private var player: AVAudioPlayer?
    private var generation = UUID()
    private var currentTargetId: String?
    private var currentStartOffset = 0
    private var currentChunkLength = 0
    private var currentChunkBoundary = KokoroChunkBoundary.hard
    private var fallbackIsActive = false
    private var completedTargetId: String?
    private var playbackComplete = false
    private var renderedCache: [Int: URL] = [:]
    private var inFlightOffsets = Set<Int>()
    private var pendingAutoplayOffset: Int?
    private var appIsActive = true
    #if canImport(UIKit)
    private var activityObservers: [NSObjectProtocol] = []
    #endif

    init(
        applicationSupportDirectory: URL,
        outputDirectory: URL,
        voiceName: String,
        speed: Float,
        cacheLimitBytes: Int,
        maxCharacters: Int = 360
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.outputDirectory = outputDirectory
        self.voiceName = voiceName
        self.speed = max(0.65, min(1.75, speed))
        self.cacheLimitBytes = cacheLimitBytes
        self.maxCharacters = maxCharacters
        super.init()
        configureAppActivityObservers()
    }

    deinit {
        #if canImport(UIKit)
        for observer in activityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    func prepareSpeechText(_ text: String) throws -> String {
        lock.lock()
        preparedSourceText = text
        lock.unlock()
        return try fallback.prepareSpeechText(text)
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        guard let request = nextRequest(targetId: targetId, from: charOffset) else {
            try fallback.play(targetId: targetId, from: charOffset)
            return
        }
        enqueueRender(request)
    }

    func currentCharOffset() -> Int? {
        lock.lock()
        let isFallbackActive = fallbackIsActive
        lock.unlock()
        if isFallbackActive {
            return fallback.currentCharOffset()
        }
        lock.lock()
        let start = currentStartOffset
        let length = currentChunkLength
        let localPlayer = player
        lock.unlock()
        guard let localPlayer, localPlayer.duration > 0, length > 0 else {
            return start
        }
        let fraction = max(0, min(1, localPlayer.currentTime / localPlayer.duration))
        return start + Int((Double(length) * fraction).rounded(.down))
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        lock.lock()
        let isFallbackActive = fallbackIsActive
        let isComplete = playbackComplete && completedTargetId == targetId
        lock.unlock()
        if isFallbackActive {
            return fallback.isPlaybackComplete(targetId: targetId)
        }
        return isComplete
    }

    func pause() throws {
        player?.pause()
        try fallback.pause()
    }

    func stop() throws {
        lock.lock()
        generation = UUID()
        player?.stop()
        player = nil
        fallbackIsActive = false
        renderedCache.removeAll()
        inFlightOffsets.removeAll()
        pendingAutoplayOffset = nil
        completedTargetId = nil
        playbackComplete = false
        lock.unlock()
        try fallback.stop()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        lock.lock()
        let nextOffset = currentStartOffset + max(1, currentChunkLength)
        let targetId = currentTargetId
        let sourceCount = preparedSourceText.count
        let cachedURL = renderedCache.removeValue(forKey: nextOffset)
        let transitionDelay = currentChunkBoundary.transitionDelay
        let requestId = generation
        lock.unlock()
        guard let targetId,
              nextOffset < sourceCount,
              let request = renderRequest(targetId: targetId, startOffset: nextOffset, id: requestId) else {
            lock.lock()
            currentStartOffset = sourceCount
            currentChunkLength = 0
            completedTargetId = targetId
            playbackComplete = true
            lock.unlock()
            return
        }
        if let cachedURL {
            playRenderedAudio(cachedURL, request: request, delay: transitionDelay)
        } else {
            lock.lock()
            pendingAutoplayOffset = nextOffset
            lock.unlock()
            enqueueRender(request, shouldPlayWhenReady: false)
        }
    }

    private struct RenderRequest: Sendable {
        var id: UUID
        var targetId: String
        var startOffset: Int
        var sourceLength: Int
        var text: String
        var boundary: KokoroChunkBoundary
    }

    private func nextRequest(targetId: String, from charOffset: Int) -> RenderRequest? {
        lock.lock()
        let source = preparedSourceText
        generation = UUID()
        let requestId = generation
        player?.stop()
        player = nil
        fallbackIsActive = false
        renderedCache.removeAll()
        inFlightOffsets.removeAll()
        pendingAutoplayOffset = nil
        completedTargetId = nil
        playbackComplete = false
        currentTargetId = targetId
        lock.unlock()

        return renderRequest(targetId: targetId, startOffset: charOffset, id: requestId, source: source)
    }

    private func renderRequest(targetId: String, startOffset: Int, id: UUID, source: String? = nil) -> RenderRequest? {
        let source = source ?? currentPreparedSourceText()
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let clampedOffset = max(0, min(startOffset, source.count))
        guard clampedOffset < source.count else { return nil }
        let slice = kokoroSourceSlice(from: source, startOffset: clampedOffset, maxCharacters: maxCharacters)
        guard !slice.text.isEmpty, slice.sourceLength > 0 else { return nil }
        return RenderRequest(
            id: id,
            targetId: targetId,
            startOffset: clampedOffset,
            sourceLength: slice.sourceLength,
            text: slice.text,
            boundary: slice.boundary
        )
    }

    private func currentPreparedSourceText() -> String {
        lock.lock()
        let source = preparedSourceText
        lock.unlock()
        return source
    }

    private func enqueueRender(_ request: RenderRequest, shouldPlayWhenReady: Bool = true) {
        guard canSubmitKokoroRender() else {
            playFallback(targetId: request.targetId, from: request.startOffset, requestId: request.id)
            return
        }
        lock.lock()
        if renderedCache[request.startOffset] != nil || inFlightOffsets.contains(request.startOffset) {
            if !shouldPlayWhenReady {
                lock.unlock()
                return
            }
        }
        inFlightOffsets.insert(request.startOffset)
        lock.unlock()

        renderQueue.async { [weak self, applicationSupportDirectory, outputDirectory, voiceName, speed, cacheLimitBytes] in
            guard let self else { return }
            guard self.canSubmitKokoroRender() else {
                DispatchQueue.main.async {
                    self.renderFailed(request: request)
                    self.playFallback(targetId: request.targetId, from: request.startOffset, requestId: request.id)
                }
                return
            }
            do {
                let assets = KokoroNarrationRenderer.installedAssets(applicationSupportDirectory: applicationSupportDirectory)
                guard let modelURL = assets.modelURL else { throw KokoroNarrationError.missingModel }
                guard let voicesURL = assets.voicesURL else { throw KokoroNarrationError.missingVoices }
                let configured = KokoroNarrationRenderer.configureMemoryForDiagnostics(cacheLimitBytes: cacheLimitBytes)
                let before = KokoroNarrationRenderer.memorySnapshot()
                let preview = request.text
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .prefix(120)
                NSLog(
                    "SpokenMargins Kokoro render start target=%@ offset=%d chars=%d boundary=%@ configured=%@ before=%@ text=\"%@\"",
                    request.targetId,
                    request.startOffset,
                    request.sourceLength,
                    request.boundary.rawValue,
                    configured.description,
                    before.description,
                    String(preview)
                )
                let renderer = try KokoroNarrationRenderer(
                    modelURL: modelURL,
                    voicesURL: voicesURL,
                    outputDirectory: outputDirectory
                )
                guard self.canSubmitKokoroRender() else {
                    DispatchQueue.main.async {
                        self.renderFailed(request: request)
                        self.playFallback(targetId: request.targetId, from: request.startOffset, requestId: request.id)
                    }
                    return
                }
                let renderSpeed = Self.currentKokoroSpeed(defaultSpeed: speed)
                let result = try renderer.render(
                    text: request.text,
                    itemId: request.targetId,
                    chunkId: "offset-\(request.startOffset)",
                    voiceName: voiceName,
                    speed: renderSpeed
                )
                let after = KokoroNarrationRenderer.memorySnapshot()
                let final = KokoroNarrationRenderer.clearMemoryCache()
                NSLog(
                    "SpokenMargins Kokoro render finish target=%@ offset=%d duration=%.2f tokens=%d speed=%.2f after=%@ final=%@",
                    request.targetId,
                    request.startOffset,
                    result.duration,
                    result.tokenCount,
                    renderSpeed,
                    after.description,
                    final.description
                )
                DispatchQueue.main.async {
                    self.renderCompleted(audioURL: result.audioURL, request: request, shouldPlayWhenReady: shouldPlayWhenReady)
                }
            } catch {
                let final = KokoroNarrationRenderer.clearMemoryCache()
                NSLog(
                    "SpokenMargins Kokoro render failed target=%@ offset=%d error=%@ final=%@",
                    request.targetId,
                    request.startOffset,
                    error.localizedDescription,
                    final.description
                )
                DispatchQueue.main.async {
                    self.renderFailed(request: request)
                    self.playFallback(targetId: request.targetId, from: request.startOffset, requestId: request.id)
                }
            }
        }
    }

    private func renderCompleted(audioURL: URL, request: RenderRequest, shouldPlayWhenReady: Bool) {
        lock.lock()
        inFlightOffsets.remove(request.startOffset)
        guard generation == request.id else {
            lock.unlock()
            return
        }
        let shouldAutoplay = shouldPlayWhenReady || pendingAutoplayOffset == request.startOffset
        if shouldAutoplay {
            pendingAutoplayOffset = nil
        } else {
            renderedCache[request.startOffset] = audioURL
        }
        lock.unlock()

        if shouldAutoplay {
            playRenderedAudio(audioURL, request: request)
        }
    }

    private func renderFailed(request: RenderRequest) {
        lock.lock()
        inFlightOffsets.remove(request.startOffset)
        if pendingAutoplayOffset == request.startOffset {
            pendingAutoplayOffset = nil
        }
        lock.unlock()
    }

    private func playRenderedAudio(_ audioURL: URL, request: RenderRequest, delay: TimeInterval = 0) {
        lock.lock()
        guard generation == request.id else {
            lock.unlock()
            return
        }
        lock.unlock()
        do {
            try fallback.stop()
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let nextPlayer = try AVAudioPlayer(contentsOf: audioURL)
            nextPlayer.delegate = self
            nextPlayer.prepareToPlay()
            lock.lock()
            player = nextPlayer
            currentTargetId = request.targetId
            currentStartOffset = request.startOffset
            currentChunkLength = request.sourceLength
            currentChunkBoundary = request.boundary
            fallbackIsActive = false
            lock.unlock()
            if delay > 0 {
                nextPlayer.play(atTime: nextPlayer.deviceCurrentTime + delay)
            } else {
                nextPlayer.play()
            }
            prefetchNextChunk(after: request)
        } catch {
            playFallback(targetId: request.targetId, from: request.startOffset, requestId: request.id)
        }
    }

    private func prefetchNextChunk(after request: RenderRequest) {
        let nextOffset = request.startOffset + max(1, request.sourceLength)
        lock.lock()
        let sourceCount = preparedSourceText.count
        let targetId = currentTargetId
        let currentGeneration = generation
        lock.unlock()
        guard currentGeneration == request.id,
              let targetId,
              nextOffset < sourceCount,
              let nextRequest = renderRequest(targetId: targetId, startOffset: nextOffset, id: currentGeneration) else {
            return
        }
        enqueueRender(nextRequest, shouldPlayWhenReady: false)
    }

    private func configureAppActivityObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        activityObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setAppIsActive(true)
        })
        activityObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setAppIsActive(false)
        })
        activityObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setAppIsActive(false)
        })
        #endif
    }

    private func setAppIsActive(_ isActive: Bool) {
        lock.lock()
        appIsActive = isActive
        if !isActive {
            renderedCache.removeAll()
            inFlightOffsets.removeAll()
            pendingAutoplayOffset = nil
        }
        lock.unlock()
    }

    private func canSubmitKokoroRender() -> Bool {
        lock.lock()
        let isActive = appIsActive
        lock.unlock()
        return isActive
    }

    private static func currentKokoroSpeed(defaultSpeed: Float) -> Float {
        let storedRate = UserDefaults.standard.double(forKey: "speechRate")
        guard storedRate > 0 else { return defaultSpeed }
        return Float(max(0.65, min(1.75, storedRate / 0.5)))
    }

    private func playFallback(targetId: String, from charOffset: Int, requestId: UUID? = nil) {
        do {
            lock.lock()
            if let requestId, generation != requestId {
                lock.unlock()
                return
            }
            fallbackIsActive = true
            playbackComplete = false
            completedTargetId = nil
            currentStartOffset = charOffset
            currentChunkLength = 0
            lock.unlock()
            try fallback.play(targetId: targetId, from: charOffset)
        } catch {
            lock.lock()
            fallbackIsActive = false
            lock.unlock()
        }
    }
}
#endif

private enum KokoroChunkBoundary: String, Sendable {
    case sentence
    case comma
    case whitespace
    case hard

    var transitionDelay: TimeInterval {
        switch self {
        case .sentence:
            return 0.12
        case .comma:
            return 0.05
        case .whitespace, .hard:
            return 0
        }
    }
}

private struct KokoroSourceSlice: Sendable {
    var text: String
    var sourceLength: Int
    var boundary: KokoroChunkBoundary
}

private func kokoroRenderChunk(from text: String, maxCharacters: Int = 360) -> String {
    let trimmed = SpeechTextNormalizer.normalize(text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxCharacters else { return trimmed }

    let hardLimit = trimmed.index(trimmed.startIndex, offsetBy: maxCharacters)
    let prefix = String(trimmed[..<hardLimit])
    return kokoroSelectChunkPrefix(prefix, maxCharacters: maxCharacters).text
}

private func kokoroSourceSlice(from source: String, startOffset: Int, maxCharacters: Int) -> KokoroSourceSlice {
    let clampedOffset = max(0, min(startOffset, source.count))
    let start = source.index(source.startIndex, offsetBy: clampedOffset)
    let remainingLength = source.distance(from: start, to: source.endIndex)
    let length = min(maxCharacters, remainingLength)
    let hardEnd = source.index(start, offsetBy: length)
    let prefix = String(source[start..<hardEnd])
    let selected = kokoroSelectChunkPrefix(prefix, maxCharacters: maxCharacters)
    return KokoroSourceSlice(
        text: selected.text,
        sourceLength: max(0, selected.sourceLength),
        boundary: selected.boundary
    )
}

private func kokoroSelectChunkPrefix(_ prefix: String, maxCharacters: Int) -> KokoroSourceSlice {
    let minimumUsefulLength = min(80, max(24, maxCharacters / 3))
    let sentenceCharacters = CharacterSet(charactersIn: ".!?\n;:")
    if let sentence = kokoroBoundary(in: prefix, characters: sentenceCharacters, includeBoundary: true, minimumUsefulLength: minimumUsefulLength) {
        return sentence.withBoundary(.sentence)
    }

    if let comma = kokoroBoundary(in: prefix, characters: CharacterSet(charactersIn: ","), includeBoundary: true, minimumUsefulLength: minimumUsefulLength) {
        return comma.withBoundary(.comma)
    }

    if let whitespace = kokoroBoundary(in: prefix, characters: .whitespacesAndNewlines, includeBoundary: false, minimumUsefulLength: minimumUsefulLength) {
        return whitespace.withBoundary(.whitespace)
    }

    let normalized = SpeechTextNormalizer.normalize(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
    return KokoroSourceSlice(text: normalized, sourceLength: prefix.count, boundary: .hard)
}

private func kokoroBoundary(in prefix: String, characters: CharacterSet, includeBoundary: Bool, minimumUsefulLength: Int) -> KokoroSourceSlice? {
    guard let range = prefix.rangeOfCharacter(from: characters, options: .backwards) else { return nil }
    let end = includeBoundary ? range.upperBound : range.lowerBound
    guard prefix.distance(from: prefix.startIndex, to: end) >= minimumUsefulLength else { return nil }
    let selected = String(prefix[..<end])
    let normalized = SpeechTextNormalizer.normalize(selected).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    let sourceLength = prefix.distance(from: prefix.startIndex, to: range.upperBound)
    return KokoroSourceSlice(text: normalized, sourceLength: sourceLength, boundary: .hard)
}

private extension KokoroSourceSlice {
    func withBoundary(_ boundary: KokoroChunkBoundary) -> KokoroSourceSlice {
        KokoroSourceSlice(text: text, sourceLength: sourceLength, boundary: boundary)
    }
}

#if targetEnvironment(simulator)
private final class FakeGeneratedSpeechPlaybackClient: AudioPlaybackClient, @unchecked Sendable {
    private let lock = NSLock()
    private var preparedText = ""
    private var currentOffsetValue = 0
    private var completedTargetId: String?
    private var playingTargetId: String?

    func prepareSpeechText(_ text: String) throws -> String {
        let normalized = SpeechTextNormalizer.normalize(text)
        lock.lock()
        preparedText = normalized
        lock.unlock()
        return normalized
    }

    func play(targetId: String) throws {
        try play(targetId: targetId, from: 0)
    }

    func play(targetId: String, from charOffset: Int) throws {
        lock.lock()
        playingTargetId = targetId
        completedTargetId = nil
        currentOffsetValue = max(0, min(charOffset, preparedText.count))
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.playingTargetId == targetId {
                self.currentOffsetValue = self.preparedText.count
                self.completedTargetId = targetId
            }
            self.lock.unlock()
        }
    }

    func currentCharOffset() -> Int? {
        lock.lock()
        let offset = currentOffsetValue
        lock.unlock()
        return offset
    }

    func isPlaybackComplete(targetId: String) -> Bool {
        lock.lock()
        let complete = completedTargetId == targetId
        lock.unlock()
        return complete
    }

    func pause() throws {
        lock.lock()
        playingTargetId = nil
        lock.unlock()
    }

    func stop() throws {
        lock.lock()
        playingTargetId = nil
        completedTargetId = nil
        lock.unlock()
    }
}
#endif

#if canImport(AVFoundation)
private func voiceQualityName(_ voice: AVSpeechSynthesisVoice) -> String {
    if #available(iOS 16.0, macOS 13.0, watchOS 9.0, *) {
        switch voice.quality {
        case .default: return "Default"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }
    return "Default"
}
#endif

enum KeychainStore {
    static func save(_ value: String, service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard let data = value.data(using: .utf8), !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
