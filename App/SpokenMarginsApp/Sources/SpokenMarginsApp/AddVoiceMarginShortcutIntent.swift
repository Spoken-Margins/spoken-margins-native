#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation
import SessionKit
import SessionKitAudio
import UniformTypeIdentifiers

/// Saves a recording a Shortcut hands over as a spoken Margin (#4924), by the route Add Margin takes for words
/// (`SiriMarginRoute`, #3880): a Library item chosen in the Shortcut, else the running live session, else the item in the
/// player, else a quick session in the Library. The recording is copied into the app's own recordings first
/// (`VoiceMarginImport`), so the Shortcut deleting its file never reaches the Margin, and the copy is removed again when
/// no Margin ended up naming it. Nothing is uploaded: the words are written by the device's own transcription.
@MainActor
enum AddVoiceMarginAction {
    static func perform(
        audio source: URL, toItemId itemId: String?, in model: Gate1AppModel,
        files: LiveSessionFileWorker = .shared, supportDirectory: URL? = nil,
        durationMs: @escaping @Sendable (URL) -> Int? = AudioFileLength.milliseconds(of:), now: Date = Date()
    ) async throws -> String {
        let support = try supportDirectory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let prepared: VoiceMarginImport.Prepared
        do {
            // Measuring and copying a long recording (about 100 MB at ten minutes, uncompressed) stays off the main actor.
            prepared = try await Task.detached(priority: .userInitiated) {
                try VoiceMarginImport.prepare(source: source, supportDirectory: support, durationMs: durationMs)
            }.value
        } catch let refusal as VoiceMarginImport.Refusal {
            throw AddMarginShortcutError.voiceRefused(refusal)
        }
        var kept = false
        defer { if !kept { VoiceMarginImport.discard(prepared, supportDirectory: support) } }
        let name = try await file(prepared, toItemId: itemId, in: model, files: files, now: now)
        kept = true
        return name
    }

    /// Where the recording goes, once it is the app's own. Returns what Siri says it went to.
    private static func file(
        _ prepared: VoiceMarginImport.Prepared, toItemId itemId: String?, in model: Gate1AppModel,
        files: LiveSessionFileWorker, now: Date
    ) async throws -> String {
        let path = prepared.audioPath // the listener's own recording, kept by `VoiceMarginImport`
        let route = SiriMarginRoute.decide(.init(
            choseItem: itemId != nil, // as Add Margin: a chosen item comes first, even over a running live session
            runningSession: await files.runningSession(),
            playerHasSession: model.hasActiveSession
        ))
        func announce() {
            // The open session screen takes it in, the Library's Live row and the Watch's board redraw.
            NotificationCenter.default.post(name: LiveSessionSpokenMargins.changedOnDisk, object: nil)
            LiveSessionBoard.shared.refresh()
            WatchMarginReceiver.shared.processInbox()
        }
        /// A spoken Margin filed into a live or quick session, with its words asked for afterwards.
        func fileInSession(marginId: String, _ filed: LiveSession?) throws -> LiveSession {
            guard let filed else { throw AddMarginShortcutError.notSaved(nil) }
            announce()
            // Words come off the main actor and never hold the Shortcut up; one that doesn't finish here is caught up
            // from the saved Margin (`LiveSessionSpokenMargins.transcribeMissing`).
            Task {
                guard let text = await LiveSessionSpokenMargins.transcribe(audioPath: path) else { return }
                await LiveSessionSpokenMargins.updateStored(in: files, marginId: marginId) { $0.setTranscript(text, forMarginId: marginId) }
            }
            return filed
        }
        func fileAsQuick() async throws -> String {
            let marginId = "phone-\(UUID().uuidString.lowercased())"
            let filed = await files.fileSpokenMarginAsQuick(
                marginId: marginId, audioPath: path, markedAt: now, durationMs: prepared.durationMs,
                spokenOn: "phone", now: now
            )
            return SiriMarginRoute.filedName(try fileInSession(marginId: marginId, filed))
        }
        switch route {
        case .chosenItem:
            guard let itemId else { throw AddMarginShortcutError.itemNotFound }
            // The item in the player is the player's case, as for Add Margin's words (`addWrittenMargin(text:toItemId:in:)`).
            if model.hasActiveSession, model.snapshot.itemId == itemId {
                return try model.addVoiceMarginToPlayer(audioPath: path)
            }
            guard model.store != nil else { throw AddMarginShortcutError.libraryUnavailable }
            do {
                return try model.addVoiceMarginToStoredItem(id: itemId, audioPath: path)
            } catch let failure as StoredSessionMargin.Failure {
                throw AddMarginShortcutError(failure)
            } catch {
                throw AddMarginShortcutError.notSaved(ListenerErrorText.message(for: error))
            }
        case .playerItem:
            do {
                return try model.addVoiceMarginToPlayer(audioPath: path)
            } catch AddMarginShortcutError.nothingRunning {
                // The player's session ended between the decision and the save: the Margin is kept, not refused.
                return try await fileAsQuick()
            }
        case let .liveSession(name):
            guard let running = await files.runningSession() else { return try await fileAsQuick() }
            let marginId = "phone-\(UUID().uuidString.lowercased())"
            let filed = await files.attachSpokenMargin(
                sessionId: running.id, marginId: marginId, audioPath: path, markedAt: now,
                durationMs: prepared.durationMs, spokenOn: "phone"
            )
            _ = try fileInSession(marginId: marginId, filed)
            return name
        case .quickSession:
            return try await fileAsQuick()
        }
    }
}

/// Opens the file a Shortcut passed for as long as `body` runs. A file the Shortcut holds by address is read in place,
/// with the access it granted; one that came as bytes is written to a temporary file first, removed afterwards.
@MainActor
enum AddVoiceMarginFile {
    static func withURL<T>(of file: IntentFile, _ body: (URL) async throws -> T) async throws -> T {
        if let url = file.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try await body(url)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "add-voice-margin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = (file.filename as NSString).lastPathComponent
        let url = directory.appending(path: name.isEmpty ? "recording.m4a" : name)
        try file.data.write(to: url)
        return try await body(url)
    }
}

/// "Add Voice Margin": a recording from Record Audio, a Voice Memo or any audio file becomes a spoken Margin without
/// opening the app (#4924). Add Margin keeps its required text, so Siri's "What should the Margin say?" is unchanged.
/// There is no Siri phrase: a file can't be spoken, so this is a Shortcuts action.
struct AddVoiceMarginToSpokenMarginsIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Voice Margin"
    static let description = IntentDescription(
        "Saves a recording as a spoken Margin in Spoken Margins, without opening the app: into your running live session if there is one, else on whatever is playing, at the current place, and playback carries on; with neither, into a quick session in your Library. Choose something else from your Library to add it there instead, at the place where you left it. The recording is kept on this device and written out on this device. Recordings over 10 minutes are refused."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Recording",
        description: "The audio to keep as the Margin's voice: from Record Audio, a Voice Memo or any audio file.",
        supportedContentTypes: [.audio]
    )
    var audio: IntentFile

    @Parameter(
        title: "Source",
        description: "The episode, article or PDF to add it to, at the place where you left it. Leave empty to add it to what's playing."
    )
    var item: LibraryItemEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add Voice Margin \(\.$audio) to what's playing") { \.$item }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The same weak reference the other Margin actions use; the app sets it at launch.
        guard let model = ListeningEditionShortcutBridge.model else {
            throw AddMarginShortcutError.libraryUnavailable
        }
        let itemId = item?.id
        let name = try await AddVoiceMarginFile.withURL(of: audio) { url in
            try await AddVoiceMarginAction.perform(audio: url, toItemId: itemId, in: model)
        }
        return .result(dialog: IntentDialog(stringLiteral: SiriMarginRoute.confirmation(named: name)))
    }
}
#endif
