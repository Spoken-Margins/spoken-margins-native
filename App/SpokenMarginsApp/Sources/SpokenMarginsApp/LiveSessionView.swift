import SessionKit
import SwiftUI

/// Live session (#1989, #2481, prototype): Margins on a clock while a meeting, an audiobook in another app or
/// a paper book goes on outside Spoken Margins. Nothing is recorded. Afterwards a meeting lines up with its
/// transcript (and recording, if the listener has it); anything else is saved as session notes.
///
/// The running state is the playback screen's layout (#3491): a Margins pane and a Session pane, and a dock with
/// the pane switch, the clock with End, and Add a Margin with the pencil. Add a Margin opens the normal recording
/// screen and the pencil the normal writing sheet; neither is a control that changes shape on this screen.
///
/// It does not watch `Gate1AppModel` (#4091). Watching it reran this whole screen on every model publish while an item
/// was loaded in the mini player, the same whole-screen redraw that once closed this screen's menus and sheets (#2831).
/// That is the likely cause, read from the code and not yet reproduced on a device, of a listener on an ended session
/// seeing the screen flash and being unable to tap Discard Session. It reads what it shows from the model through a
/// `ScreenInputsFeed`, and presenters show it with `.equatable()`, so a presenter that redraws on every publish (the
/// Library, the root) stops here too.
struct LiveSessionView: View, Equatable {
    let model: Gate1AppModel
    private let sessionId: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: LiveSessionController
    @StateObject private var feed: ScreenInputsFeed<ModelInputs>
    @ObservedObject private var links = LiveSessionLinkRouter.shared
    @ObservedObject private var capture = LiveSessionSpokenCapture.shared

    /// `sessionId` opens that session (from the Library's Live row); nil opens the running one, or the setup card.
    init(model: Gate1AppModel, sessionId: String? = nil) {
        self.model = model
        self.sessionId = sessionId
        _controller = StateObject(wrappedValue: LiveSessionController(sessionId: sessionId))
        _feed = StateObject(wrappedValue: ScreenInputsFeed(model: model, read: ModelInputs.init))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        #if DEBUG
        ScreenRedrawProbe.recordEqualityCheck("liveSession")
        #endif
        return lhs.model === rhs.model && lhs.sessionId == rhs.sessionId
    }

    /// Everything this screen's body shows from the model. Buttons still read the model when they run.
    struct ModelInputs: Equatable {
        var showsMiniPlayer: Bool
        var recordingNavigationIsLocked: Bool

        @MainActor init(_ model: Gate1AppModel) {
            showsMiniPlayer = model.shouldShowMiniPlayer
            recordingNavigationIsLocked = model.recordingNavigationIsLocked
        }
    }

    /// The full-screen screens this screen opens. One cover, so two can never stack.
    private enum Cover: String, Identifiable {
        case liveRecording, liveWriting, camera
        var id: String { rawValue }
    }

    private struct MarginTarget: Identifiable { let id: String }

    // Setup
    @State private var kind: ElsewhereKind = .meeting
    @State private var title = ""
    @State private var startPosition = ""
    @State private var startWhere = ""
    // Running
    @State private var pane: LiveSessionPane = .margins
    @State private var cover: Cover?
    /// When the pencil was tapped: the Margin is placed at that moment, not at the moment Save is tapped.
    @State private var writingStartedAt = Date()
    @State private var openMargin: MarginTarget?
    /// Set by a Live Activity tap once the screen has presented; the change handler opens the writing sheet.
    @State private var wantsWrite = false
    // Photo Margins (#2708)
    /// Photo was tapped and the camera, or the fitting of its picture, is not done yet: a second tap does nothing.
    @State private var isTakingPhoto = false
    /// The moment Photo was tapped. The Margin's place is fixed here, not when the picture is confirmed.
    @State private var photoTappedAt = Date()
    /// A photo waiting for the written Margin it belongs to (Write instead, or a microphone that couldn't start).
    @State private var writingPhoto: LiveSessionPhotoStore.Staged?
    /// A line above the photo on the writing sheet.
    @State private var writingNotice: String?
    @State private var showsCameraOff = false
    /// The writing sheet for a photo waits for an alert that is up to be answered.
    @State private var wantsWriteAfterAlert = false
    /// Set once the recording screen has gone; the change handler opens the writing sheet (or waits for an alert).
    @State private var wantsWritePhoto = false
    // Ending
    @State private var showsEndCard = false
    @State private var showsLineUp = false
    @State private var confirmsDiscard = false
    @State private var isRegisteredRunning = false
    /// Saving or discarding closes the screen without the setup card, and a saved session's item opens once it has
    /// gone (#4168).
    @StateObject private var finish = LiveSessionFinish()

    private var isRunningScreen: Bool { controller.session != nil || !finish.showsSetup }

    var body: some View {
        #if DEBUG
        let _ = ScreenRedrawProbe.record("liveSession")
        #endif
        NavigationStack {
            Group {
                if let session = controller.session {
                    LiveSessionStage(pane: paneContent(session), pill: pill, dock: dock(session))
                } else if finish.showsSetup {
                    setupScreen
                } else {
                    Color.clear
                }
            }
            .background(isRunningScreen ? AppColors.listeningBackground : AppColors.bone)
            // This screen is a full-screen cover over the root, so the root's pill padding doesn't apply here; the
            // screen's own pill sits in the stage above the dock.
            .miniPlayerKeepOut()
            .navigationTitle("Live session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(isRunningScreen ? AppColors.listeningBackground : AppColors.bone, for: .navigationBar)
            .toolbarColorScheme(isRunningScreen ? .dark : nil, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: leave) {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold)).minimumTapTarget()
                    }
                    .accessibilityLabel("Back")
                    .accessibilityHint("Leaves this screen. The session keeps running.")
                    .accessibilityIdentifier("liveSession.back.button")
                }
                // Return is a new line in a field, so Done closes the keyboard whichever field has it: the setup and
                // session fields are not tied to one focus state, so it resigns the first responder directly (#3547).
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Done") { dismissKeyboard() }
                        .accessibilityIdentifier("liveSession.keyboard.done")
                    Spacer()
                }
            }
        }
        .environment(\.miniPlayerClearance, 0)
        .onAppear {
            finish.screenAppeared()
            controller.load()
        }
        .onDisappear {
            unregisterRunningScreen()
            controller.stopPolling()
            finish.screenGone(open: openSavedItem)
        }
        .onChange(of: links.pendingAction) { _, _ in applyLink() }
        .onChange(of: controller.didLoad) { _, _ in applyLink() }
        .onChange(of: controller.session?.id) { _, _ in showsEndCard = false }
        // An ended session shows what to do with it, which is on the Session pane.
        .onChange(of: controller.hasEnded, initial: true) { _, ended in if ended { pane = .session } }
        // The mini player's mic starts the item's recording on the root, which sits under this screen. This screen
        // closes so that recording shows (the mini player acts on the root and can't be told otherwise).
        .onChange(of: feed.inputs.recordingNavigationIsLocked) { _, locked in
            if locked && cover == nil { leave() }
        }
        .onChange(of: wantsWrite) { _, wanted in
            guard wanted else { return }
            wantsWrite = false
            beginWriting()
        }
        .onChange(of: wantsWritePhoto) { _, wanted in
            guard wanted else { return }
            wantsWritePhoto = false
            if controller.errorMessage != nil {
                wantsWriteAfterAlert = true
            } else {
                beginWriting(startedAt: writingStartedAt)
            }
        }
        // An alert over the screen can't be closed by a link: once it is answered, a recording still going gets its screen.
        .onChange(of: controller.errorMessage) { _, message in
            if message == nil && controller.isRecordingSpoken && cover == nil { showRecordingAfterPresenting() }
            if message == nil && wantsWriteAfterAlert {
                wantsWriteAfterAlert = false
                // The alert is still going away: a cover set now would be dropped and leave the photo waiting with no
                // sheet. `present` waits for the alert to be gone and gives the photo up if the sheet can't open.
                present(.liveWriting)
            }
        }
        // The microphone couldn't start while a photo waited: the picture is kept and the Margin is written instead.
        .onChange(of: capture.returnedPhoto) { _, returned in
            guard let returned else { return }
            capture.returnedPhoto = nil
            writingPhoto = returned.staged
            writingNotice = LiveSessionPhotoMargin.writeInsteadLine
            writingStartedAt = returned.startedAt
            writeAfterAlert()
        }
        .onChange(of: controller.isRecordingSpoken) { _, recording in
            if !recording && cover == .liveRecording { cover = nil }
        }
        .fullScreenCover(item: $cover) { cover in
            switch cover {
            case .liveRecording: recordingScreen
            case .liveWriting: writingScreen
            case .camera: cameraScreen
            }
        }
        // The camera is off for Spoken Margins: say so, and offer the two ways on (never a dead tap).
        .confirmationDialog(LiveSessionPhotoMargin.cameraOffLine, isPresented: $showsCameraOff, titleVisibility: .visible) {
            Button(LiveSessionPhotoMargin.openSettingsTitle) { LiveSessionCamera.openSettings() }
            Button(LiveSessionPhotoMargin.withoutPhotoTitle) { beginRecording() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showsLineUp) {
            if let session = controller.session {
                LiveSessionLineUpView(session: session) { saved in
                    showsLineUp = false
                    finish.saved(saved, dismiss: { dismiss() }, open: openSavedItem)
                }
                .environmentObject(model)
            }
        }
        // Ending asks "when did it end?" in a sheet on this stable root, which nothing redraws: the sheet once closed
        // by itself before the listener could answer (#2831). Only its own End and Cancel close it.
        .sheet(isPresented: $showsEndCard) { endSheet }
        .sheet(item: $openMargin) { target in marginScreen(target) }
        .alert("Live session", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .confirmationDialog("Discard this session and its Margins?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard Session", role: .destructive) {
                controller.discard()
                finish.discarded()
                dismiss()
            }
        }
        // Outermost, so the mini player and every sheet and cover this screen opens have the model to watch themselves.
        .environmentObject(model)
    }

    /// Back to where the listener came from. The session keeps running; a spoken Margin still recording is saved, not
    /// dropped (#3489).
    private func leave() {
        dismissKeyboard() // a field the listener was still typing in is kept first
        controller.stopSpokenMargin()
        dismiss()
    }

    /// The screen has gone: let go of the saved session and open the item it became (#4168).
    private func openSavedItem(_ saved: Gate1AppModel.SavedLiveSession) {
        controller.close()
        model.openSavedLiveSession(saved)
    }

    /// A tap on the Live Activity's Write a Margin or Speak a Margin (#2833): the writing sheet opens, or the spoken
    /// Margin is already recording. Needs a running session; otherwise the screen just opens.
    private func applyLink() {
        guard controller.didLoad else { return }
        // Only a screen showing the running session takes a link; one open on an ended session leaves it waiting.
        guard controller.isRunning else { return unregisterRunningScreen() }
        if !isRegisteredRunning {
            isRegisteredRunning = true
            links.runningScreenAppeared()
        }
        // A spoken Margin outlives this screen (#3489): one still recording when the screen comes back shows its
        // recording screen again, so Finish and Cancel are in reach.
        if controller.isRecordingSpoken && cover == nil { showRecordingAfterPresenting() }
        guard let action = links.takeAction() else { return }
        switch action {
        case .open: break
        case .write:
            Task {
                try? await Task.sleep(for: .milliseconds(400)) // after the screen has finished presenting
                wantsWrite = true
            }
        case .speak:
            startRecordingIfIdle()
            showRecordingAfterPresenting()
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func unregisterRunningScreen() {
        guard isRegisteredRunning else { return }
        isRegisteredRunning = false
        links.runningScreenDisappeared()
    }

    // MARK: Setup

    private var setupScreen: some View {
        ScrollView {
            setupCard
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        // Start Session sits above the keyboard, so one tap reaches it with the keyboard up (#3547).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            startButton
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .background(AppColors.bone)
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Take Margins on something outside the app: a meeting, an audiobook in another app, or a paper book. Nothing is recorded.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            Picker("Kind", selection: $kind) {
                ForEach(ElsewhereKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .segmentedUnlessLargeText()
            AppTextField(kind == .meeting ? "Meeting name" : "Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("liveSession.setup.title")
            if kind != .paper {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where are you now?").font(.headline) // a field label, not a section title
                    AppTextField(kind == .meeting ? "Meeting clock, like 2:00" : "Time in the book, like 0:00", text: $startPosition)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                    Text(kind == .meeting ? "Leave blank if you don't know. You can set it later in Session." : "The time your audiobook app shows.")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
            }
            LiveSessionPlaceField(
                prompt: kind == .paper ? "Page, chapter or percent" : "Page, chapter or percent (optional)",
                defaultUnit: LiveSessionPlace.defaultUnit(for: kind), text: $startWhere
            )
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// Pinned under the setup card, above the keyboard (#3547).
    private var startButton: some View {
        Button {
            let read = LiveSessionWhere.interpret(clockText: startPosition, whereText: startWhere, kind: kind)
            controller.start(
                kind: kind, title: title,
                startPositionMs: read.positionMs, // blank stays unknown, never a guessed 0:00 (#3241)
                startWhere: read.text, startPlace: read.place
            )
        } label: {
            Label("Start Session", systemImage: "record.circle").frame(maxWidth: .infinity, minHeight: 44)
        }
        .filledActionButton()
        .accessibilityIdentifier("liveSession.start")
    }

    // MARK: Running

    @ViewBuilder
    private func paneContent(_ session: LiveSession) -> some View {
        switch pane {
        case .margins:
            LiveSessionMarginsPane(session: session, select: { openMargin = MarginTarget(id: $0.id) }, pauseOtherAudio: pauseSource)
        case .session:
            LiveSessionSessionPane(
                session: session, isRunning: controller.isRunning,
                setKind: controller.setKind, setTitle: controller.setTitle, setDescription: controller.setDescription,
                setStartWhere: controller.setStartWhere, setStatedStart: { controller.setStatedStart($0) },
                setSourceClock: { controller.setSourceClock(positionMs: $0) },
                showError: { controller.errorMessage = $0 },
                header: { if controller.hasEnded { finishCard(session) } })
        }
    }

    private func dock(_ session: LiveSession) -> LiveSessionDock {
        // Each piece is typed on its own line: one big call expression made the compiler give up (CI, #4179).
        let photoAction: (() -> Void)? = LiveSessionPhotoMargin.offers(session.kind) ? { beginPhoto() } : nil
        let photoIsWaiting: Bool = writingPhoto != nil || capture.photo != nil
        // While a photo waits for its words, Add Margin and Write wait too: the photo belongs to the next one.
        let addIsDisabled: Bool = feed.inputs.recordingNavigationIsLocked || writingPhoto != nil || isTakingPhoto
        let photoIsDisabled: Bool = !LiveSessionPhotoMargin.isEnabled(
            isRunning: controller.isRunning, isRecording: controller.isRecordingSpoken,
            isCapturingPhoto: isTakingPhoto, hasPhotoWaiting: photoIsWaiting)
        return LiveSessionDock(
            pane: $pane, marginCount: session.margins.count, isRunning: controller.isRunning,
            resumeUntil: controller.resumeUntil,
            clock: { dockClock($0, session: session) },
            end: { dismissKeyboard(); showsEndCard = true },
            resume: { controller.resume() },
            record: beginRecording, write: { beginWriting() },
            photo: photoAction,
            addIsDisabled: addIsDisabled,
            photoIsDisabled: photoIsDisabled)
    }

    /// The existing mini player above the dock while an item is playing. Its mic files on the item (this screen closes
    /// so the item's recording shows); Add a Margin files on the session.
    @ViewBuilder
    private var pill: some View {
        if feed.inputs.showsMiniPlayer {
            MiniPlayerBar(openNowPlaying: {
                controller.stopSpokenMargin()
                dismiss()
                model.openPlayback()
            })
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(AppColors.listeningBackground)
        }
    }

    /// While it runs, the big clock is the source's own (the meeting's elapsed time) and the session counter is the
    /// small line beside it (#2834). Without a clock, or once it has ended, the session counter is the big one.
    private func dockClock(_ date: Date, session: LiveSession) -> LiveSessionDockClock {
        let sessionTime = LiveSessionPositionMap.clock(controller.elapsedMs(at: date))
        let position = controller.predictedPosition(at: date)
        if controller.isRunning, let title = LiveSessionClock.title(for: session.kind), let position {
            let main = LiveSessionPositionMap.clock(position.ms)
            return LiveSessionDockClock(
                main: main, caption: "\(title) · session \(sessionTime)",
                accessibility: "\(title) \(main), session time \(sessionTime)")
        }
        var caption: String?
        if let position { caption = "Source: \(position.label)" }
        if session.kind == .meeting, session.startPositionMs == nil, controller.isRunning {
            caption = "Set the meeting clock in Session"
        }
        if controller.hasEnded { caption = caption.map { "Ended · \($0)" } ?? "Ended" }
        return LiveSessionDockClock(main: sessionTime, caption: caption, accessibility: "Session time \(sessionTime)")
    }

    // MARK: Adding Margins

    private var anchorTitle: String {
        guard let session = controller.session else { return "Live session" }
        return session.title.isEmpty ? "\(session.kind.label) session" : session.title
    }

    /// "about 1:23:10" or "Chapter 3", else how long the session has run.
    private func anchorSubtitle(at date: Date) -> String {
        controller.predictedPosition(at: date)?.label ?? "Session time \(LiveSessionPositionMap.clock(controller.elapsedMs(at: date)))"
    }

    /// An item playing in the app is paused first, the same as a Margin on the item does.
    private func pauseSource() {
        if model.activePlaybackIsPlaying { model.pause() }
    }

    private func beginRecording() {
        startRecordingIfIdle()
        if controller.isRecordingSpoken { cover = .liveRecording }
    }

    private func startRecordingIfIdle() {
        // A Margin being written is not interrupted by a Lock Screen link: its screen can't give way to a recording.
        // A camera that is open, or a photo waiting for its words, keeps its screen: a link can't swap it away (#2708).
        guard controller.isRunning, !controller.isRecordingSpoken, cover != .liveWriting, cover != .camera,
              writingPhoto == nil else { return }
        dismissKeyboard()
        pauseSource()
        controller.startSpokenMargin()
    }

    /// Closes the sheets this screen can have open (a Margin's screen, the End sheet). A full-screen cover can't
    /// present over a sheet, so a link that needs one closes them first. Returns whether any was open.
    private func closeSheets() -> Bool {
        let hadSheet = openMargin != nil || showsEndCard
        openMargin = nil
        showsEndCard = false
        return hadSheet
    }

    /// Whether anything is up over this screen that a full-screen cover can't present over.
    private var hasSheetOrAlertUp: Bool { openMargin != nil || showsEndCard || controller.errorMessage != nil }

    /// The one way a link, or a return to the screen, gets a full-screen cover shown (#3491). A cover asked for while
    /// this screen is itself still being presented, or while a sheet or the error alert is up, is dropped and leaves
    /// `cover` set to a screen nobody sees, so a recording would run with no Finish or Cancel. So it waits for the
    /// screen to finish presenting, closes the sheets, and sets `cover` only when nothing is left over the screen. A
    /// link can't close the error alert: that case leaves `cover` unset, and answering the alert shows a recording
    /// that is still going (a Write link under the alert is dropped; the pencil is still there). The microphone
    /// doesn't wait for any of this.
    private func present(_ wanted: Cover) {
        func stillWanted() -> Bool {
            switch wanted {
            case .liveRecording: controller.isRecordingSpoken
            case .camera: isTakingPhoto && controller.isRunning && !controller.isRecordingSpoken
            case .liveWriting: controller.isRunning && !controller.isRecordingSpoken
            }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            // A camera that never opens leaves Photo live again, not waiting for a picture that isn't coming.
            func gaveUp() {
                switch wanted {
                case .camera: isTakingPhoto = false
                case .liveWriting: dropWaitingPhoto() // a photo with no sheet to take it would lock Add Margin and Write
                case .liveRecording: break
                }
            }
            guard stillWanted(), cover == nil else { return gaveUp() }
            if closeSheets() { try? await Task.sleep(for: .milliseconds(400)) } // after the sheet has gone
            guard stillWanted(), cover == nil, controller.errorMessage == nil else { return gaveUp() }
            cover = wanted
        }
    }

    private func showRecordingAfterPresenting() { present(.liveRecording) }

    // MARK: Photo Margins (#2708)

    /// Photo, from the dock. Never a dead tap: with no camera or a camera that is off the listener is told, and told what
    /// to do instead. The first use goes straight to iOS's own camera question; nothing of ours comes before it.
    private func beginPhoto() {
        guard let session = controller.session, LiveSessionPhotoMargin.offers(session.kind),
              LiveSessionPhotoMargin.isEnabled(
                isRunning: controller.isRunning, isRecording: controller.isRecordingSpoken,
                isCapturingPhoto: isTakingPhoto || cover != nil, hasPhotoWaiting: writingPhoto != nil || capture.photo != nil)
        else { return }
        photoTappedAt = Date() // the place is fixed at this tap
        #if DEBUG
        // A simulator has no camera: a test launched with -LiveSessionFixturePhoto takes a generated picture instead.
        if let fixture = LiveSessionCamera.fixturePhoto {
            isTakingPhoto = true
            pauseSource()
            Task { await takePicture(fixture) }
            return
        }
        #endif
        switch LiveSessionCamera.tap {
        case .noCamera:
            controller.errorMessage = LiveSessionPhotoMargin.noCameraLine
        case .cameraOff:
            showsCameraOff = true
        case .openCamera:
            dismissKeyboard()
            pauseSource()
            isTakingPhoto = true
            if hasSheetOrAlertUp { present(.camera) } else { cover = .camera }
        }
    }

    private var cameraScreen: some View {
        LiveSessionCameraPicker(
            onPicture: { image in Task { await takePicture(image) } },
            onCancel: {
                isTakingPhoto = false
                cover = nil
            }
        )
        .ignoresSafeArea()
    }

    /// Fits the picture to what a Margin may keep, off the main actor, then opens the recorder with it above. When the
    /// picture can't be used nothing is saved, and the listener can try again or add a Margin without a photo.
    private func takePicture(_ picture: UIImage) async {
        guard let store = LiveSessionPhotoIntake.store else { return pictureFailed() }
        guard let staged = await LiveSessionPhotoIntake.stage(picture, in: store) else { return pictureFailed() }
        openRecorder(with: staged)
    }

    /// The fixture a test supplies where the camera would return a picture (DEBUG builds only).
    private func takePicture(_ data: Data) async {
        guard let store = LiveSessionPhotoIntake.store else { return pictureFailed() }
        guard let staged = await LiveSessionPhotoIntake.stage(data, in: store) else { return pictureFailed() }
        openRecorder(with: staged)
    }

    /// Nothing was saved: the camera closes, and once it has the listener is told and can try again. An alert raised while a
    /// cover is still going away is dropped, so it waits for the cover to be gone.
    private func pictureFailed() {
        isTakingPhoto = false
        cover = nil
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            controller.errorMessage = LiveSessionPhotoMargin.couldNotUseLine
        }
    }

    private func openRecorder(with staged: LiveSessionPhotoStore.Staged) {
        isTakingPhoto = false
        // The session may have ended or started a recording while the camera was open.
        guard controller.isRunning, !controller.isRecordingSpoken else {
            controller.discardPhoto(staged)
            cover = nil
            return
        }
        controller.startSpokenMargin(photo: staged, placedAt: photoTappedAt)
        cover = .liveRecording
    }

    /// Throws away a photo that was waiting for a written Margin that can no longer be opened.
    private func dropWaitingPhoto() {
        guard let photo = writingPhoto, cover != .liveWriting else { return }
        controller.discardPhoto(photo)
        writingPhoto = nil
        writingNotice = nil
    }

    /// Opens the writing sheet for a photo whose recorder couldn't start, after any alert has been answered.
    private func writeAfterAlert() {
        Task {
            try? await Task.sleep(for: .milliseconds(500)) // the recording screen goes, the alert shows
            wantsWritePhoto = true
        }
    }

    /// `startedAt` is when the listener began, when they began by recording: writing instead keeps that place.
    private func beginWriting(startedAt: Date? = nil) {
        // A spoken Margin still recording keeps its screen; a Write link can't swap it for the writing sheet and
        // leave the microphone on.
        guard controller.isRunning, !controller.isRecordingSpoken, cover != .camera else {
            dropWaitingPhoto() // nothing will take it now, so it is not left to the next launch's sweep
            return
        }
        // A Margin already being written keeps its words and the moment it was begun: a second Write link must not
        // re-date it.
        guard cover != .liveWriting else { return }
        dismissKeyboard()
        pauseSource()
        writingStartedAt = startedAt ?? Date()
        if hasSheetOrAlertUp {
            present(.liveWriting)
        } else {
            cover = .liveWriting
        }
    }

    private var recordingScreen: some View {
        LiveSessionRecordingView(
            capture: capture, sessionId: controller.session?.id ?? "", anchorTitle: anchorTitle,
            anchorSubtitle: { anchorSubtitle(at: Date()) },
            onWriteInstead: { began in
                // The recording is already discarded, so nothing is recording and the writing screen can replace it.
                writingStartedAt = began ?? Date()
                cover = .liveWriting
            },
            onKeepPhoto: { photo in
                // Write instead keeps the picture: the written Margin takes it.
                writingPhoto = photo
                writingNotice = nil
            },
            kind: controller.session?.kind ?? .meeting
        )
        .environmentObject(model)
    }

    private var writingScreen: some View {
        LiveSessionWriteSheet(
            kind: controller.session?.kind ?? .meeting, anchorTitle: anchorTitle,
            anchorLabel: anchorSubtitle(at: writingStartedAt),
            predictedPosition: { controller.predictedPosition(at: $0, adjustmentMs: $1) },
            onSave: { text, whereNote, adjustmentMs in
                if let photo = writingPhoto {
                    // The picture's file goes into place before the Margin that names it is saved.
                    let placedAt = writingStartedAt
                    Task { await controller.addMargin(text: text, whereNote: whereNote, adjustmentMs: adjustmentMs, markedAt: placedAt, photo: photo) }
                    writingPhoto = nil
                    writingNotice = nil
                } else {
                    controller.addMargin(text: text, whereNote: whereNote, adjustmentMs: adjustmentMs, markedAt: writingStartedAt)
                }
                cover = nil
            },
            onCancel: {
                // Cancel means "I don't want this": the picture is deleted with it.
                if let photo = writingPhoto { controller.discardPhoto(photo) }
                writingPhoto = nil
                writingNotice = nil
                cover = nil
            },
            photo: writingPhoto,
            notice: writingNotice
        )
        .environmentObject(model)
    }

    @ViewBuilder
    private func marginScreen(_ target: MarginTarget) -> some View {
        if let session = controller.session, let margin = session.margins.first(where: { $0.id == target.id }) {
            LiveSessionMarginDetailView(
                margin: margin, sessionTitle: session.title,
                position: LiveSessionMarginsList.positionLabel(for: margin, in: session),
                keepHeardPlace: { controller.keepHeardPlace(id: margin.id) },
                declineHeardPlace: { controller.declineHeardPlace(id: margin.id) },
                saveText: { controller.updateText(id: margin.id, text: $0) },
                delete: { controller.removeMargin(id: margin.id) },
                pauseOtherAudio: pauseSource)
        }
    }

    // MARK: Ending

    private var endSheet: some View {
        ScrollView {
            if let session = controller.session { endCard(session).padding(16) }
        }
        .background(AppColors.bone)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func endCard(_ session: LiveSession) -> some View {
        LiveSessionEndCard(
            kind: session.kind, startedAt: session.startedAt,
            placeUnit: session.startPlace?.unit ?? LiveSessionPlace.defaultUnit(for: session.kind)
        ) { when, read in
            if controller.end(when: when, endPositionMs: read.positionMs, endWhere: read.text, endPlace: read.place) { showsEndCard = false }
        } onCancel: {
            showsEndCard = false
        } onStillGoing: {
            showsEndCard = false
            Task { await controller.remindStillGoing() }
        }
    }

    /// The ended session's choices, at the top of the Session pane. Resume is in the dock, where End was.
    private func finishCard(_ session: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.isQuick == true ? "Quick session" : "Session ended").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(Array(LiveSessionPlaceMap.conflicts(in: session).enumerated()), id: \.offset) { _, conflict in
                Text(conflict.description()).font(.caption).foregroundStyle(AppColors.watchSecondary)
            }
            if let check = LiveSessionPlaceMap.clockCheck(for: session) {
                Text(check.note).font(.caption).foregroundStyle(AppColors.watchSecondary)
                Button { controller.useImpliedStart() } label: { Text("Use the start the clock shows").frame(minHeight: 44).contentShape(Rectangle()) }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            if session.kind == .meeting {
                Text("Line it up with the meeting's transcript (.vtt, .srt, .docx or .txt) to place your Margins on what was said. You can add the recording too.")
                    .font(.caption).foregroundStyle(AppColors.watchSecondary)
            }
            Button { showsLineUp = true } label: {
                Label("Line Up with a Transcript", systemImage: "text.alignleft").frame(maxWidth: .infinity, minHeight: 44)
            }
            .filledActionButton()
            Button {
                guard finish.beginSaving() else { return }
                Task {
                    do {
                        // The session as it is when saved, not as this card was drawn: words typed a moment ago are in it.
                        let saved = try await model.saveLiveSession(controller.session ?? session, transcript: nil, placed: [], recordingURL: nil)
                        model.hangTelemetry.labels.scoped("liveSessionSavedAsNotes") {
                            finish.saved(saved, dismiss: { dismiss() }, open: openSavedItem)
                        }
                    } catch {
                        controller.errorMessage = ListenerErrorText.line(prefix: "Couldn't save:", error: error)
                        finish.saveFailed()
                    }
                }
            } label: {
                Label(finish.isSaving ? "Saving…" : "Save as Notes", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(finish.isSaving)
            Button("Discard Session", role: .destructive) { confirmsDiscard = true }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.watchControl, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The predicted position with fine (±5 s) and coarse (±1 min) slides. Never required.
struct PositionNudgeRow: View {
    let label: String
    @Binding var adjustmentMs: Int

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Unchanged at ordinary sizes. At accessibility sizes the buttons go under the label, two by two, so none is
    /// squeezed or broken into letters beside it (#3721).
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.subheadline.monospacedDigit())
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        nudge("−1m", -60_000, "One minute earlier")
                        nudge("−5s", -5_000, "Five seconds earlier")
                    }
                    GridRow {
                        nudge("+5s", 5_000, "Five seconds later")
                        nudge("+1m", 60_000, "One minute later")
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                Text(label).font(.subheadline.monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading)
                nudge("−1m", -60_000, "One minute earlier")
                nudge("−5s", -5_000, "Five seconds earlier")
                nudge("+5s", 5_000, "Five seconds later")
                nudge("+1m", 60_000, "One minute later")
            }
        }
    }

    private func nudge(_ title: String, _ delta: Int, _ accessibility: String) -> some View {
        Button { adjustmentMs += delta } label: { Text(title).minimumTapTarget() }
            .buttonStyle(.bordered)
            .font(.caption.monospacedDigit())
            .accessibilityLabel(accessibility)
    }
}

/// Asks when the session stopped and where the listener is, on the session screen. Skippable; nudged for audiobooks,
/// where it sets the pace. It stays until the listener taps End or Cancel.
private struct LiveSessionEndCard: View {
    let kind: ElsewhereKind
    let startedAt: Date
    /// What a bare number means in the place field: the unit the session started in.
    let placeUnit: LiveSessionPlace.Unit
    let onEnd: (LiveSessionEnd.When, LiveSessionWhere) -> Void
    let onCancel: () -> Void
    /// "It's still going": keep the session running and remind the listener later (#2709).
    let onStillGoing: () -> Void
    @State private var endPosition = ""
    @State private var endWhere = ""
    /// Index into the quick choices; one past the last is "At a time".
    @State private var whenIndex = 0
    @State private var clockTime = Date()
    /// Fixed when the card opens, so the offered choices don't shift while it is up.
    @State private var openedAt = Date()

    private var choices: [LiveSessionEnd.When] { LiveSessionEnd.quickChoices(startedAt: startedAt, tappedAt: openedAt) }

    private var when: LiveSessionEnd.When {
        guard whenIndex < choices.count else {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: clockTime)
            return .clockTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }
        return choices[whenIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("End Session").font(.headline).accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 4) {
                Picker("When did it end?", selection: $whenIndex) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        Text(choice.label).tag(index)
                    }
                    Text("At a time…").tag(choices.count)
                }
                .pickerStyle(.menu)
                if whenIndex >= choices.count {
                    DatePicker("Time", selection: $clockTime, displayedComponents: .hourAndMinute)
                }
                Text("If you stopped a while ago, say so: it keeps your Margins' places close.")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            if kind != .paper {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where are you now?").font(.subheadline.weight(.semibold))
                    AppTextField(kind == .meeting ? "Meeting clock, like 47:30" : "Time in the book, like 1:23:10", text: $endPosition)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                    Text(kind == .audiobook
                         ? "Worth filling in: it tells Spoken Margins your listening speed and pauses, so each Margin's place is closer."
                         : "Optional.")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
            }
            LiveSessionPlaceField(prompt: "Where did you stop? Page, chapter or percent (optional)", defaultUnit: placeUnit, text: $endWhere)
            Button {
                onEnd(when, LiveSessionWhere.interpret(clockText: endPosition, whereText: endWhere, kind: kind, defaultUnit: placeUnit))
            } label: {
                Label("End Session", systemImage: "stop.circle.fill").frame(maxWidth: .infinity, minHeight: 44)
            }
            .filledActionButton()
            .accessibilityIdentifier("liveSession.confirmEnd")
            Button(action: onStillGoing) {
                Text("It's still going. Remind me in 15 minutes").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("liveSession.stillGoing")
            Button(action: onCancel) { Text("Cancel").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                .accessibilityIdentifier("liveSession.cancelEnd")
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// A field for "where are you?" as a page, chapter or percent (#2707). It says how it reads what was typed, so the
/// listener sees the unit before they keep it; a bare number means `defaultUnit`.
struct LiveSessionPlaceField: View {
    let prompt: String
    let defaultUnit: LiveSessionPlace.Unit
    @Binding var text: String

    private var read: LiveSessionPlace? {
        LiveSessionPlace.parseWhole(text, defaultUnit: defaultUnit, allowsTime: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AppTextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
            if let read {
                Text("Reads as \(read.label)").font(.caption).foregroundStyle(AppColors.secondaryText)
            } else if text.isEmpty {
                Text("Like \u{201C}page 118\u{201D}, \u{201C}ch 7\u{201D} or \u{201C}40%\u{201D}. A bare number is a \(defaultUnit.noun).")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
        }
    }
}
