import Foundation
import Security
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitPersistence

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

@MainActor
final class Gate1AppModel: ObservableObject {
    @Published var screen: Gate1Screen = .home
    @Published var snapshot = SessionSnapshot()
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
    @Published var providerBaseURL = UserDefaults.standard.string(forKey: "providerBaseURL") ?? "https://api.openai.com/v1"
    @Published var providerModel = UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-4.1-mini"
    @Published var providerAPIKey = KeychainStore.load(service: "SpokenMargins", account: "OpenAICompatibleAPIKey") ?? ""
    @Published var providerProbeStatus = "Not checked"
    @Published var knownIssues = [
        "Gate 1 simulator app builds; signed device installation still requires local team/provisioning configuration.",
        "Now Playing metadata and remote command handling still need the next device pass."
    ]

    private var engine: SessionEngine?
    private var store: SQLiteSessionStore?
    private var activeItemId = "item-pill"
    private let transcriptionClient = SystemSpeechTranscriptionClient()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

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

    func start() {
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
        run { engine in
            snapshot = try engine.resumePlayback()
            refreshSelectedItem()
            reportSuccess("Resumed.")
        }
    }

    func generateListeningMap() {
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

    func deleteItem(id: String) {
        do {
            let store = try requireStore()
            guard id.hasPrefix("item-import-") else {
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
            snapshot = try engine.skipBack(unit: "sentence")
            refreshSelectedItem()
            reportSuccess("Skipped back.")
        }
    }

    func skipForward() {
        run { engine in
            snapshot = try engine.skipForward(unit: "sentence")
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
        run { engine in
            snapshot = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item"))
            submitProviderJobIfNeeded(kind: "interjection_summary", turnId: "turn-summary-001", messages: [summaryPrompt(interjections: engine.lastSummaryCandidates)])
            refreshSelectedItem()
            reportSuccess(snapshot.pendingAiJobStatus == "deferred" ? "Summary queued for later." : "Summary job started.")
        }
    }

    func discuss() {
        if let turn = selectedItem.turns.last(where: { $0.role == "assistant" && $0.status == "complete" && (($0.text?.isEmpty == false) || ($0.summary?.isEmpty == false)) }) {
            playTurn(turn)
        } else {
            summarize()
        }
    }

    func playTurn(_ turn: ConversationTurn) {
        run { engine in
            snapshot = try engine.playTurn(turnId: turn.id)
            refreshSelectedItem()
            screen = .playback
            reportSuccess("Playing \(turnTitleText(turn)).")
        }
    }

    func followUp(_ text: String) {
        run { engine in
            snapshot = try engine.submitFollowup(text: text)
            submitProviderJobIfNeeded(kind: "assistant_response", turnId: "turn-response-001", messages: [text])
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
            let export = try engine.buildExport(options: ExportOptions(includeFullText: false, includeReference: true, includeListeningMap: false, includeInterjections: true))
            let data = try encoder.encode(export)
            exportPreview = String(data: data, encoding: .utf8) ?? ""
            screen = .export
            reportSuccess("Built session export.")
        }
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
            reportSuccess("Diagnostics refreshed.")
        }
    }

    func saveProviderSettings() {
        UserDefaults.standard.set(providerBaseURL, forKey: "providerBaseURL")
        UserDefaults.standard.set(providerModel, forKey: "providerModel")
        KeychainStore.save(providerAPIKey, service: "SpokenMargins", account: "OpenAICompatibleAPIKey")
        diagnostics["providerBaseURL"] = providerBaseURL
        diagnostics["providerModel"] = providerModel
        diagnostics["apiKeyConfigured"] = providerAPIKey.isEmpty ? "false" : "true"
        if rebuildEngineForCurrentSettings() {
            screen = .settings
            reportSuccess("Provider settings saved.")
        }
    }

    func runtimeProfileChanged() {
        diagnostics["runtimeProfile"] = selectedProfileId
        if rebuildEngineForCurrentSettings() {
            reportSuccess("Runtime profile set to \(selectedProfileId).")
        }
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

    var currentChapter: Chapter? {
        selectedItem.chapters.last { $0.percent <= snapshot.progressPercent } ?? selectedItem.chapters.first
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
            provider = OpenAICompatibleProvider(baseURL: url, model: providerModel, apiKeyReference: providerAPIKey.isEmpty ? nil : "keychain:SpokenMargins/OpenAICompatibleAPIKey")
        } else {
            provider = FixtureAIProvider()
        }
        return SessionEngine(
            profile: profile,
            repository: store,
            audio: SystemSpeechPlaybackClient(),
            recorder: SystemRecordingClient(),
            aiProvider: provider
        )
    }

    private func loadLibraryRows(store: SQLiteSessionStore) throws -> [LibraryItemRow] {
        try store.listItems().map { item in
            LibraryItemRow(
                id: item.id,
                title: item.title,
                status: item.status,
                canDelete: item.id.hasPrefix("item-import-")
            )
        }
    }

    private func submitProviderJobIfNeeded(kind: String, turnId: String, messages: [String], force: Bool = false) {
        guard force || snapshot.pendingAiJobStatus == "pending" else { return }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            markProviderFailure("provider_api_key_missing", userMessage: "AI provider API key required.")
            screen = .settings
            return
        }
        guard let request = makeChatCompletionsRequest(messages: messages) else {
            markProviderFailure("provider_url_invalid", userMessage: "AI provider URL is invalid.")
            screen = .settings
            return
        }
        statusMessage = "Calling provider for \(kind)."
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
                        snapshot = try engine.aiStreamDelta(turnId: turnId, content: text)
                        snapshot = try engine.aiJobCompleted(turnId: turnId)
                        refreshSelectedItem()
                        reportSuccess("Provider response saved.")
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

    private func makeChatCompletionsRequest(messages: [String]) -> URLRequest? {
        let trimmed = providerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(providerAPIKey)", forHTTPHeaderField: "Authorization")
        let payload = ChatCompletionRequest(
            model: providerModel,
            messages: [ChatMessage(role: "system", content: "You are the Spoken Margins Gate 1 assistant. Preserve user source meaning, answer concisely, and make failures explicit.")] +
                messages.map { ChatMessage(role: "user", content: $0) },
            temperature: 0.2
        )
        request.httpBody = try? JSONEncoder().encode(payload)
        return request
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
        guard !interjections.isEmpty else {
            return "Summarize the current Spoken Margins interjections for the active item. If no transcript exists yet, say what can be inferred from the saved anchors and audio references."
        }
        let lines = interjections.map { interjection in
            [
                "id=\(interjection.id)",
                "target=\(interjection.targetType.rawValue):\(interjection.targetId)",
                "anchorBefore=\(interjection.anchor.anchorBefore)",
                "transcript=\(interjection.cleanedTranscript ?? interjection.transcript ?? "pending")",
                "audio=\(interjection.audioPath ?? "none")"
            ].joined(separator: "\n")
        }.joined(separator: "\n\n")
        return "Summarize these Spoken Margins interjections and identify follow-up questions:\n\n\(lines)"
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

    private func parseListeningMapJSON(_ raw: String, item: Item) throws -> ListeningMap {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ManualListeningMapError.empty
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ManualListeningMapError.invalidUTF8
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
        throw ManualListeningMapError.anchorNotFound(chapterId)
    }

    private func reportSuccess(_ message: String) {
        statusMessage = message
        lastError = nil
        diagnostics["lastStatus"] = message
        diagnostics["recentFailure"] = "none"
    }

    private func reportFailure(_ error: Error, context: String? = nil) {
        reportFailure([context, String(describing: error)].compactMap { $0 }.joined(separator: ": "))
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

    var description: String {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(body.prefix(240))"
        case .emptyResponse:
            return "empty_response"
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
        }
    }
}

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
