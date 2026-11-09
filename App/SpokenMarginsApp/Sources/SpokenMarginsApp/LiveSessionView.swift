import SessionKit
import SwiftUI

/// Live session (#1989, #2481, prototype): Margins on a clock while a meeting, an audiobook in another app or
/// a paper book goes on outside Spoken Margins. Nothing is recorded. Afterwards a meeting lines up with its
/// transcript (and recording, if the listener has it); anything else is saved as session notes.
///
/// The running state is the playback screen's layout (#3491): a Margins pane and a Session pane, and a dock with
/// the pane switch, the clock with End, and Add a Margin with the pencil. Add a Margin opens the normal recording
/// screen and the pencil the normal writing sheet; neither is a control that changes shape on this screen.
struct LiveSessionView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: LiveSessionController
    @ObservedObject private var links = LiveSessionLinkRouter.shared
    @ObservedObject private var capture = LiveSessionSpokenCapture.shared

    /// `sessionId` opens that session (from the Library's Live row); nil opens the running one, or the setup card.
    init(sessionId: String? = nil) {
        _controller = StateObject(wrappedValue: LiveSessionController(sessionId: sessionId))
    }

    /// The two full-screen screens this screen opens. One cover, so two can never stack.
    private enum Cover: String, Identifiable {
        case liveRecording, liveWriting
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
    // Ending
    @State private var showsEndCard = false
    @State private var showsLineUp = false
    @State private var confirmsDiscard = false
    @State private var isSaving = false
    @State private var isRegisteredRunning = false

    private var isRunningScreen: Bool { controller.session != nil }

    var body: some View {
        NavigationStack {
            Group {
                if let session = controller.session {
                    LiveSessionStage(pane: paneContent(session), pill: pill, dock: dock(session))
                } else {
                    setupScreen
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
        .onAppear { controller.load() }
        .onDisappear {
            unregisterRunningScreen()
            controller.stopPolling()
        }
        .onChange(of: links.pendingAction) { _, _ in applyLink() }
        .onChange(of: controller.didLoad) { _, _ in applyLink() }
        .onChange(of: controller.session?.id) { _, _ in showsEndCard = false }
        // An ended session shows what to do with it, which is on the Session pane.
        .onChange(of: controller.hasEnded, initial: true) { _, ended in if ended { pane = .session } }
        // The mini player's mic starts the item's recording on the root, which sits under this screen. This screen
        // closes so that recording shows (the mini player acts on the root and can't be told otherwise).
        .onChange(of: model.recordingNavigationIsLocked) { _, locked in
            if locked && cover == nil { leave() }
        }
        .onChange(of: wantsWrite) { _, wanted in
            guard wanted else { return }
            wantsWrite = false
            beginWriting()
        }
        .onChange(of: controller.isRecordingSpoken) { _, recording in
            if !recording && cover == .liveRecording { cover = nil }
        }
        .fullScreenCover(item: $cover) { cover in
            switch cover {
            case .liveRecording: recordingScreen
            case .liveWriting: writingScreen
            }
        }
        .sheet(isPresented: $showsLineUp) {
            if let session = controller.session {
                LiveSessionLineUpView(session: session) {
                    controller.close()
                    showsLineUp = false
                    dismiss()
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
                dismiss()
            }
        }
    }

    /// Back to where the listener came from. The session keeps running; a spoken Margin still recording is saved, not
    /// dropped (#3489).
    private func leave() {
        dismissKeyboard() // a field the listener was still typing in is kept first
        controller.stopSpokenMargin()
        dismiss()
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
            .pickerStyle(.segmented)
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
        LiveSessionDock(
            pane: $pane, marginCount: session.margins.count, isRunning: controller.isRunning,
            resumeUntil: controller.resumeUntil,
            clock: { dockClock($0, session: session) },
            end: { dismissKeyboard(); showsEndCard = true },
            resume: { controller.resume() },
            record: beginRecording, write: { beginWriting() },
            addIsDisabled: model.recordingNavigationIsLocked)
    }

    /// The existing mini player above the dock while an item is playing. Its mic files on the item (this screen closes
    /// so the item's recording shows); Add a Margin files on the session.
    @ViewBuilder
    private var pill: some View {
        if model.shouldShowMiniPlayer {
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
        guard controller.isRunning, !controller.isRecordingSpoken, cover != .liveWriting else { return }
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

    /// For a link or a return to the screen: a cover asked for while this screen is itself still being presented, or
    /// while a sheet is up, would be dropped, leaving a recording with no screen. The microphone doesn't wait for this.
    private func showRecordingAfterPresenting() {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard controller.isRecordingSpoken, cover == nil else { return }
            if closeSheets() { try? await Task.sleep(for: .milliseconds(400)) } // after the sheet has gone
            if controller.isRecordingSpoken && cover == nil { cover = .liveRecording }
        }
    }

    /// `startedAt` is when the listener began, when they began by recording: writing instead keeps that place.
    private func beginWriting(startedAt: Date? = nil) {
        // A spoken Margin still recording keeps its screen; a Write link can't swap it for the writing sheet and
        // leave the microphone on.
        guard controller.isRunning, !controller.isRecordingSpoken else { return }
        dismissKeyboard()
        pauseSource()
        writingStartedAt = startedAt ?? Date()
        guard closeSheets() else {
            cover = .liveWriting
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(400)) // after the sheet has gone
            if controller.isRunning && !controller.isRecordingSpoken && cover == nil { cover = .liveWriting }
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
            }
        )
        .environmentObject(model)
    }

    private var writingScreen: some View {
        LiveSessionWriteSheet(
            kind: controller.session?.kind ?? .meeting, anchorTitle: anchorTitle,
            anchorLabel: anchorSubtitle(at: writingStartedAt),
            predictedPosition: { controller.predictedPosition(at: $0, adjustmentMs: $1) },
            onSave: { text, whereNote, adjustmentMs in
                controller.addMargin(text: text, whereNote: whereNote, adjustmentMs: adjustmentMs, markedAt: writingStartedAt)
                cover = nil
            },
            onCancel: { cover = nil }
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
                isSaving = true
                Task {
                    do {
                        // The session as it is when saved, not as this card was drawn: words typed a moment ago are in it.
                        try await model.saveLiveSession(controller.session ?? session, transcript: nil, placed: [], recordingURL: nil)
                        model.hangTelemetry.labels.scoped("liveSessionSavedAsNotes") {
                            controller.close()
                            dismiss()
                        }
                    } catch {
                        controller.errorMessage = ListenerErrorText.line(prefix: "Couldn't save:", error: error)
                    }
                    isSaving = false
                }
            } label: {
                Label(isSaving ? "Saving…" : "Save as Notes", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(isSaving)
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

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.subheadline.monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading)
            nudge("−1m", -60_000, "One minute earlier")
            nudge("−5s", -5_000, "Five seconds earlier")
            nudge("+5s", 5_000, "Five seconds later")
            nudge("+1m", 60_000, "One minute later")
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
