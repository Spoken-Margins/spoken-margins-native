import AppKit
import AVFoundation
import Observation
import DesktopCore
import SessionKit
import SessionKitAudio
import SessionKitSupertonic

struct DesktopMarginRow: Identifiable {
    let id: String
    let text: String
    let context: String
    let hasAudio: Bool
}

@MainActor @Observable
final class DesktopModel {
    private static let startWithComposerKey = "desktopStartWithComposer"
    var draft = ""
    var message: String?
    var rate = UserDefaults.standard.object(forKey: "desktopSpeechRate") as? Double ?? 1.0
    var aiChapterSummariesEnabled = UserDefaults.standard.bool(forKey: "desktopAIChapterSummariesEnabled")
    private(set) var chapterSummaries: [String: String] = [:]
    private(set) var isGeneratingChapterSummaries = false
    var selectedVoiceID = UserDefaults.standard.string(forKey: "desktopVoiceID") ?? ""
    var selectedLanguage = UserDefaults.standard.string(forKey: "desktopVoiceLanguage") ?? ""
    var selectedBackend = DesktopVoiceBackend(rawValue: UserDefaults.standard.string(forKey: "desktopVoiceBackend") ?? "") ?? .mac
    var selectedSupertonicVoice = SupertonicVoiceID(rawValue: UserDefaults.standard.string(forKey: "desktopSupertonicVoice") ?? "M2") ?? .m2
    var chatterboxPythonPath = UserDefaults.standard.string(forKey: "desktopChatterboxPythonPath") ?? ""
    var chatterboxModelPath = UserDefaults.standard.string(forKey: "desktopChatterboxModelPath") ?? ""
    var selectedChatterboxModel = DesktopChatterboxModel(rawValue: UserDefaults.standard.string(forKey: "desktopChatterboxModel") ?? "nano") ?? .nano
    var voicePerformanceMessage: String?
    var voiceRenderStatus: String?
    var isVoiceWaiting = false
    let voiceOptions = SystemSpeechPlaybackClient.availableVoiceOptions()
    private(set) var isPlaying = false
    private(set) var isRecording = false
    private(set) var isBusy = false
    private(set) var session: DesktopSession?
    private(set) var recentSessions: [DesktopSession] = []
    @ObservationIgnored private var store: DesktopSessionStore?
    @ObservationIgnored private var audio: DesktopAudio?
    @ObservationIgnored private var neural: DesktopNeuralSpeech?
    @ObservationIgnored private var supertonic: DesktopSupertonicService?
    @ObservationIgnored private let chatterbox = DesktopChatterboxService()
    @ObservationIgnored private var voiceTestPlayer: AVAudioPlayer?
    @ObservationIgnored private var voiceTestURL: URL?
    @ObservationIgnored private var monitoring: Task<Void, Never>?
    @ObservationIgnored private var recordingTimeout: Task<Void, Never>?
    @ObservationIgnored private let recordingControl = RecordingControlPanel()
    @ObservationIgnored private var recordingAnchor: Anchor?
    @ObservationIgnored private var resumeAfterRecording = false
    @ObservationIgnored private var transcribingMarginIDs = Set<String>()
    @ObservationIgnored private var pendingBrowserURL: URL?
    let directory: URL

    var hasSession: Bool { session != nil }
    var title: String { session?.title ?? "" }
    var progress: Double { Double(session?.session.completionPercent ?? 0) / 100 }
    var currentOffset: Int { session?.currentOffset ?? 0 }
    var sourceLength: Int { session?.sourceText.count ?? 0 }
    var chapters: [Chapter] { session?.listeningMap?.chapters ?? [] }
    var chapterSummaryAvailabilityMessage: String? { DesktopChapterSummarizer.availabilityMessage() }
    private var chapterSummaryStore: DesktopChapterSummaryStore {
        DesktopChapterSummaryStore(directory: directory.appendingPathComponent("ChapterSummaries", isDirectory: true))
    }
    func summary(for chapter: Chapter) -> String? {
        aiChapterSummariesEnabled ? chapterSummaries[chapter.id] : nil
    }
    var supertonicReady: Bool {
        guard let supertonic else { return false }
        return supertonic.setupError == nil
    }
    var supertonicSetupError: String? { supertonic?.setupError }
    var supertonicSupportsLanguage: Bool { SupertonicNarrationRenderer.supportedLanguages.contains(selectedLanguage) }
    var chatterboxReady: Bool { (try? chatterboxConfiguration().validate()) != nil }
    var chatterboxSetupError: String? {
        do { try chatterboxConfiguration().validate(); return nil }
        catch { return error.localizedDescription }
    }
    func chatterboxModelAvailable(_ variant: DesktopChatterboxModel) -> Bool {
        let checkpoint = variant == .nano ? "t3_nano_v1.safetensors" : "t3_turbo_v1.safetensors"
        return FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: chatterboxModelPath).appendingPathComponent(checkpoint).path)
    }
    func chatterboxVariantReady(_ variant: DesktopChatterboxModel) -> Bool {
        (try? chatterboxConfiguration(variant: variant).validate()) != nil
    }
    var availableLanguages: [String] { DesktopVoiceCatalog.languages(for: voiceDescriptors) }
    var filteredVoiceOptions: [SpeechVoiceOption] {
        voiceOptions
            .filter { DesktopVoiceCatalog.languageCode(for: $0.language) == selectedLanguage }
            .sorted {
                let rank = ["Premium": 0, "Enhanced": 1, "Default": 2]
                let left = rank[$0.quality] ?? 3
                let right = rank[$1.quality] ?? 3
                return left == right ? $0.name < $1.name : left < right
            }
    }
    private var voiceDescriptors: [DesktopVoiceDescriptor] {
        voiceOptions.map { DesktopVoiceDescriptor(id: $0.id, language: $0.language) }
    }
    var margins: [DesktopMarginRow] {
        (session?.margins ?? []).map {
            DesktopMarginRow(id: $0.id, text: $0.transcript ?? "",
                context: $0.anchor.anchorBefore + " ▸ " + $0.anchor.anchorAfter,
                hasAudio: $0.audioPath != nil)
        }
    }

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpokenMarginsDesktop", isDirectory: true)
        DesktopURLRouter.handle = { [weak self] url in self?.receiveBrowserURL(url) }
        selectedLanguage = DesktopVoiceCatalog.languageCode(for: selectedLanguage)
        if !availableLanguages.contains(selectedLanguage) {
            let currentVoiceLanguage = voiceOptions.first(where: { $0.id == selectedVoiceID })?.language
            selectedLanguage = DesktopVoiceCatalog.preferredLanguage(
                from: voiceDescriptors,
                preferredLanguages: [currentVoiceLanguage].compactMap { $0 } + Locale.preferredLanguages
            ) ?? ""
        }
        if !voiceOptions.contains(where: { $0.id == selectedVoiceID }) {
            selectedVoiceID = ""
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            discoverInstalledChatterboxIfNeeded()
            store = try DesktopSessionStore(databaseURL: directory.appendingPathComponent("sessions.sqlite"))
            audio = DesktopAudio(directory: directory)
            supertonic = DesktopSupertonicService(directory: directory)
            neural = DesktopNeuralSpeech()
            neural?.onError = { [weak self] error in
                if self?.selectedBackend == .chatterbox {
                    self?.chatterbox.abort()
                    if let worker = self?.chatterbox { Task { await worker.stop() } }
                }
                self?.isPlaying = false
                self?.isVoiceWaiting = false
                guard let self else { return }
                let suggestion = self.selectedBackend == .chatterbox
                    ? self.chatterboxFallbackSuggestion(after: error)
                    : "Choose another voice in Settings."
                self.message = "Voice playback failed: \(error.localizedDescription) \(suggestion)"
            }
            if selectedBackend != .mac && (!DesktopVoiceTerms.hasAccepted(selectedBackend, variant: selectedChatterboxModel) ||
                (selectedBackend == .chatterbox && !chatterboxReady)) {
                selectedBackend = .mac
            }
            try audio?.playback.configureSpeechSettings(
                voiceIdentifier: selectedVoiceID.isEmpty ? nil : selectedVoiceID,
                rate: AVSpeechUtteranceDefaultSpeechRate
            )
            if !UserDefaults.standard.bool(forKey: Self.startWithComposerKey) {
                session = try store?.recoverLatestSession()
            }
            if let session {
                try audio?.prepare(session.sourceText)
                chapterSummaries = chapterSummaryStore.load(itemID: session.item.id, sourceText: session.sourceText)
                message = "Recovered your last session. Press Listen when ready."
            }
            recentSessions = try store?.recentSessions() ?? []
        } catch { report(error) }
    }

    func receiveBrowserURL(_ url: URL) {
        if isRecording {
            pendingBrowserURL = url
            message = "Page queued. Finish your Margin to begin listening."
            return
        }
        guard let store, let audio,
              let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.spokenmargins.desktop") else {
            message = "Browser handoff is unavailable. Check the desktop app's App Group signing."
            return
        }
        let inbox = DesktopBrowserInbox(directory: group.appendingPathComponent("BrowserTextHandoffs", isDirectory: true))
        do {
            let id = try inbox.payloadID(from: url)
            let handoff = try inbox.load(id: id)
            let imported = try store.importBrowserPage(handoff)
            if session?.session.id != imported.session.id {
                if session != nil { try endCurrentSession() }
                session = imported
                try audio.prepare(imported.sourceText)
                chapterSummaries = chapterSummaryStore.load(itemID: imported.item.id, sourceText: imported.sourceText)
                togglePlayback()
            }
            try inbox.remove(id: id)
            recentSessions = try store.recentSessions()
        } catch { report(error) }
    }

    func openRecentSession(id: String) {
        guard !isBusy, !isRecording, let store, let audio else { return }
        guard session?.session.id != id else { return }
        do {
            let recovered = try store.loadSession(id: id)
            if session != nil { try endCurrentSession() }
            session = recovered
            try audio.prepare(recovered.sourceText)
            chapterSummaries = chapterSummaryStore.load(itemID: recovered.item.id, sourceText: recovered.sourceText)
            message = "Session ready. Press Listen to continue."
        } catch { report(error) }
    }

    func monitorPlayback() async {
        guard monitoring == nil else { return }
        // App-owned task intentionally survives dismissal of the menu-bar panel.
        monitoring = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard isPlaying, let audio else { return }
        do {
            if selectedBackend != .mac {
                guard let neural, let render = activeRenderFunction() else {
                    isPlaying = false
                    isVoiceWaiting = false
                    message = "The selected voice is unavailable. Choose another voice in Settings."
                    return
                }
                neural.tick(using: render)
                isVoiceWaiting = neural.isWaiting
                if neural.isTooSlow {
                    switch selectedBackend {
                    case .chatterbox where selectedChatterboxModel == .turbo:
                        voicePerformanceMessage = chatterboxVariantReady(.nano)
                            ? "Chatterbox Turbo is rendering slower than playback. Switch to Nano, Supertonic, or a Mac voice."
                            : "Chatterbox Turbo is rendering slower than playback. Nano setup is incomplete; use Supertonic or a Mac voice."
                    case .chatterbox:
                        voicePerformanceMessage = "Chatterbox Nano is rendering slower than playback. Try Supertonic or a Mac voice."
                    case .supertonic:
                        voicePerformanceMessage = "Supertonic is rendering slower than playback. Try a Mac voice."
                    case .mac:
                        voicePerformanceMessage = nil
                    }
                }
                if neural.isComplete {
                    try checkpoint(offset: session?.sourceText.count)
                    isPlaying = false
                    isVoiceWaiting = false
                    if selectedBackend == .chatterbox { Task { await chatterbox.stop() } }
                    message = "Finished listening. You can still add a Margin."
                } else {
                    try checkpoint()
                }
            } else if let targetID = audio.targetID, audio.playback.isPlaybackComplete(targetId: targetID) {
                try checkpoint(offset: session?.sourceText.count)
                isPlaying = false
                message = "Finished listening. You can still add a Margin."
            } else {
                try checkpoint()
            }
        } catch {
            try? audio.playback.pause()
            isPlaying = false
            report(error)
        }
    }

    private func checkpoint(offset: Int? = nil) throws {
        guard let store, let session else { return }
        let position = offset ?? (selectedBackend == .mac ? audio?.playback.currentCharOffset() : neural?.currentOffset) ?? session.currentOffset
        guard position != session.currentOffset else { return }
        self.session = try store.storePlaybackOffset(sessionID: session.session.id, charOffset: position)
    }

    func pasteAndListen() {
        guard !isBusy, !isRecording else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Copy some text first, then choose Paste & Listen."
            return
        }
        guard text.count <= 100_000 else {
            message = "Use up to 100,000 characters for a quick listening session."
            return
        }
        if session != nil {
            do { try endCurrentSession() }
            catch { report(error); return }
        }
        draft = text
        startDraft()
    }

    func startDraft() {
        guard !isBusy, session == nil, let store, let audio else { return }
        // Bound the quick-listen surface; book-length imports belong to the full app.
        guard draft.count <= 100_000 else { message = "Use up to 100,000 characters for a quick listening session."; return }
        do {
            let title = String(draft.split(whereSeparator: \.isNewline).first?.prefix(80) ?? "Pasted text")
            session = try store.loadOrCreateTextSession(title: title, text: draft)
            recentSessions = try store.recentSessions()
            chapterSummaries = [:]
            UserDefaults.standard.set(false, forKey: Self.startWithComposerKey)
            try audio.prepare(session!.sourceText)
            draft = ""
            togglePlayback()
        } catch { report(error) }
    }

    func togglePlayback() {
        guard !isBusy, !isRecording, let audio, let session else { return }
        do {
            if isPlaying {
                try checkpoint()
                if selectedBackend == .mac {
                    try audio.playback.pause()
                } else if selectedBackend == .chatterbox {
                    neural?.stop()
                    chatterbox.abort()
                    Task { await chatterbox.stop() }
                } else { neural?.pause() }
                isPlaying = false
                isVoiceWaiting = false
                message = "Paused."
            } else {
                let offset = session.currentOffset >= session.sourceText.count ? 0 : session.currentOffset
                try checkpoint(offset: offset)
                if selectedBackend == .mac {
                    try audio.play(from: offset, rate: rate)
                    isVoiceWaiting = false
                } else if let render = activeRenderFunction() {
                    neural?.play(text: session.sourceText, from: offset, rate: rate, render: render)
                    isVoiceWaiting = true
                } else {
                    message = "This voice is not ready. Open Settings to complete its setup."
                    return
                }
                isPlaying = true
                message = nil
            }
        } catch { isPlaying = false; report(error) }
    }

    func seek(toCharacterOffset requestedOffset: Int) {
        guard !isBusy, !isRecording, let session, let store, let audio else { return }
        let offset = max(0, min(requestedOffset, session.sourceText.count))
        do {
            if selectedBackend != .mac {
                if selectedBackend == .chatterbox { chatterbox.abort() }
                neural?.stop()
                isVoiceWaiting = false
                if isPlaying, offset < session.sourceText.count, let render = activeRenderFunction() {
                    neural?.play(text: session.sourceText, from: offset, rate: rate, render: render)
                } else if offset == session.sourceText.count {
                    isPlaying = false
                }
            } else if offset == session.sourceText.count {
                try audio.playback.stop()
                isPlaying = false
            } else if isPlaying {
                try audio.play(from: offset, rate: rate)
            } else {
                try audio.playback.stop()
            }
            self.session = try store.storePlaybackOffset(sessionID: session.session.id, charOffset: offset)
            message = nil
        } catch { isPlaying = false; report(error) }
    }

    func skipBackward() {
        guard let session else { return }
        do { try checkpoint() } catch { report(error); return }
        let offset = DesktopTextNavigation.previousSentence(before: currentOffset, in: session.sourceText)
        seek(toCharacterOffset: offset)
    }

    func skipForward() {
        guard let session else { return }
        do { try checkpoint() } catch { report(error); return }
        let offset = DesktopTextNavigation.nextSentence(after: currentOffset, in: session.sourceText)
        seek(toCharacterOffset: offset)
    }

    func updateRate() {
        UserDefaults.standard.set(rate, forKey: "desktopSpeechRate")
        neural?.updateRate(rate)
        do { try audio?.playback.setPlaybackRate(rate) } catch { report(error) }
    }

    func updateChapterSummaryPreference() {
        UserDefaults.standard.set(aiChapterSummariesEnabled, forKey: "desktopAIChapterSummariesEnabled")
    }

    func jumpToChapter(_ chapter: Chapter) {
        seek(toCharacterOffset: chapter.startChar)
    }

    func generateChapterSummaries() async {
        guard aiChapterSummariesEnabled, !isBusy, !isRecording, !isPlaying,
              let session, let map = session.listeningMap, !map.chapters.isEmpty else { return }
        if let reason = chapterSummaryAvailabilityMessage {
            message = reason
            return
        }
        isBusy = true
        isGeneratingChapterSummaries = true
        defer {
            isGeneratingChapterSummaries = false
            isBusy = false
        }
        var results = chapterSummaryStore.load(itemID: session.item.id, sourceText: session.sourceText)
        do {
            for (index, chapter) in map.chapters.enumerated() where results[chapter.id] == nil {
                try Task.checkCancellation()
                message = "Summarizing chapter \(index + 1) of \(map.chapters.count)…"
                results[chapter.id] = try await DesktopChapterSummarizer.summarize(
                    chapter: chapter, number: index + 1, sourceText: session.sourceText)
                try chapterSummaryStore.save(results, itemID: session.item.id, sourceText: session.sourceText)
                chapterSummaries = results
            }
            message = "Chapter summaries are ready."
        } catch {
            message = "Chapter summaries stopped: \(error.localizedDescription)"
        }
    }

    func activateBackend(_ backend: DesktopVoiceBackend) {
        guard DesktopVoiceTerms.hasAccepted(backend, variant: selectedChatterboxModel) else {
            message = "Read and accept the voice provider's terms in Settings first."
            return
        }
        guard backend != .supertonic || supertonicReady else {
            message = supertonicSetupError ?? "Supertonic assets are unavailable."
            return
        }
        guard backend != .supertonic || supertonicSupportsLanguage else {
            message = "Supertonic does not support the selected language. Choose another language or a Mac voice."
            return
        }
        guard backend != .chatterbox || chatterboxReady else {
            message = chatterboxSetupError ?? "Finish Chatterbox setup in Settings first."
            return
        }
        guard backend != .chatterbox || selectedLanguage == "en" else {
            message = "Chatterbox Nano and Turbo in this settings screen support English. Choose English or another voice."
            return
        }
        if isPlaying {
            try? checkpoint()
            if selectedBackend == .mac { try? audio?.playback.pause() } else { neural?.stop() }
            isPlaying = false
        }
        if selectedBackend == .chatterbox && backend != .chatterbox {
            chatterbox.abort()
            Task { await chatterbox.stop() }
        }
        selectedBackend = backend
        isVoiceWaiting = false
        voiceRenderStatus = nil
        UserDefaults.standard.set(backend.rawValue, forKey: "desktopVoiceBackend")
        voicePerformanceMessage = nil
        message = "\(backend.title) selected. Press Play to continue."
    }

    func updateSupertonicVoice() {
        UserDefaults.standard.set(selectedSupertonicVoice.rawValue, forKey: "desktopSupertonicVoice")
        if selectedBackend == .supertonic && isPlaying {
            try? checkpoint()
            neural?.stop()
            isPlaying = false
            isVoiceWaiting = false
            message = "Voice changed. Press Play to continue at this position."
        }
    }

    func testSupertonic() async {
        guard supertonicSupportsLanguage else {
            message = "Supertonic does not support the selected language."
            return
        }
        guard DesktopVoiceTerms.hasAccepted(.supertonic), let render = supertonic?.renderFunction(
            voice: selectedSupertonicVoice, language: selectedLanguage) else {
            message = "Accept Supertonic's terms before testing its voice."
            return
        }
        guard !isBusy, !isRecording, !isPlaying else {
            message = "Pause playback before testing a voice."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let sample = try await render("This is a short Supertonic voice test.")
            try playVoiceTest(at: sample.url)
            message = "Playing a Supertonic sample."
        } catch { report(error) }
    }

    func updateChatterboxSetup() {
        if selectedBackend == .chatterbox && isPlaying {
            try? checkpoint()
            neural?.stop()
            isPlaying = false
            isVoiceWaiting = false
            message = "Chatterbox setup changed. Press Play to continue at this position."
        }
        UserDefaults.standard.set(chatterboxPythonPath, forKey: "desktopChatterboxPythonPath")
        UserDefaults.standard.set(chatterboxModelPath, forKey: "desktopChatterboxModelPath")
        UserDefaults.standard.set(selectedChatterboxModel.rawValue, forKey: "desktopChatterboxModel")
        chatterbox.abort()
        voiceRenderStatus = nil
        if selectedBackend == .chatterbox &&
            (!chatterboxReady || !DesktopVoiceTerms.hasAccepted(.chatterbox, variant: selectedChatterboxModel)) {
            activateBackend(.mac)
        }
    }

    func testChatterbox() async {
        guard selectedLanguage == "en" else {
            message = "Chatterbox Nano and Turbo in this settings screen support English."
            return
        }
        guard DesktopVoiceTerms.hasAccepted(.chatterbox, variant: selectedChatterboxModel) else {
            message = "Accept Chatterbox's terms before testing its voice."
            return
        }
        guard !isBusy, !isRecording, !isPlaying else {
            message = "Pause playback before testing a voice."
            return
        }
        isBusy = true
        voicePerformanceMessage = nil
        voiceRenderStatus = "Chatterbox \(selectedChatterboxModel.shortTitle) is loading…"
        defer {
            isBusy = false
            voiceRenderStatus = nil
        }
        do {
            let sample = try await chatterbox.render("Chatterbox voice test.",
                                                     configuration: chatterboxConfiguration(),
                                                     onProgress: chatterboxProgressHandler(for: selectedChatterboxModel))
            await chatterbox.stop()
            try playVoiceTest(at: sample.url)
            message = "Playing a Chatterbox \(selectedChatterboxModel.rawValue) sample."
        } catch {
            await chatterbox.stop()
            message = "Chatterbox test failed: \(error.localizedDescription) \(chatterboxFallbackSuggestion(after: error))"
        }
    }

    private func chatterboxFallbackSuggestion(after error: Error) -> String {
        if let failure = error as? ChatterboxFailure,
           case .resourceMonitoringUnavailable = failure {
            return "Chatterbox is disabled until memory and swap monitoring works. Use Supertonic or a Mac voice."
        }
        let reason = error.localizedDescription.lowercased()
        let monitoringAvailable = !reason.contains("could not be monitored")
        if !monitoringAvailable {
            return "Chatterbox is disabled until memory and swap monitoring works. Use Supertonic or a Mac voice."
        }
        if ChatterboxResourcePolicy.shouldSuggestNano(model: selectedChatterboxModel, stopReason: reason) {
            return chatterboxVariantReady(.nano)
                ? "Switch to Chatterbox Nano, or use Supertonic or a Mac voice."
                : "Nano setup needs its checkpoint and a compatible Python runtime. Use Supertonic or a Mac voice, or finish Nano setup in Settings."
        }
        return "Use Supertonic or a Mac voice."
    }

    private func chatterboxConfiguration(variant: DesktopChatterboxModel? = nil) -> ChatterboxConfiguration {
        ChatterboxConfiguration(
            variant: variant ?? selectedChatterboxModel,
            pythonURL: URL(fileURLWithPath: chatterboxPythonPath),
            modelURL: URL(fileURLWithPath: chatterboxModelPath),
            helperURL: Bundle.main.resourceURL!.appendingPathComponent("chatterbox_worker.py"),
            outputDirectory: directory.appendingPathComponent("GeneratedSpeech", isDirectory: true))
    }

    private func discoverInstalledChatterboxIfNeeded() {
        guard chatterboxPythonPath.isEmpty, chatterboxModelPath.isEmpty else { return }
        let starter = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/studio.narrate.local/starter", isDirectory: true)
        guard let kits = try? FileManager.default.contentsOfDirectory(
            at: starter, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for kit in kits.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            where kit.lastPathComponent.contains("chatterbox-turbo") {
            let python = kit.appendingPathComponent("runtime/bin/python")
            let model = kit.appendingPathComponent("model", isDirectory: true)
            guard FileManager.default.isExecutableFile(atPath: python.path),
                  FileManager.default.fileExists(atPath: model.appendingPathComponent("t3_turbo_v1.safetensors").path) else {
                continue
            }
            chatterboxPythonPath = python.path
            chatterboxModelPath = model.path
            break
        }
    }

    private func playVoiceTest(at url: URL) throws {
        voiceTestPlayer?.stop()
        if let voiceTestURL { try? FileManager.default.removeItem(at: voiceTestURL) }
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.prepareToPlay(), player.play() else { throw DesktopNeuralFailure.invalidAudio }
        voiceTestPlayer = player
        voiceTestURL = url
    }

    private func activeRenderFunction() -> DesktopRenderFunction? {
        switch selectedBackend {
        case .mac: return nil
        case .supertonic:
            return supertonic?.renderFunction(voice: selectedSupertonicVoice, language: selectedLanguage)
        case .chatterbox:
            guard chatterboxReady else { return nil }
            let configuration = chatterboxConfiguration()
            let variant = selectedChatterboxModel
            let progress = chatterboxProgressHandler(for: variant)
            return { [chatterbox, weak self, progress] text in
                do {
                    let result = try await chatterbox.render(
                        text, configuration: configuration, onProgress: progress)
                    await MainActor.run { self?.voiceRenderStatus = nil }
                    return result
                } catch {
                    await MainActor.run { self?.voiceRenderStatus = nil }
                    throw error
                }
            }
        }
    }

    private func chatterboxProgressHandler(for variant: DesktopChatterboxModel) -> ChatterboxProgressHandler {
        let modelName = "Chatterbox \(variant.shortTitle)"
        return { [weak self] phase, fraction in
            let status: String
            if let fraction {
                status = "\(modelName) \(phase.lowercased()) (\(Int((fraction * 100).rounded()))%)…"
            } else {
                status = "\(modelName) \(phase.lowercased())…"
            }
            Task { @MainActor [weak self] in self?.voiceRenderStatus = status }
        }
    }

    func updateLanguage() {
        UserDefaults.standard.set(selectedLanguage, forKey: "desktopVoiceLanguage")
        if selectedBackend == .supertonic && !supertonicSupportsLanguage ||
           selectedBackend == .chatterbox && selectedLanguage != "en" {
            activateBackend(.mac)
        }
        if !filteredVoiceOptions.contains(where: { $0.id == selectedVoiceID }) {
            selectedVoiceID = filteredVoiceOptions.first?.id ?? ""
            updateVoice()
        }
    }

    func updateVoice() {
        UserDefaults.standard.set(selectedVoiceID, forKey: "desktopVoiceID")
        do {
            try audio?.playback.configureSpeechSettings(
                voiceIdentifier: selectedVoiceID.isEmpty ? nil : selectedVoiceID,
                rate: Float(rate)
            )
            if isPlaying && selectedBackend == .mac {
                try checkpoint()
                try audio?.play(from: session?.currentOffset ?? 0, rate: rate)
            }
        } catch { report(error) }
    }

    func toggleRecording() async {
        guard let audio, let store, let session else { return }
        if isRecording {
            do {
                let path = try audio.recorder.finishRecording(audioRef: nil)
                isRecording = false
                recordingTimeout?.cancel()
                recordingTimeout = nil
                recordingControl.hide()
                guard let anchor = recordingAnchor else { throw DesktopFailure.missingAnchor }
                let margin = try store.addMargin(sessionID: session.session.id, anchor: anchor, captureKind: .audio, audioPath: path)
                self.session = try store.loadSession(id: session.session.id)
                recordingAnchor = nil
                resumeSourceIfNeeded()
                Task { await transcribe(marginID: margin.id, path: path, sessionID: session.session.id) }
                if let pendingBrowserURL {
                    self.pendingBrowserURL = nil
                    receiveBrowserURL(pendingBrowserURL)
                }
            } catch {
                isRecording = false
                recordingTimeout?.cancel()
                recordingTimeout = nil
                recordingControl.hide()
                isBusy = false
                report(error)
                message = "Recording could not be saved as a Margin. Check Show Files for the audio. " + (message ?? "")
            }
            return
        }
        guard !isBusy else { return }
        isBusy = true
        resumeAfterRecording = isPlaying
        do {
            try checkpoint()
            if isPlaying {
                if selectedBackend == .mac {
                    try audio.playback.pause()
                } else if selectedBackend == .chatterbox {
                    neural?.stop()
                    chatterbox.abort()
                    Task { await chatterbox.stop() }
                } else { neural?.pause() }
            }
            isPlaying = false
            recordingAnchor = try store.sourceAnchor(sessionID: session.session.id, charOffset: self.session?.currentOffset ?? 0)
            recordingAnchor?.playbackRateObserved = rate
            guard await audio.requestMicrophone() else {
                isBusy = false
                message = "Microphone access is off. Enable Spoken Margins Desktop in System Settings → Privacy & Security → Microphone."
                return
            }
            try audio.recorder.beginRecording()
            isRecording = true
            isBusy = false
            recordingControl.show(model: self)
            recordingTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled, let self, self.isRecording else { return }
                await self.toggleRecording()
            }
            message = "Recording your Margin… Press Finish Margin to save and resume."
        } catch { isBusy = false; report(error) }
    }

    func saveWrittenMargin(_ text: String) -> Bool {
        guard !isBusy, !isRecording, let store, let session else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 10_000 else {
            message = "Write a Margin of up to 10,000 characters."
            return false
        }
        do {
            try checkpoint()
            let offset = self.session?.currentOffset ?? session.currentOffset
            let anchor = try store.sourceAnchor(sessionID: session.session.id, charOffset: offset)
            _ = try store.addMargin(sessionID: session.session.id, anchor: anchor,
                                    transcript: normalized, captureKind: .written)
            self.session = try store.loadSession(id: session.session.id)
            message = "Written Margin saved."
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func resumeSourceIfNeeded() {
        guard resumeAfterRecording, let session, session.currentOffset < session.sourceText.count else { return }
        do {
            let offset = max(0, session.currentOffset - 60)
            if selectedBackend == .mac {
                try audio?.play(from: offset, rate: rate)
            } else if let render = activeRenderFunction() {
                neural?.play(text: session.sourceText, from: offset, rate: rate, render: render)
            } else { return }
            isPlaying = true
        } catch { isPlaying = false; report(error) }
        resumeAfterRecording = false
    }

    private func transcribe(marginID: String, path: String, sessionID: String, overwrite: Bool = false) async {
        guard let audio, let store, transcribingMarginIDs.insert(marginID).inserted else { return }
        message = "Audio saved. Transcribing your Margin…"
        defer { transcribingMarginIDs.remove(marginID) }
        do {
            let text = try await audio.transcriber.transcribe(audioPath: path)
            let current = try store.loadSession(id: sessionID)
            if overwrite || current.margins.first(where: { $0.id == marginID })?.transcriptionStatus != "transcribed" {
                _ = try store.updateMarginTranscript(sessionID: sessionID, marginID: marginID, transcript: text)
            }
            if session?.session.id == sessionID {
                self.session = try store.loadSession(id: sessionID)
                message = "Margin saved. Review the transcript, then copy your output."
            }
        } catch {
            if session?.session.id == sessionID {
                message = "Audio is saved. Transcription failed; retry or type the Margin yourself. \(error.localizedDescription)"
            }
        }
    }

    func retryTranscript(id: String) async {
        guard !isBusy, let session, let margin = session.margins.first(where: { $0.id == id }), let path = margin.audioPath else { return }
        await transcribe(marginID: id, path: path, sessionID: session.session.id, overwrite: true)
    }

    func editMargin(id: String, text: String) {
        guard !isBusy, let store, let session else { return }
        do {
            _ = try store.updateMarginTranscript(sessionID: session.session.id, marginID: id, transcript: text)
            self.session = try store.loadSession(id: session.session.id)
            message = "Edit saved."
        } catch { report(error) }
    }

    func copyOutput() {
        guard !isBusy, let store, let session else { return }
        do {
            let output = try store.exportMarkdown(sessionID: session.session.id)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(output, forType: .string) else { throw DesktopFailure.clipboard }
            message = "Copied Margins and source context. Paste into your editor or AI chat."
        } catch { report(error) }
    }

    func newText() {
        guard !isBusy, !isRecording else { return }
        do { try endCurrentSession(); draft = "" }
        catch { report(error) }
    }

    private func endCurrentSession() throws {
        try checkpoint()
        try archiveCurrentOutput()
        try audio?.playback.stop()
        neural?.stop()
        chatterbox.abort()
        Task { await chatterbox.stop() }
        isPlaying = false
        isVoiceWaiting = false
        session = nil
        chapterSummaries = [:]
        UserDefaults.standard.set(true, forKey: Self.startWithComposerKey)
        message = nil
    }

    private func archiveCurrentOutput() throws {
        guard let store, let session else { return }
        let exports = directory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try store.exportMarkdown(sessionID: session.session.id).write(
            to: exports.appendingPathComponent(session.session.id + ".md"), atomically: true, encoding: .utf8)
    }

    func showFiles() { NSWorkspace.shared.open(directory) }

    func prepareToQuit() -> Bool {
        do {
            if isRecording, let audio {
                let path = try audio.recorder.finishRecording(audioRef: nil)
                isRecording = false
                recordingTimeout?.cancel()
                recordingTimeout = nil
                recordingControl.hide()
                if let store, let session, let recordingAnchor {
                    _ = try store.addMargin(sessionID: session.session.id, anchor: recordingAnchor,
                                            captureKind: .audio, audioPath: path)
                }
            }
            try checkpoint()
            try audio?.playback.stop()
            neural?.stop()
            chatterbox.abort()
            voiceTestPlayer?.stop()
            if let voiceTestURL { try? FileManager.default.removeItem(at: voiceTestURL) }
            return true
        }
        catch { report(error); return false }
    }

    private func report(_ error: Error) { message = error.localizedDescription }
}

private enum DesktopFailure: LocalizedError {
    case missingAnchor, clipboard
    var errorDescription: String? {
        switch self {
        case .missingAnchor: "The source position could not be recovered."
        case .clipboard: "The clipboard could not be updated."
        }
    }
}
