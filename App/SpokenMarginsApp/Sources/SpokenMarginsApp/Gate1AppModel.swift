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
    @Published var providerBaseURL = UserDefaults.standard.string(forKey: "providerBaseURL") ?? "https://api.openai.com/v1"
    @Published var providerModel = UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-4.1-mini"
    @Published var providerAPIKey = KeychainStore.load(service: "SpokenMargins", account: "OpenAICompatibleAPIKey") ?? ""
    @Published var providerProbeStatus = "Not checked"
    @Published var knownIssues = [
        "Gate 1 simulator app builds; signed device installation still requires local team/provisioning configuration.",
        "System recording adapter is still a boundary stub; real microphone capture needs the next device pass."
    ]

    private var engine: SessionEngine?
    private var store: SQLiteSessionStore?
    private var activeItemId = "item-pill"
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

    func openHome() {
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
        run { engine in
            snapshot = try engine.beginInterjection()
            refreshSelectedItem()
            reportSuccess("Recording interjection.")
        }
    }

    func finishInterjection() {
        run { engine in
            snapshot = try engine.finishInterjection(audioRef: "interjections/device-\(Date().timeIntervalSince1970).m4a")
            refreshSelectedItem()
            reportSuccess("Saved interjection.")
        }
    }

    func summarize() {
        run { engine in
            snapshot = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item"))
            submitProviderJobIfNeeded(kind: "interjection_summary", turnId: "turn-summary-001", messages: [summaryPrompt()])
            refreshSelectedItem()
            reportSuccess(snapshot.pendingAiJobStatus == "deferred" ? "Summary queued for later." : "Summary job started.")
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
            let messages = job.messages.isEmpty ? [job.kind == "interjection_summary" ? summaryPrompt() : "Continue the discussion."] : job.messages
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
        screen = .settings
        reportSuccess("Provider settings saved.")
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

    private func summaryPrompt() -> String {
        guard let sessionId = snapshot.sessionId,
              let interjections = try? store?.loadInterjections(sessionId: sessionId),
              !interjections.isEmpty else {
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
        let interjections = activeSessionId.flatMap { try? store.loadInterjections(sessionId: $0) } ?? []
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
