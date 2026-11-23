import SwiftUI
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

/// Settings › Import & Export › **Your AI** (#4683, Design 2b): the prompt a listener copies into their own AI (Claude,
/// ChatGPT or another) so it writes a daily brief and suggests shows, where those briefs arrive, and what their AI can
/// read. Spoken Margins runs no AI here and sends nothing to one; nothing on the screen fetches.
///
/// It holds no logic of its own: the prompt is `AssistantSetupPrompt`, the folder's words are `QuickFolderStatus`, and
/// "Last list" is `LinkListArrivalRecord`, each host-tested in SessionKit. It observes only the Quick Folder's state,
/// never the whole model, so a model publish while audio renders doesn't redraw the form under the listener's typing.
///
/// There is no "Queue New Quick Folder Files" switch here, though the Design placed one: the owner decided on 2026-11-17
/// to remove that setting (#4274), so a list the AI saves in the Quick Folder waits on Following like any new file.
struct YourAISettingsScreen: View {
    let model: Gate1AppModel
    @ObservedObject private var quickAccess: QuickAccessFolderState
    /// What the brief is for. It stays on this iPhone and goes into the prompt only when copied or shared.
    @AppStorage(AssistantSetupPrompt.notesDefaultsKey) private var notes = ""
    /// The last list that arrived, as `LinkListArrivalRecord` stores it; read live so the row updates while open.
    @AppStorage(LinkListArrivalRecord.defaultsKey) private var lastArrivalData: Data?

    init(model: Gate1AppModel) {
        self.model = model
        _quickAccess = ObservedObject(wrappedValue: model.quickAccess)
    }

    var body: some View {
        Form {
            Section {
                Text("Your own AI can pick things for a daily brief and find shows for you to follow. Spoken Margins doesn't run an AI and sends nothing to one. Your AI sees only what you copy or share.")
            }
            startSection
            arrivalSection
            readSection
        }
        .navigationTitle("Your AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Start

    private var startSection: some View {
        Section("Start") {
            VStack(alignment: .leading, spacing: 6) {
                Text("What your brief is for")
                    .font(.subheadline)
                // `AppTextField` draws its placeholder in the app's contrast-checked colour (AppColorUsageGuardTests).
                AppTextField("This month I'm learning about soil. Homework: chapter 4 of Dirt.", text: $notes, axis: .vertical)
                    .lineLimit(2...8)
                    .accessibilityLabel("What your brief is for")
                    .accessibilityIdentifier("yourAI.notes")
                    .onChange(of: notes) { _, newValue in
                        // Typing stops at the prompt's limit; a paste is cut to it.
                        if newValue.count > AssistantSetupPrompt.maxNotesCharacters {
                            notes = String(newValue.prefix(AssistantSetupPrompt.maxNotesCharacters))
                        }
                    }
                Text("Optional. It stays on this iPhone and goes into the prompt only when you copy or share it.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            }
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = promptText()
                #endif
                model.reportConfirmation("Copied. Paste it into a chat with your AI.")
            } label: {
                Label("Copy Prompt for Your AI", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("yourAI.copyPrompt")
            ShareLink(item: promptText()) {
                Label("Share Prompt", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("yourAI.sharePrompt")
        }
    }

    /// The prompt as of now: today's date, the listener's notes, and the Quick Folder's name once one is chosen.
    private func promptText() -> String {
        let status = folderStatus
        return AssistantSetupPrompt.make(date: Date(), notes: notes, quickFolderName: status.hasFolder ? status.name : nil)
    }

    // MARK: Where your brief arrives

    private var folderStatus: QuickFolderStatus {
        let name = quickAccess.folderName == QuickAccessFolderState.noFolderName ? nil : quickAccess.folderName
        return QuickFolderStatus(
            name: name, path: quickAccess.folderPath, lastCheckedAt: quickAccess.lastCheckedAt, problem: quickAccess.problem)
    }

    private var arrivalSection: some View {
        let status = folderStatus
        return Section("Where your brief arrives") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Quick Folder") {
                    if status.cantOpen {
                        Label(QuickFolderStatus.cantOpenTitle, systemImage: QuickFolderStatus.cantOpenSymbol)
                    } else {
                        Text(status.hasFolder ? status.displayName : QuickFolderStatus.noneChosen)
                    }
                }
                .accessibilityIdentifier("yourAI.quickFolder")
                QuickFolderPickerButton(
                    hasWorkingFolder: status.hasFolder && !status.cantOpen,
                    choose: { model.configureQuickAccessFolder(url: $0) },
                    failed: { model.reportImportFailure($0) }
                )
                .buttonStyle(.borderless)
                Text("If your AI can save files, it can save each brief in your Quick Folder. It waits in Following until you add it, and then it becomes a collection in your Library.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
            }
            Text("No folder? Copy your AI's reply, then tap Paste & go in Add to Library.")
            Text("In Shortcuts, Add Link List to Spoken Margins takes a list from a file or text, such as a web address's contents. It's added when you next open the app.")
            LabeledContent("Last list", value: lastListValue)
                .accessibilityIdentifier("yourAI.lastList")
        }
    }

    private var lastListValue: String {
        LinkListArrivalRecord.lastListValue(lastArrivalData.flatMap(LinkListArrivalRecord.decode)) { date in
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            return formatter.string(from: date)
        }
    }

    // MARK: What your AI can read

    private var readSection: some View {
        Section("What your AI can read") {
            ExportListeningSignalsButton(
                exportFileURL: { [model] in await model.listeningSignals.exportFileURL() },
                accessibilityIdentifier: "yourAI.exportListeningSignals"
            )
            Text("Counts and titles for shows you follow: what you finish, share and leave Margins on. Never your Margins' words.")
                .font(.footnote)
                .foregroundStyle(AppColors.secondaryText)
            Text("To let your AI read your Margins' words, export them yourself from the Margins tab as AI Handoff Markdown. Nothing goes on its own.")
        }
    }
}
