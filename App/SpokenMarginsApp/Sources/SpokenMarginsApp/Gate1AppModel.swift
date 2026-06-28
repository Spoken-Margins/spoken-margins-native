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

struct PiperVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let modelURL: URL
    let configURL: URL?

    var displayName: String {
        language.isEmpty ? name : "\(name) · \(language)"
    }
}

struct QuickAccessFile: Identifiable, Hashable {
    let id: String
    let name: String
    let relativePath: String
    let modifiedAtDescription: String
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
            if isMediaPlaybackSnapshot {
                mediaPlaybackRate = snapshot.playbackRate
            }
            preparedTextAudioStatus = snapshot.preparedTextAudioStatus ?? preparedTextAudioStatus
            if let snapshotSourceTranscriptStatus = snapshot.sourceTranscriptStatus,
               !(sourceTranscriptStatus == "transcribing" && snapshotSourceTranscriptStatus == "not_started") {
                sourceTranscriptStatus = snapshotSourceTranscriptStatus
            }
            reconcilePlaybackProgressTicker()
            updateGate2CompactState()
            updateGate3WatchState()
        }
    }
    @Published var gate2CompactSnapshot: CompactControlSnapshot?
    @Published var diagnostics: [String: String] = [:]
    @Published var statusMessage = "Ready."
    @Published var lastError: String?
    @Published var exportPreview = ""
    @Published var exportFormat = UserDefaults.standard.string(forKey: "exportFormat") ?? "markdown"
    @Published var exportScope = UserDefaults.standard.string(forKey: "exportScope") ?? "full_session"
    @Published var exportIncludesSourceText = UserDefaults.standard.object(forKey: "exportIncludesSourceText") as? Bool ?? true
    @Published var exportIncludesReference = UserDefaults.standard.object(forKey: "exportIncludesReference") as? Bool ?? true
    @Published var exportIncludesListeningMap = UserDefaults.standard.object(forKey: "exportIncludesListeningMap") as? Bool ?? true
    @Published var exportIncludesInterjections = UserDefaults.standard.object(forKey: "exportIncludesInterjections") as? Bool ?? true
    @Published var exportIncludesTurns = UserDefaults.standard.object(forKey: "exportIncludesTurns") as? Bool ?? true
    @Published var libraryItems: [LibraryItemRow] = []
    @Published var selectedItem = ItemDetailState()
    @Published var pastedAssistantResponse = ""
    @Published var quickAccessFolderName = UserDefaults.standard.string(forKey: "quickAccessFolderName") ?? "No folder selected"
    @Published var quickAccessRecentFiles: [QuickAccessFile] = []
    @Published var selectedProfileId = "phone-tablet-online"
    @Published var importTitle = "Gate 1 Article With Links"
    @Published var importText = "Read the background at https://example.com/long/url before continuing. A labeled [reference](https://example.com/essay) should stay readable while raw URLs are skipped."
    @Published var sourceLinkURL = ""
    @Published var isResolvingSourceLink = false
    @Published var listeningMapJSON = ""
    @Published var isGeneratingListeningMap = false
    @Published var providerBaseURL = UserDefaults.standard.string(forKey: "providerBaseURL") ?? "https://api.openai.com/v1"
    @Published var listeningMapModel = UserDefaults.standard.string(forKey: "listeningMapModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-4.1-mini"
    @Published var summaryModel = UserDefaults.standard.string(forKey: "summaryModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-4.1-mini"
    @Published var conversationModel = UserDefaults.standard.string(forKey: "conversationModel") ?? UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-4.1-mini"
    @Published var skipUnit = UserDefaults.standard.string(forKey: "skipUnit") ?? "paragraph"
    @Published var speechRate = UserDefaults.standard.double(forKey: "speechRate") == 0 ? 0.5 : UserDefaults.standard.double(forKey: "speechRate")
    @Published var mediaPlaybackRate = UserDefaults.standard.double(forKey: "mediaPlaybackRate") == 0 ? 1.0 : UserDefaults.standard.double(forKey: "mediaPlaybackRate")
    @Published var preparedTextAudioStatus = "Not started"
    @Published var sourceTranscriptStatus = "Not started"
    @Published var pendingPreparedTextStartItemId: String?
    @Published var speechVoiceOptions: [SpeechVoiceChoice] = []
    @Published var speechVoiceIdentifier = UserDefaults.standard.string(forKey: "speechVoiceIdentifier") ?? ""
    @Published var ttsMode = UserDefaults.standard.string(forKey: "ttsMode") ?? "systemImmediate"
    @Published var kokoroVoiceName = UserDefaults.standard.string(forKey: "kokoroVoiceName") ?? "am_echo"
    @Published var kokoroChunkCharacters = min(140, max(80, UserDefaults.standard.double(forKey: "kokoroChunkCharacters") == 0 ? 110 : UserDefaults.standard.double(forKey: "kokoroChunkCharacters")))
    @Published var kokoroStatus = "Not checked"
    @Published var piperVoiceId = UserDefaults.standard.string(forKey: "piperVoiceId") ?? ""
    @Published var piperVoiceOptions: [PiperVoiceOption] = []
    @Published var piperStatus = "Not checked"
    @Published var isRenderingKokoroPreview = false
    @Published var isRunningKokoroMemoryCheck = false
    @Published var isRenderingWatchPackage = false
    @Published var watchPackageRenderStatus = "Not rendered"
    @Published var providerAPIKey = KeychainStore.load(service: "SpokenMargins", account: "OpenAICompatibleAPIKey") ?? ""
    @Published var providerProbeStatus = "Not checked"
    @Published var knownIssues = [
        "Gate 1 simulator app builds; signed device installation still requires local team/provisioning configuration.",
        "Gate 2 Now Playing and Live Activity controls require signed real-device validation.",
        "Source link, public podcast, and share-extension intake are experimental until they have their own human validation record."
    ]

    private var engine: SessionEngine?
    private var store: SQLiteSessionStore?
    private let gate2CompactControls = Gate2CompactControlController()
    private let gate3WatchConnectivity = Gate3WatchConnectivityController()
    private let sourceLinkResolver: LinkResolutionClient?
    private let sourceLinkHandoffStore: SourceLinkHandoffStore?
    private let audioPlaybackClientOverride: AudioPlaybackClient?
    private let forcePreparedTextGate: Bool
    private let sourceTranscriptionClient: SourceTranscriptionClient
    private var gate3WatchDispatcher: CompactControlDispatcher?
    private var activeItemId = "item-pill"
    private var providerModel = UserDefaults.standard.string(forKey: "providerModel") ?? "gpt-4.1-mini"
    private var playbackProgressTask: Task<Void, Never>?
    private var textAudioPrewarmTasks: [String: Task<Void, Never>] = [:]
    private var liveSpeechFallbackItemIds: Set<String> = []
    private var isImportingPendingSourceLinkHandoffs = false
    private var pendingAutoPlayQueue = Gate1PlaybackAutoplayQueue()
    private var activeWatchPackageRenderItemIds: Set<String> = []
    private var failedWatchPackageRenderItemIds: Set<String> = []
    private let preparedTextAudioStarterDurationMs = 30_000
    private let transcriptionClient = SystemSpeechTranscriptionClient()
    private let quickAccessFolderBookmarkKey = "quickAccessFolderBookmark"
    #if canImport(AVFoundation)
    private let speechPreviewSynthesizer = AVSpeechSynthesizer()
    private var kokoroPreviewPlayer: AVAudioPlayer?
    #endif
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

    init(
        sourceLinkResolver: LinkResolutionClient? = nil,
        sourceLinkHandoffStore: SourceLinkHandoffStore? = nil,
        audioPlaybackClient: AudioPlaybackClient? = nil,
        forcePreparedTextGate: Bool = false,
        sourceTranscriptionClient: SourceTranscriptionClient = SystemSourceTranscriptionClient()
    ) {
        self.sourceLinkResolver = sourceLinkResolver
        self.sourceLinkHandoffStore = sourceLinkHandoffStore
        self.audioPlaybackClientOverride = audioPlaybackClient
        self.forcePreparedTextGate = forcePreparedTextGate
        self.sourceTranscriptionClient = sourceTranscriptionClient
        refreshSpeechVoiceOptions()
        sanitizeTTSMode()
        refreshPiperVoiceStatus()
        settingsValueChanged()
        refreshQuickAccessFolder()
        gate3WatchConnectivity.activate { [weak self] in
            self?.gate3WatchSnapshot()
        } commandHandler: { [weak self] request in
            self?.dispatchGate3WatchCommand(request)
        } packageLibraryProvider: { [weak self] in
            self?.gate4WatchPackageLibraryRows() ?? []
        } packageProvider: { [weak self] packageId in
            try self?.gate4WatchPackage(packageId: packageId)
        } packageRequestHandler: { [weak self] request in
            self?.handleGate4WatchPackageRequest(request)
        } watchSyncEventHandler: { [weak self] event in
            self?.handleGate4WatchSyncEvent(event)
        }
    }

    deinit {
        playbackProgressTask?.cancel()
        textAudioPrewarmTasks.values.forEach { $0.cancel() }
    }

    private func reconcilePlaybackProgressTicker() {
        if snapshot.status.isPlaybackActive {
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
                    guard self.snapshot.status.isPlaybackActive else {
                        self.stopPlaybackProgressTicker()
                        return
                    }
                    guard let engine = self.engine else { return }
                    do {
                        let previousStatus = self.snapshot.status
                        let previousTargetId = self.snapshot.targetId
                        let updated = try engine.syncPlaybackProgress()
                        let completedCurrentAudio = previousStatus.isPlaybackActive &&
                            updated.status == .paused &&
                            previousTargetId == updated.targetId
                        if updated != self.snapshot {
                            self.snapshot = updated
                        }
                        self.playPendingTurnIfReady(completedCurrentAudio: completedCurrentAudio)
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
            try seedGate4WatchPackageFixture(store: store)
            self.store = store
            installEngine(try makeEngine(store: store))
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
            installEngine(try makeEngine(store: store))
            activeItemId = item.id
            scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: item.id, store: store)
            diagnostics["lastImport"] = item.id
            importTitle = ""
            importText = ""
            startItem(id: item.id)
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
            installEngine(try makeEngine(store: store))
            activeItemId = imported.first?.id ?? activeItemId
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: activeItemId, store: store)
            imported.forEach { scheduleTextAudioPrewarmIfNeeded(itemId: $0.id) }
            diagnostics["lastObsidianImportCount"] = "\(imported.count)"
            diagnostics["lastObsidianImportFailures"] = "\(failures.count)"
            screen = .home
            let suffix = failures.isEmpty ? "" : " \(failures.count) failed."
            reportSuccess("Imported \(imported.count) Obsidian file\(imported.count == 1 ? "" : "s").\(suffix)")
        } catch {
            reportFailure(error, context: "Obsidian import failed")
        }
    }

    @discardableResult
    func importSourceLinkFromForm() -> Bool {
        let success = importSourceLink(
            urlString: sourceLinkURL,
            sourceSurface: "paste",
            startSession: true
        )
        if success {
            sourceLinkURL = ""
        }
        return success
    }

    func beginSourceLinkImportFromForm() {
        guard !isResolvingSourceLink else { return }
        guard !sourceLinkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reportFailure("Paste or enter a podcast, RSS, or audio URL first.")
            return
        }
        isResolvingSourceLink = true
        statusMessage = "Resolving source link..."
        lastError = nil
        diagnostics["lastSourceLinkButtonTap"] = "registered"
        Task { @MainActor in
            await Task.yield()
            _ = await importSourceLinkAsync(
                urlString: sourceLinkURL,
                sourceSurface: "paste",
                startSession: true
            )
        }
    }

    func pasteSourceLinkFromClipboard() {
        #if canImport(UIKit)
        guard let clipboardText = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clipboardText.isEmpty else {
            reportFailure("Clipboard does not contain a URL.")
            return
        }
        let pasted = Self.firstURL(in: clipboardText)?.absoluteString ?? clipboardText
        sourceLinkURL = pasted
        reportSuccess("Pasted link from Clipboard.")
        diagnostics["lastSourceLinkClipboardPaste"] = pasted
        #else
        reportFailure("Clipboard paste is unavailable on this platform.")
        #endif
    }

    @discardableResult
    func importSourceLink(_ handoff: SourceLinkHandoff) -> Bool {
        importSourceLink(
            urlString: handoff.inputURL,
            sourceSurface: handoff.sourceSurface,
            startSession: handoff.startSession
        )
    }

    @discardableResult
    private func importSourceLinkAsync(_ handoff: SourceLinkHandoff) async -> Bool {
        await importSourceLinkAsync(
            urlString: handoff.inputURL,
            sourceSurface: handoff.sourceSurface,
            startSession: handoff.startSession
        )
    }

    @discardableResult
    private func importSourceLinkAsync(urlString: String, sourceSurface: String, startSession: Bool = true) async -> Bool {
        guard sourceLinkResolver == nil else {
            return importSourceLink(urlString: urlString, sourceSurface: sourceSurface, startSession: startSession)
        }
        isResolvingSourceLink = true
        statusMessage = "Resolving source link..."
        defer { isResolvingSourceLink = false }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            reportFailure("Enter a valid podcast, RSS, or audio URL.")
            return false
        }
        let request = LinkResolutionRequest(
            id: "source-link-\(Int(Date().timeIntervalSince1970))",
            inputURL: url.absoluteString,
            sourceSurface: sourceSurface,
            createdAt: Date()
        )
        do {
            let result = try await PublicPodcastLinkResolver().resolveAsync(request)
            return importResolvedSourceLink(request: request, result: result, startSession: startSession)
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }

    @discardableResult
    func importSourceLink(urlString: String, sourceSurface: String, startSession: Bool = true) -> Bool {
        isResolvingSourceLink = true
        defer { isResolvingSourceLink = false }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            reportFailure("Enter a valid podcast, RSS, or audio URL.")
            return false
        }
        do {
            let store = try requireStore()
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            statusMessage = "Resolving source link..."
            let request = LinkResolutionRequest(
                id: "source-link-\(Int(Date().timeIntervalSince1970))",
                inputURL: url.absoluteString,
                sourceSurface: sourceSurface,
                createdAt: Date()
            )
            snapshot = try engine.importSourceLink(request, startSessionWhenPlayable: startSession)
            libraryItems = try loadLibraryRows(store: store)
            if let itemId = snapshot.itemId {
                activeItemId = itemId
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["lastSourceLinkImport"] = snapshot.itemId ?? "none"
            diagnostics["lastSourceLinkStatus"] = snapshot.linkResolutionStatus ?? "unknown"
            diagnostics["lastSourceLinkFailureReason"] = snapshot.linkResolutionFailureReason ?? "none"
            let sourceLinkProvider = engine.lastLinkResolutionResult?.originalLink.provider
                ?? engine.lastLinkResolutionResult?.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkProvider"] = sourceLinkProvider ?? "unknown"
            if snapshot.linkResolutionStatus == LinkResolutionStatus.playable.rawValue, let title = snapshot.title {
                screen = startSession ? .playback : .item
                sourceTranscriptStatus = snapshot.sourceTranscriptStatus ?? "not_started"
                diagnostics["sourceTranscriptionStatus"] = sourceTranscriptStatus
                if let itemId = snapshot.itemId {
                    let resolved = engine.lastLinkResolutionResult
                    scheduleSourceTranscriptImportIfAvailable(
                        resolved?.selectedCandidate?.transcriptLinks ?? resolved?.candidates.flatMap(\.transcriptLinks) ?? [],
                        itemId: itemId
                    )
                }
                reportSuccess("Imported and started \(title).")
                return true
            }
            screen = .home
            reportFailure(sourceLinkFailureMessage(
                status: snapshot.linkResolutionStatus,
                reason: snapshot.linkResolutionFailureReason,
                provider: sourceLinkProvider
            ))
            return false
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }

    @discardableResult
    private func importResolvedSourceLink(request: LinkResolutionRequest, result: LinkResolutionResult, startSession: Bool = true) -> Bool {
        do {
            let store = try requireStore()
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            snapshot = try engine.importResolvedSourceLink(request, result: result, startSessionWhenPlayable: startSession)
            libraryItems = try loadLibraryRows(store: store)
            if let itemId = snapshot.itemId {
                activeItemId = itemId
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["lastSourceLinkImport"] = snapshot.itemId ?? "none"
            diagnostics["lastSourceLinkStatus"] = snapshot.linkResolutionStatus ?? "unknown"
            diagnostics["lastSourceLinkFailureReason"] = snapshot.linkResolutionFailureReason ?? "none"
            let sourceLinkProvider = result.originalLink.provider ?? result.candidates.first?.sourceLink.provider
            diagnostics["lastSourceLinkProvider"] = sourceLinkProvider ?? "unknown"
            if snapshot.linkResolutionStatus == LinkResolutionStatus.playable.rawValue, let title = snapshot.title {
                screen = startSession ? .playback : .item
                sourceTranscriptStatus = snapshot.sourceTranscriptStatus ?? "not_started"
                diagnostics["sourceTranscriptionStatus"] = sourceTranscriptStatus
                if let itemId = snapshot.itemId {
                    scheduleSourceTranscriptImportIfAvailable(
                        result.selectedCandidate?.transcriptLinks ?? result.candidates.flatMap(\.transcriptLinks),
                        itemId: itemId
                    )
                }
                reportSuccess("Imported and started \(title).")
                return true
            }
            screen = .home
            reportFailure(sourceLinkFailureMessage(
                status: snapshot.linkResolutionStatus,
                reason: snapshot.linkResolutionFailureReason,
                provider: sourceLinkProvider
            ))
            return false
        } catch {
            reportFailure(error, context: "Source link import failed")
            return false
        }
    }

    func configureQuickAccessFolder(url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmark = try url.bookmarkData(options: quickAccessBookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: quickAccessFolderBookmarkKey)
            UserDefaults.standard.set(url.lastPathComponent, forKey: "quickAccessFolderName")
            quickAccessFolderName = url.lastPathComponent
            refreshQuickAccessFolder()
            reportSuccess("Quick folder set to \(url.lastPathComponent).")
        } catch {
            reportFailure(error, context: "Quick folder setup failed")
        }
    }

    func refreshQuickAccessFolder() {
        guard let folderURL = resolvedQuickAccessFolderURL() else {
            quickAccessRecentFiles = []
            return
        }
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            let supported = files.compactMap { url -> (url: URL, date: Date)? in
                let ext = url.pathExtension.lowercased()
                guard ["md", "markdown", "txt"].contains(ext) else { return nil }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { return nil }
                return (url, values?.contentModificationDate ?? .distantPast)
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            quickAccessRecentFiles = supported
                .sorted { $0.date > $1.date }
                .prefix(2)
                .map { entry in
                    QuickAccessFile(
                        id: entry.url.lastPathComponent,
                        name: entry.url.deletingPathExtension().lastPathComponent,
                        relativePath: entry.url.lastPathComponent,
                        modifiedAtDescription: formatter.localizedString(for: entry.date, relativeTo: Date())
                    )
                }
            quickAccessFolderName = folderURL.lastPathComponent
            diagnostics["quickAccessFolder"] = folderURL.lastPathComponent
            diagnostics["quickAccessRecentFiles"] = "\(quickAccessRecentFiles.count)"
        } catch {
            quickAccessRecentFiles = []
            diagnostics["quickAccessError"] = String(describing: error)
        }
    }

    func importQuickAccessFile(_ file: QuickAccessFile) {
        guard let folderURL = resolvedQuickAccessFolderURL() else {
            reportFailure("Choose a quick folder before importing recent files.")
            return
        }
        let fileURL = folderURL.appending(path: file.relativePath)
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        importObsidianMarkdownFiles(urls: [fileURL])
        refreshQuickAccessFolder()
    }

    @discardableResult
    func importBrowserText(_ handoff: BrowserTextHandoff) -> Bool {
        do {
            let store = try requireStore()
            let engine = try makeEngine(store: store)
            installEngine(engine)
            let shouldStart = handoff.requestedContinuation.startSession
            var importOnlyHandoff = handoff
            importOnlyHandoff.requestedContinuation.startSession = false
            snapshot = try engine.importBrowserText(importOnlyHandoff)
            guard let importedItemId = snapshot.itemId ?? handoff.itemId else {
                throw SessionKitError.persistenceFailed("browser_text_item_id")
            }
            activeItemId = importedItemId
            libraryItems = try loadLibraryRows(store: store)
            selectedItem = try loadItemDetail(id: importedItemId, store: store)
            scheduleTextAudioPrewarmIfNeeded(itemId: importedItemId)
            diagnostics["lastBrowserTextImport"] = importedItemId
            diagnostics["lastBrowserTextSource"] = handoff.source.url
            if shouldStart {
                startItem(id: importedItemId)
            } else {
                screen = .item
                reportSuccess("Imported browser text from \(handoff.source.title).")
            }
            return true
        } catch {
            reportFailure(error, context: "Browser text import failed")
            return false
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

    func importPiperVoiceAssets(urls: [URL]) {
        guard !urls.isEmpty else {
            reportFailure("No Piper voice files were selected.")
            return
        }

        do {
            let assetsDirectory = try piperAssetsDirectory()
            try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)

            var copied: [String] = []
            var ignored: [String] = []

            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                guard isSupportedPiperVoiceAsset(url) else {
                    ignored.append(url.lastPathComponent)
                    continue
                }

                let destinationURL = assetsDirectory.appending(path: url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: url, to: destinationURL)
                copied.append(url.lastPathComponent)
            }

            refreshPiperVoiceStatus()
            let ignoredSuffix = ignored.isEmpty ? "" : " Ignored: \(ignored.joined(separator: ", "))."
            if copied.isEmpty {
                reportFailure("No Piper assets were imported. Select a .onnx voice model and its .onnx.json config.\(ignoredSuffix)")
            } else {
                reportSuccess("Imported Piper asset\(copied.count == 1 ? "" : "s").\(ignoredSuffix)")
            }
        } catch {
            reportFailure(error, context: "Piper voice import failed")
        }
    }

    func start() {
        stopSpeechPreviews()
        scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
        run { engine in
            snapshot = try engine.startSession(itemId: activeItemId)
            if isMediaPlaybackSnapshot, mediaPlaybackRate != snapshot.playbackRate {
                snapshot = try engine.setPlaybackRate(mediaPlaybackRate)
            }
            if let store, let sessionId = snapshot.sessionId {
                try seedUITestingGeneratedTimelineIfNeeded(sessionId: sessionId, engine: engine, store: store)
            }
            if let store {
                selectedItem = try loadItemDetail(id: activeItemId, store: store)
            }
            screen = .playback
            reportSuccess("Started \(snapshot.title ?? "session").")
        }
    }

    func playPause() {
        if snapshot.status.isPlaybackActive {
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
        if let item = try? store?.loadItem(id: activeItemId),
           item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           item.media?.url != nil {
            if sourceTranscriptStatus == "transcribing" || sourceTranscriptStatus == "queued" || sourceTranscriptStatus == "downloading" {
                isGeneratingListeningMap = false
                reportFailure("Source transcript is still being prepared. Listening Map will be available when transcription finishes.")
                return
            }
            if sourceTranscriptStatus == "unavailable" || sourceTranscriptStatus == "failed" {
                isGeneratingListeningMap = false
                reportFailure("Source transcript is unavailable, so this audio can only use timestamp anchors for now.")
                return
            }
            isGeneratingListeningMap = false
            reportFailure("No source transcript is ready yet. Interjections will use timestamp anchors until transcript context is available.")
            return
        }
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            run { engine in
                snapshot = try engine.generateListeningMap(itemId: activeItemId)
                if let store {
                    libraryItems = try loadLibraryRows(store: store)
                }
                refreshSelectedItem()
                diagnostics["lastGeneratedMapItem"] = activeItemId
                diagnostics["lastListeningMapMode"] = "local_deterministic"
                scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
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
        scheduleTextAudioPrewarmIfNeeded(itemId: item.id)
    }

    private func generateLocalListeningMap() {
        run { engine in
            snapshot = try engine.generateListeningMap(itemId: activeItemId)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
            }
            refreshSelectedItem()
            diagnostics["lastGeneratedMapItem"] = activeItemId
            scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
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
            scheduleTextAudioPrewarmIfNeeded(itemId: activeItemId)
            reportSuccess("Applied Listening Map.")
        } catch {
            reportFailure(error, context: "Listening Map validation failed")
        }
    }

    func jumpToChapter(_ chapter: Chapter) {
        stopSpeechPreviews()
        clearPendingAutoPlayTurns()
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
        clearPendingAutoPlayTurns()
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
            scheduleTextAudioPrewarmIfNeeded(itemId: id)
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

    func playLiveSpeechInstead() {
        guard canPlayLiveSpeechInstead else { return }
        liveSpeechFallbackItemIds.insert(activeItemId)
        pendingPreparedTextStartItemId = nil
        preparedTextAudioStatus = "live_fallback"
        snapshot.preparedTextAudioStatus = "live_fallback"
        diagnostics["textAudioFallback:\(activeItemId)"] = "explicit_user_action"
        start()
    }

    func openSession(_ session: Session) {
        stopSpeechPreviews()
        do {
            let store = try requireStore()
            activeItemId = session.itemId
            if engine == nil {
                installEngine(try makeEngine(store: store))
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
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return }
            if hasActiveSession {
                _ = try? engine.stopPlayback()
            }
            _ = try engine.inspectSession(sessionId: session.id)
            do {
                if session.phase == .finished || session.completionPercent >= 100 {
                    snapshot = try engine.playSourceFromBeginning()
                } else {
                    snapshot = try engine.resumePlayback()
                }
            } catch SessionKitError.invalidCommandForState("playback_text_empty") {
                snapshot = try engine.playSourceFromBeginning()
            }
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
            snapshot = try engine.skipBack(unit: skipUnitForCurrentTarget())
            refreshSelectedItem()
            reportSuccess("Skipped back.")
        }
    }

    func skipForward() {
        run { engine in
            let unit = skipUnitForCurrentTarget()
            if ttsMode == "kokoro" {
                snapshot = try engine.skipForward(unit: unit, minimumDistance: kokoroSkipForwardMinimumDistance)
            } else {
                snapshot = try engine.skipForward(unit: unit)
            }
            refreshSelectedItem()
            reportSuccess("Skipped forward.")
        }
    }

    func setMediaPlaybackRate(_ rate: Double) {
        let clamped = max(0.75, min(2.0, rate))
        mediaPlaybackRate = clamped
        UserDefaults.standard.set(clamped, forKey: "mediaPlaybackRate")
        run { engine in
            snapshot = try engine.setPlaybackRate(clamped)
            refreshSelectedItem()
            diagnostics["mediaPlaybackRate"] = String(format: "%.2f", clamped)
        }
    }

    private func skipUnitForCurrentTarget() -> String {
        switch snapshot.targetType {
        case TargetType.transcriptBackedMedia.rawValue, TargetType.browserOwnedMedia.rawValue:
            return "time_15s"
        default:
            return skipUnit
        }
    }

    func beginInterjection() {
        statusMessage = "Starting interjection..."
        lastError = nil
        diagnostics["lastInterjectionTap"] = "begin"
        Task {
            let granted = await requestMicrophonePermission()
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

    private func requestMicrophonePermission(timeoutSeconds: TimeInterval = 10) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await SystemRecordingClient.requestRecordPermission()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let granted = await group.next() ?? false
            group.cancelAll()
            diagnostics["lastMicrophonePermissionResult"] = granted ? "granted" : "denied_or_timeout"
            return granted
        }
    }

    func finishInterjection() {
        run { engine in
            snapshot = try engine.finishInterjection(audioRef: nil)
            refreshSelectedItem()
            if let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
                scheduleSourceWindowContextIfNeeded(for: interjection)
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

    func renderSelectedItemForWatchPackage() {
        renderWatchPackage(itemId: selectedItem.id, transferAfterRender: false)
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
        let currentInterjections = currentDiscussionInterjections()
        let request = Gate1DiscussionContext.primaryRequest(explicitFollowUp: trimmed, currentInterjections: currentInterjections)
        submitDiscussionFollowUp(request, explicitFollowUp: trimmed, primaryInterjections: currentInterjections)
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
        clearPendingAutoPlayTurns()
        run { engine in
            snapshot = try engine.jumpToTurnChapter(turnId: turn.id, chapterId: chapter.id)
            refreshSelectedItem()
            screen = .playback
            reportSuccess("Jumped to \(chapter.title).")
        }
    }

    private func playTurn(_ turnId: String, engine: SessionEngine) throws {
        try playTurn(turnId, engine: engine, clearsPendingQueue: true)
    }

    private func playTurn(_ turnId: String, engine: SessionEngine, clearsPendingQueue: Bool) throws {
        stopSpeechPreviews()
        if clearsPendingQueue {
            clearPendingAutoPlayTurns()
        }
        snapshot = try engine.playTurn(turnId: turnId)
        refreshSelectedItem()
        screen = .playback
    }

    private func autoPlayCompletedTurn(
        kind: String,
        turnId: String,
        engine: SessionEngine,
        completedCurrentAudio: Bool = false
    ) throws {
        guard kind == "interjection_summary" || kind == "assistant_response" else { return }
        if shouldDeferGeneratedTurnPlayback(turnId: turnId, completedCurrentAudio: completedCurrentAudio) {
            enqueuePendingAutoPlayTurn(turnId)
            return
        }
        try playTurn(turnId, engine: engine)
    }

    private func playPendingTurnIfReady(completedCurrentAudio: Bool = false) {
        guard let engine,
              let turnId = pendingAutoPlayQueue.popReadyTurn(snapshot: snapshot, completedCurrentAudio: completedCurrentAudio) else {
            return
        }
        do {
            updatePendingAutoPlayDiagnostics(reason: "draining_queue")
            try playTurn(turnId, engine: engine, clearsPendingQueue: false)
            reportSuccess("Playing generated response.")
        } catch {
            reportFailure(error, context: "Auto-play generated response failed")
        }
    }

    private func shouldDeferGeneratedTurnPlayback(turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        pendingAutoPlayQueue.shouldDeferGeneratedTurnPlayback(
            snapshot: snapshot,
            turnId: turnId,
            completedCurrentAudio: completedCurrentAudio
        )
    }

    private func shouldPlayPendingTurnNow(turnId: String, completedCurrentAudio: Bool = false) -> Bool {
        pendingAutoPlayQueue.shouldPlayPendingTurnNow(snapshot: snapshot, turnId: turnId, completedCurrentAudio: completedCurrentAudio)
    }

    private func enqueuePendingAutoPlayTurn(_ turnId: String) {
        pendingAutoPlayQueue.enqueue(turnId)
        updatePendingAutoPlayDiagnostics(reason: "waiting_for_current_audio")
    }

    private func clearPendingAutoPlayTurns() {
        pendingAutoPlayQueue.clear()
        diagnostics["pendingAutoPlayTurnId"] = nil
        diagnostics["pendingAutoPlayQueue"] = "0"
        diagnostics["pendingAutoPlayReason"] = nil
    }

    private func updatePendingAutoPlayDiagnostics(reason: String) {
        diagnostics["pendingAutoPlayTurnId"] = pendingAutoPlayQueue.first
        diagnostics["pendingAutoPlayQueue"] = "\(pendingAutoPlayQueue.count)"
        diagnostics["pendingAutoPlayReason"] = reason
    }

    private func latestPendingJob(kind: String) -> AIJob? {
        guard let sessionId = snapshot.sessionId,
              let jobs = try? store?.loadAIJobs(sessionId: sessionId) else {
            return nil
        }
        return jobs.last { $0.kind == kind && $0.status != "complete" }
    }

    func followUp(_ text: String) {
        submitDiscussionFollowUp(text, explicitFollowUp: text, primaryInterjections: currentDiscussionInterjections())
    }

    private func submitDiscussionFollowUp(_ text: String, explicitFollowUp: String, primaryInterjections: [Interjection]) {
        run { engine in
            snapshot = try engine.submitFollowup(text: text)
            let turnId = latestPendingJob(kind: "assistant_response")?.turnId ?? "turn-response-001"
            submitProviderJobIfNeeded(
                kind: "assistant_response",
                turnId: turnId,
                messages: [conversationPrompt(
                    followUp: text,
                    explicitFollowUp: explicitFollowUp,
                    primaryInterjections: primaryInterjections
                )]
            )
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
            persistExportSettings()
            let export = try engine.buildExport(options: currentExportOptions())
            exportPreview = try renderExport(export)
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
        reportSuccess("Copied \(exportFormat == "json" ? "JSON" : "Markdown") export.")
        #else
        reportFailure("Clipboard is unavailable on this platform.")
        #endif
    }

    func copyTargetInterjections(targetType: String, targetId: String, format: String = "markdown") {
        run { engine in
            let export = try engine.buildExport(options: ExportOptions(
                sessionId: snapshot.sessionId,
                includeFullText: false,
                includeReference: true,
                includeListeningMap: false,
                includeInterjections: true,
                includeTurns: targetType != InterjectionTargetType.item.rawValue,
                scope: "target",
                targetType: targetType,
                targetId: targetId
            ))
            guard !export.interjections.isEmpty else {
                reportFailure("No interjections are available for that target.")
                return
            }
            let text = try renderExport(export, format: format)
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportSuccess("Copied target interjections.")
            #else
            exportPreview = text
            reportSuccess("Built target interjection export.")
            #endif
        }
    }

    func importPastedAssistantResponse(autoPlay: Bool = true) {
        let text = pastedAssistantResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            reportFailure("Paste a response before importing.")
            return
        }
        stopSpeechPreviews()
        run { engine in
            if !hasActiveSession {
                snapshot = try engine.startSession(itemId: activeItemId)
            }
            snapshot = try engine.importAssistantResponse(text: text, autoPlay: autoPlay)
            pastedAssistantResponse = ""
            refreshSelectedItem()
            screen = .playback
            reportSuccess(autoPlay ? "Imported and playing pasted response." : "Imported pasted response.")
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
            diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
            settingsValueChanged()
            refreshKokoroAssetStatus()
            refreshPiperVoiceStatus()
            reportSuccess("Diagnostics refreshed.")
        }
    }

    func dispatchGate2CompactCommand(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) {
        if command == .beginInterjection {
            Task {
                let granted = await SystemRecordingClient.requestRecordPermission()
                guard granted else {
                    reportFailure("Microphone access is required to record interjections from compact controls.")
                    return
                }
                performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
            }
            return
        }
        performGate2CompactCommand(command, chapterId: chapterId, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
    }

    func handleGate2CompactURL(_ url: URL) {
        guard let rawCommand = Gate2CompactCommandURL.command(from: url),
              let command = CompactControlCommand(rawValue: rawCommand) else {
            reportFailure("Unsupported compact control URL.")
            return
        }
        dispatchGate2CompactCommand(command, origin: "compact_url")
    }

    func importPendingSourceLinkHandoffs() {
        Task { @MainActor in
            await importPendingSourceLinkHandoffsAsync()
        }
    }

    private func importPendingSourceLinkHandoffsAsync() async {
        guard !isImportingPendingSourceLinkHandoffs else { return }
        isImportingPendingSourceLinkHandoffs = true
        defer { isImportingPendingSourceLinkHandoffs = false }
        do {
            let handoffStore = try resolvedSourceLinkHandoffStore()
            let payloadIDs = try handoffStore.pendingPayloadIDs()
            guard !payloadIDs.isEmpty else { return }
            diagnostics["pendingSourceLinkPayloads"] = "\(payloadIDs.count)"
            for payloadID in payloadIDs {
                do {
                    let handoff = try handoffStore.handoff(payloadID: payloadID)
                    let imported: Bool
                    if sourceLinkResolver == nil {
                        imported = await importSourceLinkAsync(handoff)
                    } else {
                        imported = importSourceLink(handoff)
                    }
                    if imported {
                        try? handoffStore.deletePayload(payloadID: payloadID)
                        diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "deleted_after_import"
                    } else {
                        diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "retained_after_failed_import"
                    }
                } catch SourceLinkHandoffStoreError.invalidPayload {
                    try? handoffStore.deletePayload(payloadID: payloadID)
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "deleted_invalid_payload"
                } catch SourceLinkHandoffStoreError.missingPayload {
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "missing"
                } catch {
                    diagnostics["pendingSourceLinkPayload:\(payloadID)"] = "retained_error:\(error.localizedDescription)"
                }
            }
        } catch {
            diagnostics["pendingSourceLinkImport"] = "unavailable:\(error.localizedDescription)"
        }
    }

    func handleIncomingURL(_ url: URL) {
        if url.scheme == "spokenmargins", url.host == "open" {
            screen = hasActiveSession ? .playback : .home
            return
        }
        if SourceLinkHandoffURL.isSourceLinkURL(url) {
            do {
                if let payloadID = SourceLinkHandoffURL.payloadID(from: url) {
                    let handoffStore = try resolvedSourceLinkHandoffStore()
                    let handoff = try SourceLinkHandoffURL.handoff(from: url, store: handoffStore)
                    if sourceLinkResolver == nil {
                        Task { @MainActor in
                            let imported = await importSourceLinkAsync(handoff)
                            if imported {
                                try? handoffStore.deletePayload(payloadID: payloadID)
                                diagnostics["lastSourceLinkPayloadCleanup"] = "deleted_after_import"
                            } else {
                                diagnostics["lastSourceLinkPayloadCleanup"] = "retained_after_failed_import"
                            }
                        }
                    } else {
                        let imported = importSourceLink(handoff)
                        if imported {
                            try? handoffStore.deletePayload(payloadID: payloadID)
                            diagnostics["lastSourceLinkPayloadCleanup"] = "deleted_after_import"
                        } else {
                            diagnostics["lastSourceLinkPayloadCleanup"] = "retained_after_failed_import"
                        }
                    }
                } else if let handoff = SourceLinkHandoffURL.handoff(from: url) {
                    if sourceLinkResolver == nil {
                        Task { @MainActor in
                            await importSourceLinkAsync(handoff)
                        }
                    } else {
                        importSourceLink(handoff)
                    }
                } else {
                    reportFailure("Unsupported source link URL.")
                }
            } catch {
                reportFailure(error, context: "Source link import failed")
            }
            return
        }
        guard !Gate5BrowserTextHandoffURL.isBrowserTextURL(url) else {
            do {
                if let payloadID = Gate5BrowserTextHandoffURL.payloadID(from: url) {
                    let handoffStore = try Gate5BrowserTextHandoffStore.appGroup()
                    let handoff = try Gate5BrowserTextHandoffURL.handoff(from: url, store: handoffStore)
                    if importBrowserText(handoff) {
                        try? handoffStore.deletePayload(payloadID: payloadID)
                    }
                } else if let handoff = Gate5BrowserTextHandoffURL.handoff(from: url) {
                    importBrowserText(handoff)
                } else {
                    reportFailure("Unsupported browser text URL.")
                }
            } catch {
                reportFailure(error, context: "Browser text import failed")
            }
            return
        }
        handleGate2CompactURL(url)
    }

    @discardableResult
    func handleGate2CompactApplicationCommand(_ command: String) -> Bool {
        switch command {
        case Gate2CompactApplicationCommand.summarizeInterjections:
            guard gate2CompactSnapshot?.availableCommands.contains(.generateInterjectionSummary) == true else {
                reportFailure("Summary is unavailable for the current compact surface state.")
                return false
            }
            summarize()
            return true
        case Gate2CompactApplicationCommand.discussInterjections:
            guard gate2CompactSnapshot?.availableCommands.contains(.submitFollowup) == true else {
                reportFailure("Discuss is unavailable for the current compact surface state.")
                return false
            }
            discuss(followUp: "")
            return true
        default:
            reportFailure("Unsupported compact application command.")
            return false
        }
    }

    func saveProviderSettings() {
        sanitizeTTSMode()
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
        UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
        UserDefaults.standard.set(kokoroChunkCharacters, forKey: "kokoroChunkCharacters")
        KeychainStore.save(providerAPIKey, service: "SpokenMargins", account: "OpenAICompatibleAPIKey")
        cancelTextAudioPrewarmTasks()
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
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
        diagnostics["kokoroCacheLimitMB"] = String(kokoroCacheLimitMB)
        diagnostics["kokoroChunkCharacters"] = String(format: "%.0f", kokoroChunkCharacters)
        diagnostics["apiKeyConfigured"] = providerAPIKey.isEmpty ? "false" : "true"
        if rebuildEngineForCurrentSettings() {
            screen = .settings
            reportSuccess("Provider settings saved.")
        }
    }

    func saveSpeechSettings() {
        sanitizeTTSMode()
        UserDefaults.standard.set(speechRate, forKey: "speechRate")
        UserDefaults.standard.set(speechVoiceIdentifier, forKey: "speechVoiceIdentifier")
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        UserDefaults.standard.set(kokoroVoiceName, forKey: "kokoroVoiceName")
        UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
        UserDefaults.standard.set(kokoroChunkCharacters, forKey: "kokoroChunkCharacters")
        cancelTextAudioPrewarmTasks()
        diagnostics["speechRate"] = String(format: "%.2f", speechRate)
        diagnostics["speechVoice"] = speechVoiceDescription
        diagnostics["ttsMode"] = ttsMode
        diagnostics["kokoroVoice"] = kokoroVoiceName
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
        diagnostics["kokoroCacheLimitMB"] = String(kokoroCacheLimitMB)
        diagnostics["kokoroChunkCharacters"] = String(format: "%.0f", kokoroChunkCharacters)
    }

    func refreshSpeechVoiceOptions() {
        speechVoiceOptions = Self.availableSpeechVoiceOptions()
        diagnostics["speechVoiceCount"] = "\(speechVoiceOptions.count)"
        diagnostics["speechVoice"] = speechVoiceDescription
    }

    func speechSettingsChanged() {
        let changed = sanitizeTTSMode()
        settingsValueChanged()
        saveSpeechSettings()
        _ = rebuildEngineForCurrentSettings()
        if changed {
            reportFailure("Kokoro requires the SpokenMarginsAppDevice scheme on a physical device.")
        }
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

    func refreshPiperVoiceStatus() {
        do {
            piperVoiceOptions = try discoverPiperVoiceOptions()
            if piperVoiceId.isEmpty, let first = piperVoiceOptions.first {
                piperVoiceId = first.id
                UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
            } else if !piperVoiceId.isEmpty, !piperVoiceOptions.contains(where: { $0.id == piperVoiceId }) {
                piperVoiceId = piperVoiceOptions.first?.id ?? ""
                UserDefaults.standard.set(piperVoiceId, forKey: "piperVoiceId")
            }
            if piperVoiceOptions.isEmpty {
                piperStatus = "No Piper voices installed. Import a .onnx model and .onnx.json config."
            } else if let selected = piperVoiceOptions.first(where: { $0.id == piperVoiceId }) {
                piperStatus = "Selected \(selected.displayName). Renderer not linked yet; playback falls back to system speech."
            } else {
                piperStatus = "\(piperVoiceOptions.count) Piper voice\(piperVoiceOptions.count == 1 ? "" : "s") installed."
            }
            diagnostics["piperVoices"] = "\(piperVoiceOptions.count)"
            diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
            diagnostics["piperStatus"] = piperStatus
        } catch {
            piperVoiceOptions = []
            piperStatus = "Piper voice check failed: \(error.localizedDescription)"
            diagnostics["piperStatus"] = piperStatus
        }
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
        diagnostics["piperVoice"] = piperVoiceId.isEmpty ? "none" : piperVoiceId
        diagnostics["piperStatus"] = piperStatus
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

    var isMediaPlaybackSnapshot: Bool {
        snapshot.targetType == TargetType.transcriptBackedMedia.rawValue ||
            snapshot.targetType == TargetType.browserOwnedMedia.rawValue
    }

    var displayPlaybackProgressPercent: Int {
        switch snapshot.targetType {
        case TargetType.itemTextTTS.rawValue,
            TargetType.transcriptBackedMedia.rawValue,
            TargetType.browserOwnedMedia.rawValue:
            return snapshot.sourceProgressPercent
        default:
            return snapshot.currentPlaybackProgressPercent
        }
    }

    var canPlayLiveSpeechInstead: Bool {
        pendingPreparedTextStartItemId == activeItemId
    }

    var canFinishInterjection: Bool {
        snapshot.isRecording
    }

    var canSummarizeInterjections: Bool {
        hasActiveSession && !unsummarizedInterjectionsForCurrentTarget().isEmpty
    }

    var isSummarizingInterjections: Bool {
        latestPendingJob(kind: "interjection_summary") != nil ||
        pendingAutoPlayQueue.contains(where: { $0.contains("summary") }) ||
        snapshot.targetType == TargetType.summaryTurnTTS.rawValue
    }

    var interjectionButtonTitle: String {
        "Interject"
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
        if ttsMode == "kokoro", isKokoroDeviceBuild {
            return String(format: "Kokoro %.2fx", max(0.65, min(1.75, speechRate / 0.5)))
        }
        return String(format: "System %.2f", speechRate)
    }

    var mediaPlaybackRateDescription: String {
        String(format: "%.2fx", mediaPlaybackRate)
    }

    var preparedTextAudioStatusDescription: String {
        humanReadableStatus(preparedTextAudioStatus)
    }

    var sourceTranscriptStatusDescription: String {
        humanReadableStatus(sourceTranscriptStatus)
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

    private func humanReadableStatus(_ status: String) -> String {
        switch status {
        case "not_started":
            return "not started"
        case "rendering":
            return "rendering"
        case "starter_ready":
            return "starter ready"
        case "ready", "complete":
            return "ready"
        case "failed":
            return "failed"
        case "live_fallback":
            return "live fallback"
        case "queued":
            return "queued"
        case "downloading":
            return "downloading"
        case "transcribing":
            return "transcribing"
        case "unavailable":
            return "unavailable"
        default:
            return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    var currentChapter: Chapter? {
        selectedItem.chapters.last { $0.percent <= snapshot.sourceProgressPercent } ?? selectedItem.chapters.first
    }

    private func installEngine(_ engine: SessionEngine) {
        self.engine = engine
        configureGate2CompactControls(for: engine)
        configureGate3WatchControls(for: engine)
    }

    private func configureGate2CompactControls(for engine: SessionEngine) {
        do {
            let surfaceProfile = try loadProfile(id: "lock-screen-widget")
            gate2CompactControls.configure(
                canonicalRuntime: engine,
                surfaceProfile: surfaceProfile,
                skipUnit: "time_15s"
            ) { [weak self] command, origin, mediaTimeMs, playbackRate in
                self?.dispatchGate2CompactCommand(command, mediaTimeMs: mediaTimeMs, playbackRate: playbackRate, origin: origin)
            } applicationCommandHandler: { [weak self] command in
                self?.handleGate2CompactApplicationCommand(command) ?? false
            }
            updateGate2CompactState()
            diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
        } catch {
            diagnostics["gate2CompactSurface"] = "configuration_failed"
            diagnostics["gate2CompactError"] = String(describing: error)
        }
    }

    private func updateGate2CompactState() {
        gate2CompactControls.update(snapshot: snapshot)
        gate2CompactSnapshot = gate2CompactControls.snapshot
        diagnostics.merge(gate2CompactControls.diagnostics(), uniquingKeysWith: { _, new in new })
    }

    private func configureGate3WatchControls(for engine: SessionEngine) {
        do {
            let surfaceProfile = try loadProfile(id: "watch-tethered")
            gate3WatchDispatcher = CompactControlDispatcher(
                surfaceProfile: surfaceProfile,
                canonicalRuntime: engine,
                defaultSkipUnit: skipUnit
            )
            updateGate3WatchState()
        } catch {
            diagnostics["gate3WatchSurface"] = "configuration_failed"
            diagnostics["gate3WatchError"] = String(describing: error)
        }
    }

    private func gate3WatchSnapshot() -> CompactControlSnapshot? {
        gate3WatchDispatcher?.snapshot()
    }

    private func updateGate3WatchState() {
        gate3WatchConnectivity.publish(snapshot: gate3WatchSnapshot())
        diagnostics.merge(gate3WatchConnectivity.diagnostics(), uniquingKeysWith: { _, new in new })
    }

    private func gate4WatchPackageLibraryRows() -> [WatchPackageLibraryRow] {
        do {
            let store = try requireStore()
            try seedGate4WatchPackageFixture(store: store)
            let items = try store.listItems()
            return try items.flatMap { item -> [WatchPackageLibraryRow] in
                let packages = try store.loadWatchAudioPackages(itemId: item.id)
                let requests = try store.loadWatchPackageRequests(itemId: item.id)
                if let package = packages.sorted(by: { $0.createdAt > $1.createdAt }).first {
                    let hasTransferRequest = requests.contains { $0.packageId == package.id && $0.requestType == .watchTransferRequested }
                    return [
                        WatchPackageLibraryRow(
                            itemId: item.id,
                            title: package.item.title.isEmpty ? item.title : package.item.title,
                            status: hasTransferRequest ? .queuedForTransfer : .availableForTransfer,
                            packageId: package.id,
                            progressPercent: hasTransferRequest ? 0 : nil
                        )
                    ]
                }
                let hasPrerenderRequest = requests.contains { $0.requestType == .prerenderRequested }
                let status: WatchPackageLibraryStatus
                if activeWatchPackageRenderItemIds.contains(item.id) {
                    status = .rendering
                } else if failedWatchPackageRenderItemIds.contains(item.id) {
                    status = .failed
                } else if hasPrerenderRequest {
                    status = .rendering
                } else {
                    status = .needsPrerender
                }
                return [
                    WatchPackageLibraryRow(
                        itemId: item.id,
                        title: item.title,
                        status: status,
                        packageId: nil,
                        progressPercent: status == .rendering ? 0 : nil
                    )
                ]
            }
        } catch {
            diagnostics["gate4WatchPackageLibraryError"] = String(describing: error)
            return []
        }
    }

    private func gate4WatchPackage(packageId: String) throws -> WatchAudioPackage? {
        let store = try requireStore()
        try seedGate4WatchPackageFixture(store: store)
        return try store.loadWatchAudioPackage(id: packageId)
    }

    private func handleGate4WatchPackageRequest(_ request: WatchPackageRequestEvent) {
        do {
            let store = try requireStore()
            try store.saveWatchPackageRequest(request)
            diagnostics["gate4WatchLastPackageRequest"] = "\(request.requestType.rawValue):\(request.itemId)"
            if request.requestType == .prerenderRequested {
                renderWatchPackage(itemId: request.itemId, transferAfterRender: true)
            } else if request.requestType == .watchTransferRequested, let packageId = request.packageId {
                gate3WatchConnectivity.transferWatchPackage(packageId: packageId)
            }
            gate3WatchConnectivity.publishPackageLibrary()
        } catch {
            diagnostics["gate4WatchPackageRequestError"] = String(describing: error)
            reportFailure(error, context: "Watch package request failed")
        }
    }

    private func handleGate4WatchSyncEvent(_ event: WatchSyncEvent) {
        do {
            let store = try requireStore()
            try seedGate4WatchPackageFixture(store: store)
            try store.saveWatchSyncEvent(event)
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            _ = try engine?.importWatchSyncEvent(eventId: event.id)
            if let engine {
                snapshot = engine.snapshot
            }
            libraryItems = try loadLibraryRows(store: store)
            let importedItemId: String?
            if let itemId = event.itemId {
                importedItemId = itemId
            } else {
                importedItemId = try store.loadWatchAudioPackage(id: event.watchPackageId)?.itemId
            }
            if let itemId = importedItemId {
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["gate4WatchLastImportedEvent"] = event.id
            reportSuccess("Imported Watch event \(event.id).")
        } catch {
            diagnostics["gate4WatchSyncEventError"] = String(describing: error)
            reportFailure(error, context: "Watch sync import failed")
        }
    }

    private func renderWatchPackage(itemId: String, transferAfterRender: Bool) {
        guard !itemId.isEmpty else {
            reportFailure("Choose an item before rendering Watch audio.")
            return
        }
        guard !activeWatchPackageRenderItemIds.contains(itemId) else {
            reportFailure("Watch audio is already rendering for this item.")
            return
        }
        activeWatchPackageRenderItemIds.insert(itemId)
        failedWatchPackageRenderItemIds.remove(itemId)
        isRenderingWatchPackage = true
        watchPackageRenderStatus = "Rendering"
        diagnostics["gate4WatchRenderItem"] = itemId
        gate3WatchConnectivity.publishPackageLibrary()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let store = try self.requireStore()
                let item = try store.loadItem(id: itemId)
                let map = try store.loadListeningMap(itemId: itemId)
                let coordinator = WatchPackageRenderCoordinator(
                    applicationSupportDirectory: try self.applicationSupportDirectory()
                )
                let output = try await coordinator.renderSystemSpeechPackage(
                    item: item,
                    map: map,
                    voiceIdentifier: self.speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self.speechVoiceIdentifier,
                    rate: Float(self.speechRate)
                )
                try store.saveWatchAudioPackage(output.package)
                self.activeWatchPackageRenderItemIds.remove(itemId)
                self.failedWatchPackageRenderItemIds.remove(itemId)
                self.isRenderingWatchPackage = !self.activeWatchPackageRenderItemIds.isEmpty
                self.libraryItems = try self.loadLibraryRows(store: store)
                if itemId == self.selectedItem.id || itemId == self.activeItemId {
                    self.selectedItem = try self.loadItemDetail(id: itemId, store: store)
                }
                self.diagnostics["gate4WatchLastRenderedPackage"] = output.package.id
                self.diagnostics["gate4WatchLastRenderedAudio"] = output.audioURL.lastPathComponent
                self.watchPackageRenderStatus = "Available"
                self.reportSuccess("Rendered Watch package \(output.package.item.title).")
                self.gate3WatchConnectivity.publishPackageLibrary()
                if transferAfterRender {
                    self.gate3WatchConnectivity.transferWatchPackage(packageId: output.package.id)
                }
            } catch {
                self.activeWatchPackageRenderItemIds.remove(itemId)
                self.failedWatchPackageRenderItemIds.insert(itemId)
                self.isRenderingWatchPackage = !self.activeWatchPackageRenderItemIds.isEmpty
                self.watchPackageRenderStatus = "Failed"
                self.diagnostics["gate4WatchRenderError"] = String(describing: error)
                self.reportFailure(error, context: "Watch package render failed")
                self.gate3WatchConnectivity.publishPackageLibrary()
            }
        }
    }

    private func dispatchGate3WatchCommand(_ request: Gate3WatchCommandRequest) {
        diagnostics["gate2LastCommandOrigin"] = "watch_connectivity_legacy"
        if request.command == .beginInterjection {
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = "disabled_until_watch_recording"
            updateGate3WatchState()
            reportFailure("Watch interjection is disabled until Watch-owned or background-safe recording is available.")
            return
        }
        guard gate3WatchSnapshot()?.availableCommands.contains(request.command) == true else {
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = "unavailable"
            updateGate3WatchState()
            reportFailure("Watch command \(request.command.rawValue) is unavailable for the current session state.")
            return
        }
        if request.command == .generateInterjectionSummary {
            summarize()
            updateGate3WatchState()
            return
        }
        if request.command == .submitFollowup {
            discuss(followUp: request.followUpText ?? "Can you respond to my interjection?")
            updateGate3WatchState()
            return
        }
        if request.command == .beginInterjection {
            Task {
                let granted = await SystemRecordingClient.requestRecordPermission()
                guard granted else {
                    reportFailure("Microphone access is required to record interjections from Watch.")
                    updateGate3WatchState()
                    return
                }
                performGate3WatchCommand(request)
            }
            return
        }
        performGate3WatchCommand(request)
    }

    private func performGate3WatchCommand(_ request: Gate3WatchCommandRequest) {
        do {
            if engine == nil {
                resetAndSeed()
            }
            guard let dispatcher = gate3WatchDispatcher else {
                throw SessionKitError.invalidCommandForState("watch_tethered_unconfigured")
            }
            let result = try dispatcher.dispatch(
                request.command,
                chapterId: request.chapterId,
                unit: request.unit,
                followUpText: request.followUpText
            )
            if let engine {
                snapshot = engine.snapshot
            } else {
                updateGate3WatchState()
            }
            refreshSelectedItem()
            if request.command == .finishInterjection, let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
                scheduleSourceWindowContextIfNeeded(for: interjection)
            }
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = result.delegatedToCanonicalRuntime ? "delegated" : (result.rejectedReason ?? "rejected")
            updateGate3WatchState()
            reportSuccess("Watch control \(request.command.rawValue) delegated.")
        } catch {
            diagnostics["gate3WatchLastCommand"] = request.command.rawValue
            diagnostics["gate3WatchLastResult"] = "failed"
            updateGate3WatchState()
            reportFailure(error, context: "Watch control failed")
        }
    }

    private func performGate2CompactCommand(
        _ command: CompactControlCommand,
        chapterId: String? = nil,
        mediaTimeMs: Int? = nil,
        playbackRate: Double? = nil,
        origin: String = "app_ui"
    ) {
        do {
            let result = try gate2CompactControls.dispatch(
                command,
                chapterId: chapterId,
                mediaTimeMs: mediaTimeMs,
                playbackRate: playbackRate,
                origin: origin
            )
            if let engine {
                snapshot = engine.snapshot
            } else {
                updateGate2CompactState()
            }
            refreshSelectedItem()
            if command == .finishInterjection, let interjection = latestInterjectionNeedingTranscription() {
                scheduleTranscription(for: interjection)
                scheduleSourceWindowContextIfNeeded(for: interjection)
            }
            reportSuccess("Compact control \(command.rawValue) \(result.delegatedToCanonicalRuntime ? "delegated" : "handled").")
        } catch {
            reportFailure(error, context: "Compact control failed")
        }
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

    private func piperAssetsDirectory() throws -> URL {
        try applicationSupportDirectory().appending(path: "Piper", directoryHint: .isDirectory)
    }

    private func isSupportedPiperVoiceAsset(_ url: URL) -> Bool {
        let lowercasedName = url.lastPathComponent.lowercased()
        return lowercasedName.hasSuffix(".onnx") || lowercasedName.hasSuffix(".onnx.json")
    }

    private func discoverPiperVoiceOptions() throws -> [PiperVoiceOption] {
        let directory = try piperAssetsDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.lastPathComponent.lowercased().hasSuffix(".onnx") }
            .compactMap { modelURL -> PiperVoiceOption? in
                let voiceId = piperVoiceId(forModelURL: modelURL)
                guard !voiceId.isEmpty else { return nil }
                let configURL = piperConfigURL(forVoiceId: voiceId, in: directory)
                let metadata = piperVoiceMetadata(configURL: configURL)
                return PiperVoiceOption(
                    id: voiceId,
                    name: metadata.name ?? piperDisplayName(for: voiceId),
                    language: metadata.language ?? "",
                    modelURL: modelURL,
                    configURL: configURL
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func piperVoiceId(forModelURL url: URL) -> String {
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".onnx") else { return "" }
        return String(name.dropLast(5))
    }

    private func piperConfigURL(forVoiceId voiceId: String, in directory: URL) -> URL? {
        let candidates = [
            directory.appending(path: "\(voiceId).onnx.json"),
            directory.appending(path: "\(voiceId).json")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func piperDisplayName(for voiceId: String) -> String {
        voiceId
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { token in
                token.prefix(1).uppercased() + token.dropFirst()
            }
            .joined(separator: " ")
    }

    private func piperVoiceMetadata(configURL: URL?) -> (name: String?, language: String?) {
        guard let configURL,
              let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let dataset = object["dataset"] as? String
        let language = object["language"] as? [String: Any]
        let languageCode = language?["code"] as? String
        let languageName = language?["name"] as? String
        return (
            dataset?.isEmpty == false ? dataset : nil,
            languageName ?? languageCode
        )
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
        Gate1SummaryEligibility.unsummarizedInterjections(
            turns: selectedItem.turns,
            interjections: selectedItem.interjections,
            currentTargetType: currentPlaybackTargetType,
            currentTargetId: currentPlaybackTargetId
        )
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
            installEngine(try makeEngine(store: store))
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
            aiProvider: provider,
            linkResolver: sourceLinkResolver ?? PublicPodcastLinkResolver(),
            textAudio: try makeTextAudioPreparationClient()
        )
    }

    private func makeTextAudioPreparationClient() throws -> TextAudioPreparationClient? {
        guard audioPlaybackClientOverride == nil else { return nil }
        guard ttsMode != "kokoro" else { return nil }
        guard ttsMode != "piper" else { return nil }
        #if canImport(AVFoundation)
        diagnostics["sessionTextAudio"] = "System generated audio"
        return SystemTextAudioPreparationClient(
            outputDirectory: try generatedTextAudioDirectory(),
            voiceIdentifier: speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : speechVoiceIdentifier,
            speechRate: Float(speechRate),
            allowsSynchronousRendering: false
        )
        #else
        return nil
        #endif
    }

    private func scheduleTextAudioPrewarmIfNeeded(itemId: String) {
        guard audioPlaybackClientOverride == nil, ttsMode != "kokoro" else { return }
        guard ttsMode != "piper" else { return }
        guard textAudioPrewarmTasks[itemId] == nil else { return }
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: itemId)
            guard shouldPrewarmTextAudio(for: item), let text = item.text else { return }
            let outputDirectory = try generatedTextAudioDirectory()
            let voiceIdentifier = speechVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : speechVoiceIdentifier
            let rate = Float(speechRate)
            diagnostics["textAudioPrewarm:\(itemId)"] = "scheduled"
            preparedTextAudioStatus = "rendering"
            snapshot.preparedTextAudioStatus = preparedTextAudioStatus
            textAudioPrewarmTasks[itemId] = Task { [weak self, itemId, title = item.title, text, outputDirectory, voiceIdentifier, rate] in
                guard let self else { return }
                self.diagnostics["textAudioPrewarm:\(itemId)"] = "rendering_full"
                let fullResult = await Self.prepareTextAudioInBackground(
                    itemId: itemId,
                    title: title,
                    text: text,
                    outputDirectory: outputDirectory,
                    voiceIdentifier: voiceIdentifier,
                    speechRate: rate,
                    renderScope: .complete
                )
                guard !Task.isCancelled else { return }
                self.textAudioPrewarmTasks[itemId] = nil
                switch fullResult {
                case .success(let prepared):
                    guard let prepared else {
                        self.finishTextAudioPrewarm(itemId: itemId, status: "failed", diagnostic: "full_unavailable")
                        return
                    }
                    self.attachPreparedTextAudio(prepared, itemId: itemId, preparedStatus: "ready", diagnosticStatus: "ready")
                case .failure(let error):
                    self.finishTextAudioPrewarm(itemId: itemId, status: "failed", diagnostic: "full_failed:\(error.localizedDescription)")
                }
            }
        } catch {
            diagnostics["textAudioPrewarm:\(itemId)"] = "failed:\(error.localizedDescription)"
            preparedTextAudioStatus = "failed"
            snapshot.preparedTextAudioStatus = "failed"
        }
    }

    private nonisolated static func prepareTextAudioInBackground(
        itemId: String,
        title: String,
        text: String,
        outputDirectory: URL,
        voiceIdentifier: String?,
        speechRate: Float,
        renderScope: TextAudioPrewarmRenderScope
    ) async -> Result<PreparedTextAudio?, Error> {
        await Task.detached(priority: renderScope.priority) {
            do {
                let renderer = SystemTextAudioPreparationClient(
                    outputDirectory: outputDirectory,
                    voiceIdentifier: voiceIdentifier,
                    speechRate: speechRate,
                    allowsSynchronousRendering: true
                )
                switch renderScope {
                case .starter(let targetDurationMs):
                    return .success(try renderer.prepareStarterTextAudio(itemId: itemId, title: title, text: text, targetDurationMs: targetDurationMs))
                case .complete:
                    return .success(try renderer.prepareTextAudio(itemId: itemId, title: title, text: text))
                }
            } catch {
                return .failure(error)
            }
        }.value
    }

    @discardableResult
    private func attachPreparedTextAudio(
        _ prepared: PreparedTextAudio,
        itemId: String,
        preparedStatus: String = "ready",
        diagnosticStatus: String = "ready"
    ) -> Bool {
        do {
            let shouldAutoStart = pendingPreparedTextStartItemId == itemId
            if engine == nil, let store {
                installEngine(try makeEngine(store: store))
            }
            guard let engine else { return false }
            snapshot = try engine.attachPreparedTextAudio(itemId: itemId, prepared: prepared)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
                if activeItemId == itemId || selectedItem.id == itemId {
                    selectedItem = try loadItemDetail(id: itemId, store: store)
                }
            }
            diagnostics["textAudioPrewarm:\(itemId)"] = diagnosticStatus
            preparedTextAudioStatus = preparedStatus
            snapshot.preparedTextAudioStatus = preparedStatus
            if shouldAutoStart {
                pendingPreparedTextStartItemId = nil
                startItem(id: itemId)
            }
            return true
        } catch {
            diagnostics["textAudioPrewarm:\(itemId)"] = "attach_failed:\(error.localizedDescription)"
            if pendingPreparedTextStartItemId == itemId {
                pendingPreparedTextStartItemId = nil
            }
            preparedTextAudioStatus = "failed"
            snapshot.preparedTextAudioStatus = "failed"
            return false
        }
    }

    private func finishTextAudioPrewarm(itemId: String, status: String, diagnostic: String) {
        textAudioPrewarmTasks[itemId] = nil
        diagnostics["textAudioPrewarm:\(itemId)"] = diagnostic
        if pendingPreparedTextStartItemId == itemId {
            pendingPreparedTextStartItemId = nil
        }
        preparedTextAudioStatus = status
        snapshot.preparedTextAudioStatus = status
    }

    private nonisolated static func preparedTextAudioCoversCompleteText(_ prepared: PreparedTextAudio) -> Bool {
        guard let endChar = prepared.timeline.segments.compactMap(\.endChar).max() else {
            return false
        }
        return endChar >= prepared.normalizedText.count
    }

    private func shouldPrewarmTextAudio(for item: Item) -> Bool {
        guard item.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        if item.mediaType == TargetType.browserOwnedMedia.rawValue {
            return false
        }
        switch item.media?.sourceType {
        case .none, .some(.generatedTTSRealtime):
            return true
        case .some(.generatedTTSPrerendered):
            return isStarterPreparedTextMedia(item.media)
        case .some(.nativeMediaFile), .some(.browserOwnedMedia), .some(.remoteStream):
            return false
        }
    }

    private func isStarterPreparedTextMedia(_ media: ItemMedia?) -> Bool {
        guard media?.sourceType == .generatedTTSPrerendered else { return false }
        let identifier = media?.nativeMediaId ?? media?.url ?? ""
        return identifier.contains("-starter.caf") || identifier.contains("-starter.")
    }

    private func cancelTextAudioPrewarmTasks() {
        textAudioPrewarmTasks.values.forEach { $0.cancel() }
        textAudioPrewarmTasks.removeAll()
    }

    private func generatedTextAudioDirectory() throws -> URL {
        let cachesDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return cachesDirectory.appending(path: "GeneratedTextAudio", directoryHint: .isDirectory)
    }

    private func prepareTextPlaybackBeforeStarting(itemId: String) -> Bool {
        do {
            let store = try requireStore()
            let item = try store.loadItem(id: itemId)
            guard shouldGatePreparedTextPlayback(for: item) else {
                return false
            }
            pendingPreparedTextStartItemId = itemId
            diagnostics["textAudioStartGate:\(itemId)"] = "waiting_for_prepared_media"
            if preparedTextAudioStatus != "failed" {
                preparedTextAudioStatus = "rendering"
                snapshot.preparedTextAudioStatus = "rendering"
            }
            if engine == nil {
                installEngine(try makeEngine(store: store))
            }
            selectedItem = try loadItemDetail(id: itemId, store: store)
            screen = .playback
            reportSuccess("Preparing generated audio for \(item.title).")
            return true
        } catch {
            reportFailure(error, context: "Prepare text playback failed")
            return true
        }
    }

    private func shouldGatePreparedTextPlayback(for item: Item) -> Bool {
        guard (audioPlaybackClientOverride == nil || forcePreparedTextGate),
              ttsMode != "kokoro",
              !liveSpeechFallbackItemIds.contains(item.id),
              shouldPrewarmTextAudio(for: item) else {
            return false
        }
        if item.media?.sourceType == .generatedTTSPrerendered {
            return false
        }
        return true
    }

    private enum TextAudioPrewarmRenderScope: Sendable {
        case starter(targetDurationMs: Int)
        case complete

        var priority: TaskPriority {
            switch self {
            case .starter:
                return .userInitiated
            case .complete:
                return .utility
            }
        }
    }

    private func makeAudioPlaybackClient() throws -> AudioPlaybackClient {
        if let audioPlaybackClientOverride {
            diagnostics["sessionTTS"] = "Test audio override"
            return audioPlaybackClientOverride
        }
        sanitizeTTSMode()
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
            let speech = KokoroSpeechPlaybackClient(
                applicationSupportDirectory: supportDirectory,
                outputDirectory: cachesDirectory.appending(path: "KokoroPlayback", directoryHint: .isDirectory),
                voiceName: kokoroVoiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "am_echo" : kokoroVoiceName,
                speed: Float(speechRate / 0.5),
                cacheLimitBytes: kokoroCacheLimitBytes,
                maxCharacters: kokoroChunkCharacterLimit
            )
            return RoutedAudioPlaybackClient(speech: speech, media: makeMediaPlaybackClient())
        }
        #endif
        if ttsMode == "kokoro" {
            diagnostics["sessionTTS"] = "Kokoro unavailable in this build; using system speech"
        } else {
            diagnostics["sessionTTS"] = "System speech"
        }
        return RoutedAudioPlaybackClient(
            speech: SystemSpeechPlaybackClient(),
            media: makeMediaPlaybackClient()
        )
    }

    private func makeMediaPlaybackClient() -> AudioPlaybackClient {
        AVPlayerStreamPlaybackClient { [weak self] command, mediaTimeMs, playbackRate in
            Task { @MainActor [weak self] in
                self?.performGate2CompactCommand(
                    command,
                    mediaTimeMs: mediaTimeMs,
                    playbackRate: playbackRate,
                    origin: "now_playing"
                )
            }
        }
    }

    @discardableResult
    private func sanitizeTTSMode() -> Bool {
        guard (ttsMode == "kokoro" && !isKokoroDeviceBuild) || ttsMode == "piper" else {
            return false
        }
        ttsMode = "systemImmediate"
        UserDefaults.standard.set(ttsMode, forKey: "ttsMode")
        return true
    }

    private func loadLibraryRows(store: SQLiteSessionStore) throws -> [LibraryItemRow] {
        try store.listItems().map { item in
            LibraryItemRow(
                id: item.id,
                title: item.title,
                status: libraryStatusLabel(for: item),
                canDelete: isUserImportedItem(item.id)
            )
        }
    }

    private func libraryStatusLabel(for item: Item) -> String {
        guard item.status == "ready" else { return item.status }
        if item.media != nil || item.mediaType == TargetType.transcriptBackedMedia.rawValue {
            return "Audio ready"
        }
        return item.status
    }

    private func resolvedSourceLinkHandoffStore() throws -> SourceLinkHandoffStore {
        if let sourceLinkHandoffStore {
            return sourceLinkHandoffStore
        }
        return try SourceLinkHandoffStore.appGroup()
    }

    private func sourceLinkFailureMessage(status: String?, reason: String?, provider: String?) -> String {
        switch reason {
        case "spotify_audio_requires_provider_playback":
            if provider == "spotify" {
                return "This looks like a Spotify-only episode. Spoken Margins could not find a public audio file for it yet."
            }
            return "This provider did not expose a public audio file that Spoken Margins can play yet."
        case "apple_episode_id_missing":
            return "That Apple Podcasts link did not identify a specific episode."
        case "apple_lookup_empty":
            return "Apple Podcasts did not return this episode from lookup, and I could not find a public audio stream on the Apple page."
        case "apple_audio_enclosure_not_found":
            return "Apple Podcasts did not expose a playable public audio stream for that episode."
        case "audio_enclosure_not_found":
            return "I found the page or feed, but not a playable podcast/audio file."
        case "rss_episode_ambiguous":
            return "I found the feed, but could not identify one episode to play."
        case "unsupported_link_type":
            return "That link is not a supported public podcast, RSS feed, or direct audio file."
        case "apple_lookup_failed":
            return "Apple Podcasts did not return a playable public audio file for that episode."
        case .some(let message):
            return message
        case .none:
            if status == LinkResolutionStatus.unsupported.rawValue {
                return "That link is not playable in Spoken Margins yet."
            }
            return "Source link needs review before it can be played."
        }
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return URL(string: text)
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.url).first
    }

    private func isUserImportedItem(_ id: String) -> Bool {
        id.hasPrefix("item-import-") || id.hasPrefix("item-obsidian-") || id.hasPrefix("item-browser-") || id.hasPrefix("item-source-")
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
                let (data, response) = try await performProviderDataRequest(request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    let body = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                    throw ProviderCallError.http(status, body)
                }
                let text = try decodeProviderText(data)
                await MainActor.run {
                    do {
                        guard let engine else { return }
                        let completedCurrentAudio = syncPlaybackProgressBeforeGeneratedTurnDecision(engine: engine)
                        snapshot = try engine.aiStreamDelta(turnId: turnId, content: text)
                        snapshot = try engine.aiJobCompleted(turnId: turnId)
                        refreshSelectedItem()
                        try autoPlayCompletedTurn(
                            kind: kind,
                            turnId: turnId,
                            engine: engine,
                            completedCurrentAudio: completedCurrentAudio
                        )
                        reportSuccess(pendingAutoPlayQueue.contains { $0 == turnId } ? "Provider response saved. Playback will start when the current audio finishes." : "Provider response saved.")
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

    private func syncPlaybackProgressBeforeGeneratedTurnDecision(engine: SessionEngine) -> Bool {
        let previousStatus = snapshot.status
        let previousTargetId = snapshot.targetId
        do {
            let updated = try engine.syncPlaybackProgress()
            if updated != snapshot {
                snapshot = updated
            }
            return previousStatus.isPlaybackActive &&
                updated.status == .paused &&
                previousTargetId == updated.targetId
        } catch {
            diagnostics["playbackProgressSyncError"] = String(describing: error)
            return false
        }
    }

    private func callProvider(messages: [String], model: String, systemPrompt: String) async throws -> String {
        guard !providerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderCallError.missingAPIKey
        }
        guard let request = makeChatCompletionsRequest(messages: messages, model: model, systemPrompt: systemPrompt) else {
            throw ProviderCallError.invalidURL
        }
        let (data, response) = try await performProviderDataRequest(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw ProviderCallError.http(status, body)
        }
        return try decodeProviderText(data)
    }

    private func performProviderDataRequest(_ request: URLRequest, timeoutSeconds: TimeInterval = 30) async throws -> (Data, URLResponse) {
        var timedRequest = request
        timedRequest.timeoutInterval = timeoutSeconds
        diagnostics["lastProviderRequestURL"] = timedRequest.url?.absoluteString ?? "none"
        diagnostics["lastProviderRequestStartedAt"] = "\(Date().timeIntervalSince1970)"
        return try await Self.performProviderDataRequestOffMain(timedRequest, timeoutSeconds: timeoutSeconds)
    }

    private nonisolated static func performProviderDataRequestOffMain(
        _ request: URLRequest,
        timeoutSeconds: TimeInterval
    ) async throws -> (Data, URLResponse) {
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await URLSession.shared.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return result
        }
    }

    private func makeChatCompletionsRequest(messages: [String], model: String, systemPrompt: String) -> URLRequest? {
        Gate1ProviderRequestFactory.makeChatCompletionsRequest(
            baseURL: providerBaseURL,
            apiKey: providerAPIKey,
            messages: messages,
            model: model,
            systemPrompt: systemPrompt
        )
    }

    private func modelForAIJob(kind: String) -> String {
        Gate1ProviderRequestFactory.modelForAIJob(
            kind: kind,
            listeningMapModel: listeningMapModel,
            summaryModel: summaryModel,
            conversationModel: conversationModel,
            fallbackProviderModel: fallbackProviderModel()
        )
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
        Gate1ProviderRequestFactory.systemPromptForAIJob(kind: kind)
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

    private func scheduleSourceTranscriptImportIfAvailable(_ links: [SourceTranscriptLink], itemId: String) {
        guard !links.isEmpty else {
            diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "no_links"
            return
        }
        guard let store,
              let item = try? store.loadItem(id: itemId),
              item.transcriptId == nil else { return }
        let sortedLinks = Self.prioritizedTranscriptLinks(links)
        diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "scheduled:\(sortedLinks.count)"
        diagnostics["sourceTranscriptionStatus"] = "downloading"
        sourceTranscriptStatus = "downloading"
        snapshot.sourceTranscriptStatus = "downloading"
        Task { [weak self, itemId, sortedLinks, durationMs = item.media?.durationMs] in
            guard let self else { return }
            var lastFailure = ""
            for link in sortedLinks {
                do {
                    let data = try await Self.fetchTranscriptLink(link)
                    if let timeline = try Self.transcriptTimeline(from: data, link: link, itemId: itemId, durationMs: durationMs),
                       !timeline.segments.isEmpty {
                        await MainActor.run {
                            self.diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "attached:\(link.type)"
                            self.attachSourceTranscriptTimeline(timeline, itemId: itemId)
                        }
                        return
                    }
                    lastFailure = "empty:\(link.type)"
                } catch {
                    lastFailure = "\(link.type):\(error.localizedDescription)"
                }
            }
            await MainActor.run {
                self.diagnostics["sourceTranscriptDiscovery:\(itemId)"] = "unavailable:\(lastFailure)"
                self.diagnostics["sourceTranscriptionStatus"] = "unavailable"
                self.sourceTranscriptStatus = "unavailable"
                self.snapshot.sourceTranscriptStatus = "unavailable"
            }
        }
    }

    private static func prioritizedTranscriptLinks(_ links: [SourceTranscriptLink]) -> [SourceTranscriptLink] {
        links.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = transcriptLinkRank(lhs.element)
                let rhsRank = transcriptLinkRank(rhs.element)
                if lhsRank == rhsRank {
                    return lhs.offset < rhs.offset
                }
                return lhsRank < rhsRank
            }
            .map(\.element)
    }

    private static func transcriptLinkRank(_ link: SourceTranscriptLink) -> Int {
        let value = "\(link.type) \(link.url) \(link.rel ?? "")".lowercased()
        if value.contains("vtt") || value.contains("webvtt") { return 0 }
        if value.contains("srt") || value.contains("subrip") { return 1 }
        if value.contains("json") { return 2 }
        if value.contains("plain") || value.contains(".txt") { return 3 }
        if value.contains("html") || value.contains(".htm") { return 4 }
        return 5
    }

    private static func fetchTranscriptLink(_ link: SourceTranscriptLink) async throws -> Data {
        guard let url = URL(string: link.url),
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            throw SessionKitError.persistenceFailed("source_transcript_url_unsupported")
        }
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("SpokenMargins/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func transcriptTimeline(from data: Data, link: SourceTranscriptLink, itemId: String, durationMs: Int?) throws -> TranscriptTimeline? {
        let type = "\(link.type) \(link.url)".lowercased()
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        if type.contains("vtt") || type.contains("srt") {
            return cueTranscriptTimeline(from: text, itemId: itemId, durationMs: durationMs)
        }
        if type.contains("json") {
            return jsonTranscriptTimeline(from: data, itemId: itemId, durationMs: durationMs)
        }
        let cleaned = type.contains("html") ? stripHTML(text) : text
        let normalized = cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let endMs = max(1, durationMs ?? 1)
        return TranscriptTimeline(
            segments: [
                MediaTimelineSegment(
                    id: "transcript-\(itemId)-plain-0001",
                    startMs: 0,
                    endMs: endMs,
                    text: normalized
                )
            ],
            chapters: [],
            durationMs: durationMs ?? endMs
        )
    }

    private static func cueTranscriptTimeline(from text: String, itemId: String, durationMs: Int?) -> TranscriptTimeline {
        let blocks = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        var segments: [MediaTimelineSegment] = []
        for block in blocks {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count >= 2,
                  let startMs = parseCueTime(parts[0]),
                  let endMs = parseCueTime(parts[1]) else {
                continue
            }
            let body = lines[(timingIndex + 1)...]
                .joined(separator: " ")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            segments.append(MediaTimelineSegment(
                id: "transcript-\(itemId)-cue-\(String(format: "%04d", segments.count + 1))",
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: body
            ))
        }
        return TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: durationMs ?? segments.map(\.endMs).max()
        )
    }

    private static func jsonTranscriptTimeline(from data: Data, itemId: String, durationMs: Int?) -> TranscriptTimeline? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [[String: Any]]
        if let array = object as? [[String: Any]] {
            entries = array
        } else if let dictionary = object as? [String: Any],
                  let nested = (dictionary["segments"] ?? dictionary["transcripts"] ?? dictionary["captions"]) as? [[String: Any]] {
            entries = nested
        } else if let dictionary = object as? [String: Any],
                  let text = dictionary["text"] as? String {
            let normalized = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            let endMs = max(1, durationMs ?? 1)
            return TranscriptTimeline(
                segments: [MediaTimelineSegment(id: "transcript-\(itemId)-json-0001", startMs: 0, endMs: endMs, text: normalized)],
                chapters: [],
                durationMs: durationMs ?? endMs
            )
        } else {
            return nil
        }
        var segments: [MediaTimelineSegment] = []
        for entry in entries {
            let body = (entry["text"] ?? entry["body"] ?? entry["caption"]) as? String ?? ""
            let text = body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let startMs = jsonTimeMs(entry["start"] ?? entry["startTime"] ?? entry["start_ms"] ?? entry["offset"]) ?? 0
            let explicitEndMs = jsonTimeMs(entry["end"] ?? entry["endTime"] ?? entry["end_ms"])
            let duration = jsonTimeMs(entry["duration"] ?? entry["durationMs"] ?? entry["duration_ms"])
            let endMs = explicitEndMs ?? duration.map { startMs + $0 } ?? max(startMs + 1, durationMs ?? startMs + 1)
            segments.append(MediaTimelineSegment(
                id: "transcript-\(itemId)-json-\(String(format: "%04d", segments.count + 1))",
                startMs: startMs,
                endMs: max(startMs + 1, endMs),
                text: text
            ))
        }
        guard !segments.isEmpty else { return nil }
        return TranscriptTimeline(
            segments: segments,
            chapters: [],
            durationMs: durationMs ?? segments.map(\.endMs).max()
        )
    }

    private static func parseCueTime(_ raw: String) -> Int? {
        let value = raw
            .split(separator: " ")
            .first?
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = value.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        let secondsPart = parts.last ?? "0"
        let seconds = Double(secondsPart) ?? 0
        let minutes = parts.count >= 2 ? Double(parts[parts.count - 2]) ?? 0 : 0
        let hours = parts.count >= 3 ? Double(parts[parts.count - 3]) ?? 0 : 0
        return Int(((hours * 3600) + (minutes * 60) + seconds) * 1000)
    }

    private static func jsonTimeMs(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return double < 10_000 ? Int((double * 1000).rounded()) : Int(double.rounded())
        case let string as String:
            if string.contains(":") {
                return parseCueTime(string)
            }
            guard let double = Double(string) else { return nil }
            return double < 10_000 ? Int((double * 1000).rounded()) : Int(double.rounded())
        default:
            return nil
        }
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }

    private func scheduleSourceTranscriptionIfNeeded(for item: Item) {
        guard item.transcriptId == nil,
              let sourceURLString = item.media?.url,
              let sourceURL = URL(string: sourceURLString) else {
            return
        }
        diagnostics["sourceTranscriptionStatus"] = "transcribing"
        sourceTranscriptStatus = "transcribing"
        snapshot.sourceTranscriptStatus = "transcribing"
        statusMessage = "Transcribing source audio..."
        Task { [weak self] in
            guard let self else { return }
            do {
                let timeline = try await self.sourceTranscriptionClient.transcribeSourceAudio(
                    url: sourceURL,
                    itemId: item.id,
                    durationMs: item.media?.durationMs
                )
                await MainActor.run {
                    self.attachSourceTranscriptTimeline(timeline, itemId: item.id)
                }
            } catch {
                await MainActor.run {
                    self.diagnostics["sourceTranscriptionStatus"] = "unavailable"
                    self.diagnostics["sourceTranscriptionError"] = String(describing: error)
                    self.sourceTranscriptStatus = "unavailable"
                    self.snapshot.sourceTranscriptStatus = "unavailable"
                    if self.lastError == nil {
                        self.statusMessage = "Audio ready. Source transcript unavailable; notes will use timestamps."
                    }
                }
            }
        }
    }

    private func attachSourceTranscriptTimeline(_ timeline: TranscriptTimeline, itemId: String) {
        run { engine in
            snapshot = try engine.attachTranscriptTimeline(itemId: itemId, timeline: timeline)
            if let store {
                libraryItems = try loadLibraryRows(store: store)
                selectedItem = try loadItemDetail(id: itemId, store: store)
            }
            diagnostics["sourceTranscriptionStatus"] = "complete"
            diagnostics["sourceTranscriptionItem"] = itemId
            sourceTranscriptStatus = "ready"
            snapshot.sourceTranscriptStatus = "ready"
            reportSuccess("Source transcript ready for anchored notes.")
        }
    }

    private func scheduleSourceWindowContextIfNeeded(for interjection: Interjection) {
        guard interjection.targetType == .item,
              let anchorMediaTimeMs = interjection.anchor.mediaTimeMs,
              let store,
              let item = try? store.loadItem(id: interjection.itemId),
              item.transcriptId == nil,
              let sourceURLString = item.media?.url,
              let sourceURL = URL(string: sourceURLString) else {
            return
        }
        switch item.media?.sourceType {
        case .some(.nativeMediaFile), .some(.remoteStream):
            break
        default:
            return
        }
        diagnostics["sourceWindowTranscription:\(interjection.id)"] = "scheduled"
        Task { [weak self, interjectionId = interjection.id, itemId = item.id, durationMs = item.media?.durationMs] in
            guard let self else { return }
            do {
                let timeline = try await self.sourceTranscriptionClient.transcribeSourceAudioWindow(
                    url: sourceURL,
                    itemId: itemId,
                    anchorMediaTimeMs: anchorMediaTimeMs,
                    durationMs: durationMs,
                    windowBeforeMs: 90_000,
                    windowAfterMs: 120_000
                )
                await MainActor.run {
                    self.run { engine in
                        self.snapshot = try engine.sourceWindowContextCompleted(interjectionId: interjectionId, timeline: timeline)
                        self.refreshSelectedItem()
                        self.diagnostics["sourceWindowTranscription:\(interjectionId)"] = "complete"
                    }
                }
            } catch {
                await MainActor.run {
                    self.diagnostics["sourceWindowTranscription:\(interjectionId)"] = "failed:\(error.localizedDescription)"
                }
            }
        }
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

    private func conversationPrompt(followUp: String, explicitFollowUp: String, primaryInterjections: [Interjection]) -> String {
        let scopedInterjections = primaryInterjections.isEmpty ? currentDiscussionInterjections() : primaryInterjections
        return Gate1ProviderRequestFactory.conversationPrompt(
            followUp: followUp,
            contextJSON: sessionContextJSON(
                interjections: scopedInterjections,
                currentFollowUp: followUp,
                explicitFollowUp: explicitFollowUp,
                primaryInterjections: scopedInterjections
            )
        )
    }

    private func sessionContextJSON(
        interjections: [Interjection],
        currentFollowUp: String?,
        explicitFollowUp: String? = nil,
        primaryInterjections: [Interjection] = []
    ) -> String {
        let map: [String: Any] = [
            "schemaVersion": currentFollowUp == nil ? "session-export.v1" : "conversation-context.v2",
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
            "primaryUserIntent": currentFollowUp.map { followUp in
                [
                    "source": Gate1DiscussionContext.primaryIntentSource(
                        explicitFollowUp: explicitFollowUp ?? "",
                        currentInterjections: primaryInterjections
                    ),
                    "request": followUp,
                    "targetType": currentPlaybackTargetType,
                    "targetId": currentPlaybackTargetId ?? "",
                    "target": currentDiscussionTargetContext(),
                    "interjections": primaryInterjections.map { interjection in
                        [
                            "id": interjection.id,
                            "targetType": interjection.targetType.rawValue,
                            "targetId": interjection.targetId,
                            "anchorBefore": interjection.anchor.anchorBefore,
                            "anchorAfter": interjection.anchor.anchorAfter,
                            "transcriptionStatus": interjection.transcriptionStatus,
                            "transcript": interjection.cleanedTranscript ?? interjection.transcript ?? "pending"
                        ]
                    }
                ] as [String: Any]
            } ?? NSNull(),
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

    private func currentDiscussionInterjections() -> [Interjection] {
        Gate1DiscussionContext.currentTargetInterjections(
            interjections: selectedItem.interjections,
            currentTargetType: currentPlaybackTargetType,
            currentTargetId: currentPlaybackTargetId,
            itemId: selectedItem.id
        )
    }

    private func currentDiscussionTargetContext() -> [String: Any] {
        let targetType = currentPlaybackTargetType
        let targetId = currentPlaybackTargetId ?? ""
        switch targetType {
        case TargetType.summaryTurnTTS.rawValue, TargetType.assistantTurnTTS.rawValue:
            if let turn = selectedItem.turns.first(where: { $0.id == targetId }) {
                return [
                    "id": turn.id,
                    "targetType": targetType,
                    "role": turn.role,
                    "turnType": turn.turnType,
                    "summary": turn.summary ?? "",
                    "text": turn.text ?? turn.rawText ?? ""
                ]
            }
        default:
            break
        }
        return [
            "id": selectedItem.id,
            "targetType": TargetType.itemTextTTS.rawValue,
            "title": selectedItem.title,
            "overview": selectedItem.overview
        ]
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

    private func persistExportSettings() {
        UserDefaults.standard.set(exportFormat, forKey: "exportFormat")
        UserDefaults.standard.set(exportScope, forKey: "exportScope")
        UserDefaults.standard.set(exportIncludesSourceText, forKey: "exportIncludesSourceText")
        UserDefaults.standard.set(exportIncludesReference, forKey: "exportIncludesReference")
        UserDefaults.standard.set(exportIncludesListeningMap, forKey: "exportIncludesListeningMap")
        UserDefaults.standard.set(exportIncludesInterjections, forKey: "exportIncludesInterjections")
        UserDefaults.standard.set(exportIncludesTurns, forKey: "exportIncludesTurns")
    }

    private func currentExportOptions() -> ExportOptions {
        ExportOptions(
            sessionId: snapshot.sessionId,
            includeFullText: exportIncludesSourceText,
            includeReference: exportIncludesReference,
            includeListeningMap: exportIncludesListeningMap,
            includeInterjections: exportIncludesInterjections,
            includeTurns: exportIncludesTurns,
            scope: exportScope
        )
    }

    private func renderExport(_ export: SessionExport, format: String? = nil) throws -> String {
        if (format ?? exportFormat) == "json" {
            let data = try encoder.encode(export)
            return String(data: data, encoding: .utf8) ?? ""
        }
        return SessionExportMarkdownRenderer.render(export)
    }

    private func resolvedQuickAccessFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: quickAccessFolderBookmarkKey) else { return nil }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: quickAccessBookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let refreshed = try url.bookmarkData(options: quickAccessBookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(refreshed, forKey: quickAccessFolderBookmarkKey)
            }
            return url
        } catch {
            diagnostics["quickAccessBookmarkError"] = String(describing: error)
            return nil
        }
    }

    private var quickAccessBookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private var quickAccessBookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
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

    private func seedUITestingGeneratedTimelineIfNeeded(sessionId: String, engine: SessionEngine, store: SQLiteSessionStore) throws {
        guard CommandLine.arguments.contains("--ui-testing"),
              try store.loadTurns(sessionId: sessionId).isEmpty else {
            return
        }
        _ = try engine.submitFollowup(text: "Can you respond to my interjection?")
        _ = try engine.aiStreamDelta(
            turnId: "turn-response-001",
            content: """
            <sm_summary>Here is a quick response to your interjection.</sm_summary>
            <sm_response>Here is a quick response to your interjection. First, your test is checking whether generated turns stay easy to navigate. Second, the response chapters should remain tappable in the main timeline.</sm_response>
            <sm_chapters_json>{"schemaVersion":"assistant-response-map.v1","chapters":[{"id":"ai-ch-1","title":"Quick Response","anchor":"Here is a quick response"},{"id":"ai-ch-2","title":"Timeline Navigation","anchor":"Second, the response chapters"}]}</sm_chapters_json>
            """
        )
        _ = try engine.aiJobCompleted(turnId: "turn-response-001")
        snapshot = try engine.inspectSession(sessionId: sessionId)
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

    private func seedGate4WatchPackageFixture(store: SQLiteSessionStore) throws {
        guard let url = Bundle.main.url(forResource: "offline-package", withExtension: "json", subdirectory: "fixtures/watch") else {
            return
        }
        let package = try ContractFixtureLoader.watchAudioPackage(at: url)
        try store.saveWatchAudioPackage(package)
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
