import SessionKit
import SwiftUI

/// Live session (#1989, #2481, prototype): Margins on a clock while a meeting, an audiobook in another app or
/// a paper book goes on outside Spoken Margins. Nothing is recorded. Afterwards a meeting lines up with its
/// transcript (and recording, if the listener has it); anything else is saved as session notes.
struct LiveSessionView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: LiveSessionController
    @ObservedObject private var links = LiveSessionLinkRouter.shared

    /// `sessionId` opens that session (from the Library's Live row); nil opens the running one, or the setup card.
    init(sessionId: String? = nil) {
        _controller = StateObject(wrappedValue: LiveSessionController(sessionId: sessionId))
    }

    // Setup
    @State private var kind: ElsewhereKind = .meeting
    @State private var title = ""
    @State private var startPosition = ""
    @State private var startWhere = ""
    // Running
    @State private var marginText = ""
    @State private var marginWhere = ""
    @State private var adjustmentMs = 0
    @FocusState private var marginFieldFocused: Bool
    // Editing while it runs
    @State private var showsDetails = false
    @State private var titleDraft = ""
    @State private var whereDraft = ""
    @State private var clockDraft = ""
    // Ending
    @State private var showsEndCard = false
    @State private var showsLineUp = false
    @State private var confirmsDiscard = false
    @State private var isSaving = false
    @State private var isRegisteredRunning = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let session = controller.session {
                            sessionHeader(session)
                            if showsDetails && controller.isRunning { detailsCard(session) }
                            if controller.isRunning { marginComposer(session) }
                            marginList(session)
                            if controller.hasEnded {
                                finishCard(session)
                            } else if showsEndCard {
                                endCard(session).id(Self.endCardId)
                            } else {
                                endButton
                            }
                        } else {
                            setupCard
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: controller.session?.id) { _, _ in
                    showsEndCard = false
                    showsDetails = false
                }
                .onChange(of: controller.isRunning) { _, running in if !running { showsDetails = false } }
                .onChange(of: showsEndCard) { _, shown in
                    if shown {
                        DispatchQueue.main.async { withAnimation { scroller.scrollTo(Self.endCardId, anchor: .bottom) } }
                    }
                }
                // Typing a Margin: bring the whole composer, Add Margin included, up above the keyboard (#2963).
                .onChange(of: marginFieldFocused) { _, focused in
                    guard focused else { return }
                    Task {
                        try? await Task.sleep(for: .milliseconds(350)) // after the keyboard has finished rising
                        withAnimation { scroller.scrollTo(Self.composerId, anchor: .bottom) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.bone)
            .miniPlayerKeepOut()
            .navigationTitle("Live session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                // Return is a new line in a Margin, so Add Margin is on the keyboard itself, not below it (#2963).
                ToolbarItemGroup(placement: .keyboard) {
                    if marginFieldFocused {
                        Button("Done") { marginFieldFocused = false }
                        Spacer()
                        Button("Add Margin", action: submitMargin)
                            .fontWeight(.semibold)
                            .disabled(marginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("liveSession.addMargin.keyboard.button")
                    }
                }
            }
        }
        .onAppear { controller.load() }
        .onDisappear {
            unregisterRunningScreen()
            controller.stopPolling()
        }
        .onChange(of: links.pendingAction) { _, _ in applyLink() }
        .onChange(of: controller.didLoad) { _, _ in applyLink() }
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

    /// A tap on the Live Activity's Write a Margin or Speak a Margin (#2833): the written field is ready to type in,
    /// or the spoken Margin is already recording. Needs a running session; otherwise the screen just opens.
    private func applyLink() {
        guard controller.didLoad else { return }
        // Only a screen showing the running session takes a link; one open on an ended session leaves it waiting.
        guard controller.isRunning else { return unregisterRunningScreen() }
        if !isRegisteredRunning {
            isRegisteredRunning = true
            links.runningScreenAppeared()
        }
        guard let action = links.takeAction() else { return }
        switch action {
        case .open: break
        case .write:
            Task {
                try? await Task.sleep(for: .milliseconds(400)) // after the screen has finished presenting
                marginFieldFocused = true
            }
        case .speak: if !controller.isRecordingSpoken { controller.startSpokenMargin() }
        }
    }

    private func unregisterRunningScreen() {
        guard isRegisteredRunning else { return }
        isRegisteredRunning = false
        links.runningScreenDisappeared()
    }

    // MARK: Setup

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Take Margins on something outside the app: a meeting, an audiobook in another app, or a paper book. Nothing is recorded.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            Picker("Kind", selection: $kind) {
                ForEach(ElsewhereKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField(kind == .meeting ? "Meeting name" : "Title", text: $title)
                .textFieldStyle(.roundedBorder)
            if kind != .paper {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where are you now?").font(.headline)
                    TextField(kind == .meeting ? "Meeting clock, like 2:00" : "Time in the book, like 0:00", text: $startPosition)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                    Text(kind == .meeting ? "Leave blank if you're at the start." : "The time your audiobook app shows.")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
            }
            LiveSessionPlaceField(
                prompt: kind == .paper ? "Page, chapter or percent" : "Page, chapter or percent (optional)",
                defaultUnit: LiveSessionPlace.defaultUnit(for: kind), text: $startWhere
            )
            Button {
                let read = LiveSessionWhere.interpret(clockText: startPosition, whereText: startWhere, kind: kind)
                controller.start(
                    kind: kind, title: title,
                    startPositionMs: read.positionMs ?? (kind == .meeting ? 0 : nil),
                    startWhere: read.text, startPlace: read.place
                )
            } label: {
                Label("Start Session", systemImage: "record.circle").frame(maxWidth: .infinity, minHeight: 44)
            }
            .filledActionButton()
            .accessibilityIdentifier("liveSession.start")
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Running

    private func sessionHeader(_ session: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title.isEmpty ? "\(session.kind.label) session" : session.title).font(.headline)
                Spacer()
                if controller.isRunning {
                    Button(showsDetails ? "Done" : "Edit") { toggleDetails(session) }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("liveSession.editDetails")
                        .accessibilityHint("Change the kind, name, clock or chapter while the session runs.")
                }
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                clockBlock(session, at: context.date)
            }
            if let bracket = session.bracket {
                Text(bracket).font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            if controller.isRunning {
                Text("The Lock Screen has a Mark button for a quick blind Margin.").font(.caption).foregroundStyle(AppColors.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// The name and chapter are saved when the listener finishes with them, not on every keystroke.
    private func commitDrafts() {
        controller.setTitle(titleDraft)
        controller.setStartWhere(whereDraft)
    }

    /// While it runs, the big clock is the source's own (the meeting's elapsed time) and the session counter is the
    /// small line under it (#2834). Without a clock, or once it has ended, the session counter is the big one.
    @ViewBuilder
    private func clockBlock(_ session: LiveSession, at date: Date) -> some View {
        let sessionTime = LiveSessionPositionMap.clock(controller.elapsedMs(at: date))
        if controller.isRunning, let title = LiveSessionClock.title(for: session.kind),
           let position = controller.predictedPosition(at: date) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.secondaryText)
                Text(LiveSessionPositionMap.clock(position.ms))
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .accessibilityLabel("\(title) \(LiveSessionPositionMap.clock(position.ms))")
                Text("Session time \(sessionTime)").font(.subheadline.monospacedDigit()).foregroundStyle(AppColors.secondaryText)
                if session.kind == .meeting {
                    Text("Not where the meeting is? Tap Edit and say where it is now.")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(sessionTime)
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .accessibilityLabel("Session time \(sessionTime)")
                if let position = controller.predictedPosition(at: date) {
                    Text("Source: \(position.label)").font(.subheadline).foregroundStyle(AppColors.secondaryText)
                }
            }
        }
    }

    private func toggleDetails(_ session: LiveSession) {
        if showsDetails { commitDrafts() }
        if !showsDetails {
            titleDraft = session.title
            whereDraft = session.startWhere ?? ""
            clockDraft = ""
        }
        showsDetails.toggle()
    }

    /// Everything the start card asks, changeable while the session runs (#2832): starting stays one tap with
    /// blanks allowed.
    private func detailsCard(_ session: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Kind", selection: Binding(get: { session.kind }, set: { controller.setKind($0) })) {
                ForEach(ElsewhereKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField(session.kind == .meeting ? "Meeting name" : "Title", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitDrafts() }
            if session.kind != .paper {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Where are you now?").font(.subheadline.weight(.semibold))
                    HStack {
                        TextField(session.kind == .meeting ? "What the meeting's clock shows, like 12:30" : "Time in the book, like 1:23:10", text: $clockDraft)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                        Button("Set") {
                            guard let ms = LiveSessionPositionMap.parse(clockDraft) else {
                                controller.errorMessage = "Enter a time like 12:30 or 1:23:10."
                                return
                            }
                            if controller.setSourceClock(positionMs: ms) { clockDraft = "" }
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .disabled(clockDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Type it once and the clock runs from there. Margins you've already taken move with it.")
                        .font(.caption).foregroundStyle(AppColors.secondaryText)
                }
            }
            LiveSessionPlaceField(
                prompt: session.kind == .paper ? "Page, chapter or percent" : "Page, chapter or percent (optional)",
                defaultUnit: LiveSessionPlace.defaultUnit(for: session.kind), text: $whereDraft
            )
            .onSubmit { commitDrafts() }
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func guidance(_ kind: ElsewhereKind) -> String {
        switch kind {
        case .meeting: "Say something that helps place this, like \u{201C}Johnny was just talking about the budget\u{201D}"
        case .audiobook, .paper, .other: "Say something that helps place this, like \u{201C}I think this is chapter 5\u{201D}"
        }
    }

    private func marginComposer(_ session: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Margin").font(.headline)
            TextField(guidance(session.kind), text: $marginText, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .focused($marginFieldFocused)
                .accessibilityIdentifier("liveSession.marginText")
            if session.kind != .meeting {
                LiveSessionPlaceField(
                    prompt: session.kind == .paper ? "Page (optional)" : "Page, chapter or percent (optional)",
                    defaultUnit: LiveSessionPlace.defaultUnit(for: session.kind), text: $marginWhere
                )
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                if let position = controller.predictedPosition(at: context.date, adjustmentMs: adjustmentMs) {
                    PositionNudgeRow(label: adjustmentMs == 0 ? position.label : "you set \(LiveSessionPositionMap.clock(position.ms))", adjustmentMs: $adjustmentMs)
                }
            }
            Button(action: submitMargin) {
                Label("Add Margin", systemImage: "text.bubble").frame(maxWidth: .infinity, minHeight: 44)
            }
            .filledActionButton()
            .disabled(marginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("liveSession.addMargin.button")
            spokenMarginButton
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .id(Self.composerId)
    }

    /// Add Margin, from the button under the field or the one on the keyboard.
    private func submitMargin() {
        controller.addMargin(text: marginText, whereNote: marginWhere.isEmpty ? nil : marginWhere, adjustmentMs: adjustmentMs)
        marginText = ""
        marginWhere = ""
        adjustmentMs = 0
        marginFieldFocused = false
    }

    private static let composerId = "liveSession.composer"

    /// Speak a Margin on the phone (#2487). During a call it says to use the Watch: the call holds the microphone.
    private var spokenMarginButton: some View {
        Button {
            if controller.isRecordingSpoken { controller.stopSpokenMargin() } else { controller.startSpokenMargin() }
        } label: {
            Label(
                controller.isRecordingSpoken ? "Stop and Save Spoken Margin" : "Speak Margin",
                systemImage: controller.isRecordingSpoken ? "stop.circle.fill" : "mic"
            )
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityHint(controller.isRecordingSpoken ? "Recording. Tap to stop and save." : "Records a spoken Margin at this moment.")
    }

    private func marginList(_ session: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !session.margins.isEmpty {
                Text("Margins (\(session.margins.count))").font(.headline)
            }
            ForEach(session.margins) { margin in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(positionText(for: margin, in: session))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppColors.secondaryText)
                        Spacer()
                        Button { controller.removeMargin(id: margin.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove Margin")
                    }
                    if margin.isBlindMark {
                        TextField("Mark: add words to help place it (optional)", text: Binding(
                            get: { margin.text }, set: { controller.updateText(id: margin.id, text: $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    } else if margin.isSpoken {
                        Label {
                            Text(margin.spokenTranscript ?? "Spoken Margin")
                        } icon: {
                            Image(systemName: margin.spokenOn == "watch" ? "applewatch" : "mic")
                        }
                        .accessibilityLabel("Spoken on the \(margin.spokenOn == "watch" ? "Watch" : "phone"): \(margin.spokenTranscript ?? "not transcribed yet")")
                    } else {
                        Text(margin.text)
                    }
                    if let note = margin.filingNote {
                        Text("Filed \(note)").font(.caption).foregroundStyle(AppColors.secondaryText)
                    }
                    if let heard = margin.heardPlace {
                        heardPlaceOffer(heard, margin: margin)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Where a Margin is, in the unit the session uses: a page, percent or chapter is never shown as a time (#2707).
    private func positionText(for margin: LiveSessionMargin, in session: LiveSession) -> String {
        var text: String
        if let label = LiveSessionPlaceMap.label(for: margin, in: session) {
            text = label
        } else if session.usesPlaces {
            text = "\(LiveSessionPositionMap.clock(margin.sessionOffsetMs)) in"
        } else {
            text = LiveSessionPositionMap.position(of: margin, in: session).map { $0.isListenerSet ? "you set \(LiveSessionPositionMap.clock($0.ms))" : $0.label }
                ?? "\(LiveSessionPositionMap.clock(margin.sessionOffsetMs)) in"
        }
        // A place in another unit than the session's is kept beside it, not converted.
        if let place = margin.place, !text.hasSuffix(place.label) { text += " · \(place.label)" }
        return text
    }

    /// A page, percent or chapter said in the Margin, offered as a checkpoint: one tap to keep it, never automatic.
    private func heardPlaceOffer(_ heard: LiveSessionPlace, margin: LiveSessionMargin) -> some View {
        HStack(spacing: 8) {
            Text("Heard \u{201C}\(heard.label)\u{201D}. Keep it as a checkpoint?")
                .font(.caption).foregroundStyle(AppColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Keep") { controller.keepHeardPlace(id: margin.id) }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityHint("Uses \(heard.label) to place the Margins around this one.")
            Button("No") { controller.declineHeardPlace(id: margin.id) }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
        }
    }

    private static let endCardId = "liveSession.endCard"

    /// Ending asks "when did it end?" on the screen itself, not in a sheet (#2831): the sheet closed by itself before
    /// the listener could answer, and nothing on the screen can close this card but its own End and Cancel.
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

    private var endButton: some View {
        Button {
            if showsDetails { commitDrafts() }
            showsEndCard = true
        } label: {
            Label("End Session", systemImage: "stop.circle").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("liveSession.endSession")
    }

    /// Resume for the 10 minutes after End (#2883), the same as the Watch's and the Lock Screen card's. It goes when the
    /// window closes, without the screen needing to redraw for any other reason.
    @ViewBuilder
    private var resumeButton: some View {
        if let until = controller.resumeUntil {
            TimelineView(.explicit([min(Date.now, until), until])) { context in
                if context.date < until {
                    Button { controller.resume() } label: {
                        Label("Resume Session", systemImage: "play.circle").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .filledActionButton()
                    .accessibilityIdentifier("liveSession.resume")
                }
            }
        }
    }

    private func finishCard(_ session: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.isQuick == true ? "Quick session" : "Session ended").font(.headline)
            resumeButton
            ForEach(Array(LiveSessionPlaceMap.conflicts(in: session).enumerated()), id: \.offset) { _, conflict in
                Text(conflict.description()).font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            if let check = LiveSessionPlaceMap.clockCheck(for: session) {
                Text(check.note).font(.caption).foregroundStyle(AppColors.secondaryText)
                Button("Use the start the clock shows") { controller.useImpliedStart() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
            if session.kind == .meeting {
                Text("Line it up with the meeting's transcript (.vtt, .srt, .docx or .txt) to place your Margins on what was said. You can add the recording too.")
                    .font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            Button { showsLineUp = true } label: {
                Label("Line Up with a Transcript", systemImage: "text.alignleft").frame(maxWidth: .infinity, minHeight: 44)
            }
            .filledActionButton()
            Button {
                isSaving = true
                Task {
                    do {
                        try await model.saveLiveSession(session, transcript: nil, placed: [], recordingURL: nil)
                        model.hangTelemetry.labels.scoped("liveSessionSavedAsNotes") {
                            controller.close()
                            dismiss()
                        }
                    } catch {
                        controller.errorMessage = "Couldn't save: \(error.localizedDescription)"
                    }
                    isSaving = false
                }
            } label: {
                Label(isSaving ? "Saving…" : "Save as Notes", systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(isSaving)
            Button("Discard Session", role: .destructive) { confirmsDiscard = true }
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        Button(title) { adjustmentMs += delta }
            .buttonStyle(.bordered)
            .font(.caption.monospacedDigit())
            .frame(minHeight: 44)
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
            Text("End Session").font(.headline)
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
                    TextField(kind == .meeting ? "Meeting clock, like 47:30" : "Time in the book, like 1:23:10", text: $endPosition)
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
            Button("It's still going. Remind me in 15 minutes", action: onStillGoing)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("liveSession.stillGoing")
            Button("Cancel", action: onCancel)
                .frame(maxWidth: .infinity, minHeight: 44)
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
            TextField(prompt, text: $text)
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
