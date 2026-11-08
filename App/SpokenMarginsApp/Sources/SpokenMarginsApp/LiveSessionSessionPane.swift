import SessionKit
import SwiftUI

/// The Session pane of the live session screen (#3491): what the session is. Kind, name, a description, the time it
/// started, and where the source is now. The kind and name change only while it runs; the description and the start
/// time stay editable until the session is saved. Words are kept when the listener finishes with a field, not on
/// every keystroke, so the Lock Screen card isn't rewritten as they type.
struct LiveSessionSessionPane<Header: View>: View {
    let session: LiveSession
    let isRunning: Bool
    let setKind: (ElsewhereKind) -> Void
    let setTitle: (String) -> Void
    let setDescription: (String) -> Void
    let setStartWhere: (String) -> Void
    /// Returns false, with the reason shown by the screen, for a time that can't be.
    let setStatedStart: (Date) -> Bool
    let setSourceClock: (Int) -> Bool
    let showError: (String) -> Void
    /// The ended session's choices, at the top while it has ended (the screen's `finishCard`).
    @ViewBuilder let header: () -> Header

    private enum Field: Hashable { case title, description, place, clock }

    @FocusState private var focus: Field?
    @State private var titleDraft = ""
    @State private var descriptionDraft = ""
    @State private var whereDraft = ""
    @State private var clockDraft = ""
    @State private var startedDraft = Date()
    @State private var loadedFor: String?

    private var shownStart: Date { session.statedStartedAt ?? session.startedAt }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header()
                card {
                    Picker("Kind", selection: Binding(get: { session.kind }, set: setKind)) {
                        ForEach(ElsewhereKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!isRunning)
                    .accessibilityIdentifier("liveSession.kind")
                    AppTextField(session.kind == .meeting ? "Meeting name" : "Title", text: $titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .title)
                        .disabled(!isRunning)
                        .onSubmit(commit)
                        .accessibilityIdentifier("liveSession.session.title")
                    AppTextField("What is this about? (optional)", text: $descriptionDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .description)
                        .accessibilityIdentifier("liveSession.session.description")
                    DatePicker(
                        "Started at", selection: $startedDraft, in: ...startLimit,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("liveSession.session.startedAt")
                    Text("If you pressed Start late, say when it really began. The clock and your Margins' places don't change.")
                        .font(.caption).foregroundStyle(AppColors.watchSecondary)
                }
                card {
                    if session.kind != .paper && isRunning {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Where are you now?").font(.subheadline.weight(.semibold))
                            HStack {
                                AppTextField(
                                    session.kind == .meeting ? "What the meeting's clock shows, like 12:30" : "Time in the book, like 1:23:10",
                                    text: $clockDraft
                                )
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numbersAndPunctuation)
                                .focused($focus, equals: .clock)
                                Button(action: setClock) { Text("Set").minimumTapTarget() }
                                    .buttonStyle(.bordered)
                                    .tint(.white)
                                    .disabled(clockDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            Text("Type it once and the clock runs from there. Margins you've already taken move with it.")
                                .font(.caption).foregroundStyle(AppColors.watchSecondary)
                        }
                    }
                    LiveSessionPlaceField(
                        prompt: session.kind == .paper ? "Page, chapter or percent" : "Page, chapter or percent (optional)",
                        defaultUnit: LiveSessionPlace.defaultUnit(for: session.kind), text: $whereDraft
                    )
                    .focused($focus, equals: .place)
                    .disabled(!isRunning)
                    .onSubmit(commit)
                    if let bracket = session.bracket {
                        Text(bracket).font(.caption).foregroundStyle(AppColors.watchSecondary)
                    }
                    if isRunning {
                        Text("The Lock Screen has a Mark button for a quick blind Margin.")
                            .font(.caption).foregroundStyle(AppColors.watchSecondary)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveSession.session.screen")
        .onAppear(perform: load)
        .onChange(of: session.id) { _, _ in load() }
        .onChange(of: focus) { old, _ in if old != nil { commit() } }
        .onChange(of: startedDraft) { _, date in
            guard date != shownStart else { return }
            if !setStatedStart(date) { startedDraft = shownStart }
        }
        .onChange(of: session.statedStartedAt) { _, _ in startedDraft = shownStart }
        .onDisappear(perform: commit)
    }

    /// A start can't be in the future or after the end.
    private var startLimit: Date { min(session.endedAt ?? .distantFuture, Date()) }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private func load() {
        guard loadedFor != session.id else { return }
        loadedFor = session.id
        titleDraft = session.title
        descriptionDraft = session.sessionDescription ?? ""
        whereDraft = session.startWhere ?? ""
        startedDraft = shownStart
    }

    private func commit() {
        guard loadedFor == session.id else { return }
        if isRunning {
            setTitle(titleDraft)
            setStartWhere(whereDraft)
        }
        setDescription(descriptionDraft)
    }

    private func setClock() {
        guard let ms = LiveSessionPositionMap.parse(clockDraft) else {
            showError("Enter a time like 12:30 or 1:23:10.")
            return
        }
        if setSourceClock(ms) { clockDraft = "" }
    }
}
