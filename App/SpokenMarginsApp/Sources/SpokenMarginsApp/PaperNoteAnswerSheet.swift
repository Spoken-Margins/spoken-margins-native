import SessionKit
import SwiftUI

/// The Paper note's Write sheet (#4340, PR 5 of the Design): one role at a time ("Purpose"), its question, a text box the
/// listener types or dictates into, and the place the answer will sit, with Change to pick the start of the paper or of a
/// page. Save writes a written Margin carrying the role (`Gate1AppModel.writePaperAnswer`) and moves to the next empty slot;
/// with none left the sheet closes. Done with unsaved text asks first. The places, words and prompt order are SessionKit's
/// (`PaperNoteWriteContext`, `PaperNoteWritePrompts`).
struct PaperNoteAnswerSheet: View {
    struct Request: Identifiable {
        /// The slot whose Add was tapped; the sheet asks for it first.
        let role: PaperNoteRole
        /// The answer "Change answer" replaces: the sheet asks for this role only, and the old Margin gives it up.
        var replacing: Interjection? = nil
        let id = UUID()
    }

    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    let slots: PaperNoteSlots
    let document: StructuredDocument?
    let replacing: Interjection?

    @State private var prompts: PaperNoteWritePrompts
    @State private var context: PaperNoteWriteContext?
    @State private var loaded = false
    @State private var text = ""
    @State private var choice: PaperNotePlace.Choice = .startOfPaper
    /// Made when each prompt opens, so a second tap on Save writes nothing more.
    @State private var draftId = UUID().uuidString
    @State private var savedLine: String?
    @State private var errorLine: String?
    @State private var confirmingDiscard = false
    @FocusState private var editorFocused: Bool

    init(request: Request, slots: PaperNoteSlots, document: StructuredDocument?) {
        self.slots = slots
        self.document = document
        replacing = request.replacing
        _prompts = State(initialValue: request.replacing == nil
            ? PaperNoteWritePrompts(start: request.role, slots: slots) : PaperNoteWritePrompts(only: request.role))
    }

    private var hasDraft: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if let context, context.canWrite, let role = prompts.current {
                    form(role: role, context: context)
                } else if loaded {
                    Text(PaperNoteSlots.footnote(canWrite: false) ?? "")
                        .foregroundStyle(AppColors.secondaryText)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(AppColors.bone)
            .navigationTitle(prompts.current.map(PaperNoteSlots.slotName) ?? PaperNoteSlots.heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", action: close).accessibilityIdentifier("paperNote.write.done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!hasDraft || context?.canWrite != true)
                        .accessibilityIdentifier("paperNote.write.save")
                }
            }
            .confirmationDialog(PaperNoteWriteContext.discardTitle, isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button(PaperNoteWriteContext.discard, role: .destructive) { dismiss() }
                Button(PaperNoteWriteContext.keepWriting, role: .cancel) {}
            }
        }
        .tint(AppColors.evergreen)
        .interactiveDismissDisabled(hasDraft)
        .task {
            let fresh = await model.paperNoteWriteContext(document: document)
            context = fresh
            choice = fresh?.defaultChoice ?? .startOfPaper
            loaded = true
        }
    }

    private func form(role: PaperNoteRole, context: PaperNoteWriteContext) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let savedLine {
                    Label(savedLine, systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.evergreen)
                        .accessibilityIdentifier("paperNote.write.saved")
                }
                Text(PaperNoteSlots.question(role))
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                    .fixedSize(horizontal: false, vertical: true)
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(PaperNoteWriteContext.placeholder)
                            .foregroundStyle(AppColors.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: $text)
                        .focused($editorFocused)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140)
                        .accessibilityLabel(PaperNoteSlots.slotName(role))
                        .accessibilityHint(PaperNoteWriteContext.placeholder)
                        .accessibilityIdentifier("paperNote.write.text")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.inputBackground))
                .onAppear { editorFocused = true }
                placeRow(context)
                if let errorLine {
                    Label(errorLine, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.dangerText)
                        .accessibilityIdentifier("paperNote.write.error")
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func placeRow(_ context: PaperNoteWriteContext) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(context.placeLine(choice))
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityIdentifier("paperNote.write.place")
            Spacer(minLength: 8)
            Menu {
                ForEach(context.choices, id: \.self) { option in
                    Button(context.menuTitle(option)) { choose(option) }
                }
            } label: {
                Text("Change").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Change where this answer sits")
            .accessibilityIdentifier("paperNote.write.change")
        }
        if case .startOfPage(let page) = choice, let pageCount = context.pageCount {
            Picker(PaperNoteWriteContext.pagePickerTitle, selection: Binding(get: { page }, set: { pickPage($0) })) {
                ForEach(1...pageCount, id: \.self) { Text("p. \($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("paperNote.write.page")
        }
    }

    /// The page picker: any page, p. 1 included. Only the Change menu goes through `choose`.
    private func pickPage(_ page: Int) {
        choice = .startOfPage(page)
        errorLine = nil
    }

    /// The Change menu. Its "Start of a page…" entry sends p. 1; picked again, it keeps the page already chosen.
    private func choose(_ option: PaperNotePlace.Choice) {
        // "Start of a page…" again keeps the page already picked.
        if case .startOfPage = option, case .startOfPage = choice, option == .startOfPage(1) { return errorLine = nil }
        choice = option
        errorLine = nil
    }

    private func save() {
        guard let context, let role = prompts.current, hasDraft else { return }
        guard (try? context.character(for: choice)) != nil else {
            errorLine = PaperNoteWriteContext.placeFailed
            return
        }
        guard model.writePaperAnswer(
            draftId: draftId, role: role, text: text, choice: choice, context: context, replacing: replacing) else {
            errorLine = PaperNoteWriteContext.saveFailed
            return
        }
        prompts.advance()
        guard prompts.current != nil else { return dismiss() }
        // The next prompt starts clean, at "Where you are" again (the Design).
        savedLine = PaperNoteWriteContext.savedLine(role)
        text = ""
        errorLine = nil
        draftId = UUID().uuidString
        choice = context.defaultChoice
        editorFocused = true
    }

    private func close() {
        if hasDraft { confirmingDiscard = true } else { dismiss() }
    }
}
