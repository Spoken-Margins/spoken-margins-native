import SessionKit
import SwiftUI

/// Live session (#1989, #2481, prototype): Margins on a clock while a meeting, an audiobook in another app or
/// a paper book goes on outside Spoken Margins. Nothing is recorded. Afterwards a meeting lines up with its
/// transcript (and recording, if the listener has it); anything else is saved as session notes.
struct LiveSessionView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: LiveSessionController

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
    // Ending
    @State private var showsEndSheet = false
    @State private var showsLineUp = false
    @State private var confirmsDiscard = false
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let session = controller.session {
                        sessionHeader(session)
                        if controller.isRunning { marginComposer(session) }
                        marginList(session)
                        if controller.hasEnded { finishCard(session) } else { endButton }
                    } else {
                        setupCard
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.bone)
            .miniPlayerKeepOut()
            .navigationTitle("Live session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
            }
        }
        .onAppear { controller.load() }
        .onDisappear { controller.stopPolling() }
        .sheet(isPresented: $showsEndSheet) {
            LiveSessionEndSheet(kind: controller.session?.kind ?? .meeting, startedAt: controller.session?.startedAt ?? Date()) { when, endPosition, endWhere in
                if controller.end(when: when, endPositionMs: endPosition, endWhere: endWhere) { showsEndSheet = false }
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
            TextField(kind == .paper ? "Chapter or page" : "Chapter or page (optional)", text: $startWhere)
                .textFieldStyle(.roundedBorder)
            Button {
                controller.start(
                    kind: kind, title: title,
                    startPositionMs: kind == .paper ? nil : (LiveSessionPositionMap.parse(startPosition) ?? (kind == .meeting ? 0 : nil)),
                    startWhere: startWhere.isEmpty ? nil : startWhere
                )
            } label: {
                Label("Start Session", systemImage: "record.circle").frame(maxWidth: .infinity, minHeight: 44)
            }
            .filledActionButton()
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Running

    private func sessionHeader(_ session: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title.isEmpty ? "\(session.kind.label) session" : session.title).font(.headline)
            Text(LiveSessionPositionMap.clock(controller.elapsedMs))
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityLabel("Session time \(LiveSessionPositionMap.clock(controller.elapsedMs))")
            if let position = controller.predictedPosition() {
                Text("Source now: \(position.label)").font(.subheadline).foregroundStyle(AppColors.secondaryText)
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
            if session.kind == .paper {
                TextField("Page (optional)", text: $marginWhere).textFieldStyle(.roundedBorder)
            }
            if let position = controller.predictedPosition(adjustmentMs: adjustmentMs) {
                PositionNudgeRow(label: adjustmentMs == 0 ? position.label : "you set \(LiveSessionPositionMap.clock(position.ms))", adjustmentMs: $adjustmentMs)
            }
            Button {
                controller.addMargin(text: marginText, whereNote: marginWhere.isEmpty ? nil : marginWhere, adjustmentMs: adjustmentMs)
                marginText = ""
                marginWhere = ""
                adjustmentMs = 0
                marginFieldFocused = false
            } label: {
                Label("Add Margin", systemImage: "text.bubble").frame(maxWidth: .infinity, minHeight: 44)
            }
            .filledActionButton()
            .disabled(marginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            spokenMarginButton
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

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
                        Text(LiveSessionPositionMap.position(of: margin, in: session).map { $0.isListenerSet ? "you set \(LiveSessionPositionMap.clock($0.ms))" : $0.label }
                             ?? "\(LiveSessionPositionMap.clock(margin.sessionOffsetMs)) in")
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
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var endButton: some View {
        Button { showsEndSheet = true } label: {
            Label("End Session", systemImage: "stop.circle").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private func finishCard(_ session: LiveSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.isQuick == true ? "Quick session" : "Session ended").font(.headline)
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

/// Asks where the listener is at the end. Skippable; nudged for audiobooks, where it sets the pace.
private struct LiveSessionEndSheet: View {
    let kind: ElsewhereKind
    let startedAt: Date
    let onEnd: (LiveSessionEnd.When, Int?, String?) -> Void
    @State private var endPosition = ""
    @State private var endWhere = ""
    /// Index into the quick choices; one past the last is "At a time".
    @State private var whenIndex = 0
    @State private var clockTime = Date()
    /// Fixed when the sheet opens, so the offered choices don't shift while it is up.
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
        NavigationStack {
            Form {
                Section {
                    Picker("When did it end?", selection: $whenIndex) {
                        ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                            Text(choice.label).tag(index)
                        }
                        Text("At a time…").tag(choices.count)
                    }
                    if whenIndex >= choices.count {
                        DatePicker("Time", selection: $clockTime, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("If you stopped a while ago, say so: it keeps your Margins' places close.")
                }
                if kind != .paper {
                    Section {
                        TextField(kind == .meeting ? "Meeting clock, like 47:30" : "Time in the book, like 1:23:10", text: $endPosition)
                            .keyboardType(.numbersAndPunctuation)
                    } header: {
                        Text("Where are you now?")
                    } footer: {
                        Text(kind == .audiobook
                             ? "Worth filling in: it tells Spoken Margins your listening speed and pauses, so each Margin's place is closer."
                             : "Optional.")
                    }
                }
                Section {
                    TextField("Chapter or page (optional)", text: $endWhere)
                }
            }
            .miniPlayerKeepOut()
            .navigationTitle("End Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("End") {
                        onEnd(when, LiveSessionPositionMap.parse(endPosition), endWhere.isEmpty ? nil : endWhere)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
