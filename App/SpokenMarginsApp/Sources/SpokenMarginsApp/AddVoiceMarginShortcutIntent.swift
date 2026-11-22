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
        inspect: @escaping @Sendable (URL) -> VoiceMarginImport.Inspection? = VoiceMarginFiles.defaultInspect, now: Date = Date()
    ) async throws -> String {
        try await perform(
            audio: source, toItemId: itemId, picture: nil, in: model, files: files, supportDirectory: supportDirectory,
            inspect: inspect, now: now
        ).name
    }

    /// The same with an optional screenshot or photo (#4925): kept with the Margin only when it goes to a live or quick
    /// session, as for Add Margin; for a Library item the Margin is saved without it and the result says so.
    static func perform(
        audio source: URL, toItemId itemId: String?, picture: ShortcutPicture?, in model: Gate1AppModel,
        files: LiveSessionFileWorker = .shared, supportDirectory: URL? = nil,
        inspect: @escaping @Sendable (URL) -> VoiceMarginImport.Inspection? = VoiceMarginFiles.defaultInspect, now: Date = Date()
    ) async throws -> ShortcutMarginFiled {
        let support = try supportDirectory ?? VoiceMarginFiles.supportDirectory()
        let prepared: VoiceMarginImport.Prepared
        do {
            prepared = try await VoiceMarginFiles.prepare(source: source, support: support, inspect: inspect)
        } catch let refusal as VoiceMarginImport.Refusal {
            throw AddMarginShortcutError.voiceRefused(refusal)
        }
        let path = prepared.audioPath // the listener's own recording, kept by `VoiceMarginImport`
        do {
            return try await file(prepared, path: path, toItemId: itemId, picture: picture, in: model, files: files, now: now)
        } catch {
            // Removed only when no saved Margin names it, whatever step failed: a save that stored the Margin and then
            // reported a failure keeps its voice. A doubt keeps the recording. Never the Shortcut's own file.
            let sessions = await files.allSessions()
            let named = VoiceMarginImport.liveSession(naming: path, in: sessions) != nil
                || model.voiceMarginIsNamed(path)
            await VoiceMarginFiles.discard(prepared, support: support, isNamed: named)
            throw error
        }
    }

    /// Where the recording goes, once it is the app's own. Returns what Siri says it went to.
    private static func file(
        _ prepared: VoiceMarginImport.Prepared, path: String, toItemId itemId: String?, picture: ShortcutPicture?,
        in model: Gate1AppModel, files: LiveSessionFileWorker, now: Date
    ) async throws -> ShortcutMarginFiled {
        let onItemOutcome: SiriMarginRoute.PictureOutcome = picture == nil ? .noneGiven : .notKeptOnItem
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
        func fileInSession(marginId: String, _ filed: LiveSession?) async throws -> LiveSession {
            // A save that reports a failure after the Margin was stored (its second file) still saved it.
            let stored = await files.allSessions()
            guard let filed = filed ?? VoiceMarginImport.liveSession(naming: path, in: stored) else {
                throw AddMarginShortcutError.notSaved(nil)
            }
            announce()
            // Words come off the main actor and never hold the Shortcut up; one that doesn't finish here is caught up
            // from the saved Margin (`LiveSessionSpokenMargins.transcribeMissing`).
            Task {
                guard let text = await LiveSessionSpokenMargins.transcribe(audioPath: path) else { return }
                await LiveSessionSpokenMargins.updateStored(in: files, marginId: marginId) { $0.setTranscript(text, forMarginId: marginId) }
            }
            return filed
        }
        func fileAsQuick() async throws -> ShortcutMarginFiled {
            let marginId = "phone-\(UUID().uuidString.lowercased())"
            let (staged, pictureOutcome) = await ShortcutPictureIntake.prepare(picture)
            var outcome = pictureOutcome
            let filed: LiveSession?
            if let staged {
                let filing = await files.fileSpokenMarginAsQuick(
                    marginId: marginId, audioPath: path, markedAt: now, durationMs: prepared.durationMs,
                    spokenOn: "phone", now: now, staged: staged
                )
                filed = filing.session
                outcome = ShortcutPictureIntake.outcome(of: filing)
            } else {
                filed = await files.fileSpokenMarginAsQuick(
                    marginId: marginId, audioPath: path, markedAt: now, durationMs: prepared.durationMs,
                    spokenOn: "phone", now: now
                )
            }
            let session = try await fileInSession(marginId: marginId, filed)
            return ShortcutMarginFiled(name: SiriMarginRoute.filedName(session), picture: outcome)
        }
        switch route {
        case .chosenItem:
            guard let itemId else { throw AddMarginShortcutError.itemNotFound }
            // The item in the player is the player's case, as for Add Margin's words (`addWrittenMargin(text:toItemId:in:)`).
            if model.hasActiveSession, model.snapshot.itemId == itemId {
                return ShortcutMarginFiled(name: try model.addVoiceMarginToPlayer(audioPath: path), picture: onItemOutcome)
            }
            guard model.store != nil else { throw AddMarginShortcutError.libraryUnavailable }
            do {
                return ShortcutMarginFiled(name: try model.addVoiceMarginToStoredItem(id: itemId, audioPath: path), picture: onItemOutcome)
            } catch let failure as StoredSessionMargin.Failure {
                throw AddMarginShortcutError(failure)
            } catch {
                throw AddMarginShortcutError.notSaved(ListenerErrorText.message(for: error))
            }
        case .playerItem:
            do {
                return ShortcutMarginFiled(name: try model.addVoiceMarginToPlayer(audioPath: path), picture: onItemOutcome)
            } catch AddMarginShortcutError.nothingRunning {
                // The player's session ended between the decision and the save: the Margin is kept, not refused.
                return try await fileAsQuick()
            }
        case let .liveSession(name):
            guard let running = await files.runningSession() else { return try await fileAsQuick() }
            let marginId = "phone-\(UUID().uuidString.lowercased())"
            let (staged, pictureOutcome) = await ShortcutPictureIntake.prepare(picture)
            var outcome = pictureOutcome
            let filed: LiveSession?
            if let staged {
                let filing = await files.attachSpokenMargin(
                    sessionId: running.id, marginId: marginId, audioPath: path, markedAt: now,
                    durationMs: prepared.durationMs, spokenOn: "phone", staged: staged
                )
                filed = filing.session
                outcome = ShortcutPictureIntake.outcome(of: filing)
            } else {
                filed = await files.attachSpokenMargin(
                    sessionId: running.id, marginId: marginId, audioPath: path, markedAt: now,
                    durationMs: prepared.durationMs, spokenOn: "phone"
                )
            }
            _ = try await fileInSession(marginId: marginId, filed)
            return ShortcutMarginFiled(name: name, picture: outcome)
        case .quickSession:
            return try await fileAsQuick()
        }
    }
}

/// The file work of Add Voice Margin, off the main actor: measuring and copying a long recording (about 100 MB at ten
/// minutes, uncompressed), removing a copy no Margin names, and holding a Shortcut's bytes in a temporary file.
enum VoiceMarginFiles {
    static let defaultInspect: @Sendable (URL) -> VoiceMarginImport.Inspection? = { AudioFileLength.inspect($0) }

    static func supportDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    static func prepare(
        source: URL, support: URL, inspect: @escaping @Sendable (URL) -> VoiceMarginImport.Inspection?
    ) async throws -> VoiceMarginImport.Prepared {
        try VoiceMarginImport.prepare(source: source, supportDirectory: support, inspect: inspect)
    }

    static func discard(_ prepared: VoiceMarginImport.Prepared, support: URL, isNamed: Bool) async {
        VoiceMarginImport.discardUnlessNamed(prepared, supportDirectory: support, isNamed: { isNamed })
    }

    /// The file a Shortcut passed, readable at `url` until `remove()`. A file the Shortcut holds by address is read in
    /// place, with the access it granted (`remove` lets go of that access); one that came as bytes is written to a
    /// temporary file, which `remove` deletes. Neither ever touches the Shortcut's own file.
    struct Staged: Sendable {
        let url: URL
        let remove: @Sendable () -> Void
    }

    static func stage(_ file: IntentFile) async throws -> Staged {
        if let url = file.fileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            return Staged(url: url) { if scoped { url.stopAccessingSecurityScopedResource() } }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "add-voice-margin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = (file.filename as NSString).lastPathComponent
        let url = directory.appending(path: name.isEmpty ? "recording.m4a" : name)
        do {
            try file.data.write(to: url)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return Staged(url: url) { try? FileManager.default.removeItem(at: directory) }
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

    /// Optional, as on Add Margin (#4925): a screenshot or photo kept with the Margin on this phone when it goes to a
    /// live session or a quick session; the answer says when it was not kept.
    @Parameter(
        title: "Screenshot or photo",
        description: "A picture to keep with the Margin on this phone, such as the page you are reading. Kept only when the Margin goes into a live session or a quick session; for something chosen from your Library it is not kept, and the answer says so.",
        supportedContentTypes: [.image]
    )
    var picture: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("Add Voice Margin \(\.$audio) to what's playing") { \.$item; \.$picture }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The same weak reference the other Margin actions use; the app sets it at launch.
        guard let model = ListeningEditionShortcutBridge.model else {
            throw AddMarginShortcutError.libraryUnavailable
        }
        let itemId = item?.id
        let staged = try await VoiceMarginFiles.stage(audio)
        defer { staged.remove() }
        let filed = try await AddVoiceMarginAction.perform(
            audio: staged.url, toItemId: itemId, picture: picture.map(ShortcutPicture.init(file:)), in: model
        )
        return .result(dialog: IntentDialog(stringLiteral: filed.dialogLine))
    }
}
#endif
