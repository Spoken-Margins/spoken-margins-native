import SwiftUI
import SessionKit

/// Settings › Import & Export answers "which folder is this?" (#3770, Design PR 3, as amended by #4274 section 3b): the
/// Quick Folder row, its screen, and the "can't open" section that Following's folder screen shows too. Every word comes
/// from `QuickFolderStatus` (SessionKit, host-tested), built here from what `QuickAccessFolderState` remembers, so Settings,
/// Following, Your AI and the Add sheet can't word the same folder differently. Nothing here resolves the bookmark: the
/// views draw stored values, and the scan does its own resolving off the main actor.
///
/// New files only ever wait on Following (owner decision, #4274), so there is no New Files choice and no last-problem row.

extension QuickAccessFolderState {
    /// What the app remembers about the folder, as the words every surface shows. `newCount` is the count Following shows.
    func status(newCount: Int = 0, now: Date = Date()) -> QuickFolderStatus {
        QuickFolderStatus(
            name: folderName == Self.noFolderName ? nil : folderName,
            path: folderPath,
            lastCheckedAt: lastCheckedAt,
            problem: problem,
            newCount: newCount,
            now: now
        )
    }
}

extension Gate1AppModel {
    /// New files in the Quick Folder: the files Following lists, already filtered for what is added or dismissed.
    var quickFolderNewFiles: [QuickAddCandidate] {
        quickAddCandidates.filter { if case .localFile = $0 { true } else { false } }
    }
}

/// The Quick Folder row, first in Settings › Import & Export. With no folder: "Quick Folder", "None chosen" and a Choose
/// Folder button. With one: the name, the location once known, and the check and new-files line, opening the screen.
/// It observes only the folder's state, so a model publish doesn't redraw Settings for it.
struct QuickFolderSettingsRow: View {
    let model: Gate1AppModel
    @ObservedObject private var quickAccess: QuickAccessFolderState

    init(model: Gate1AppModel) {
        self.model = model
        _quickAccess = ObservedObject(wrappedValue: model.quickAccess)
    }

    var body: some View {
        let status = quickAccess.status()
        if status.hasFolder {
            NavigationLink {
                QuickFolderSettingsScreen(model: model).miniPlayerKeepOut()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label(status.displayName, systemImage: "folder")
                    if let location = status.settingsLocationLine {
                        Text(location)
                            .font(.footnote)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    statusLine(status)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status.settingsAccessibilityLabel)
            }
            .accessibilityIdentifier("settings.quickFolder.row")
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Quick Folder", systemImage: "folder")
                    Text(QuickFolderStatus.noneChosen)
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status.settingsAccessibilityLabel)
                .accessibilityIdentifier("settings.quickFolder.row")
                Spacer()
                QuickFolderPickerButton(
                    hasWorkingFolder: false,
                    accessibilityIdentifier: "settings.quickFolder.choose",
                    choose: { model.configureQuickAccessFolder(url: $0) },
                    failed: { model.reportImportFailure($0) }
                )
                .buttonStyle(.borderless)
            }
        }
    }

    /// Line 3: the check and new-files part, or the warning when the folder can't be opened. The icon and the words carry the
    /// state, never colour alone.
    @ViewBuilder private func statusLine(_ status: QuickFolderStatus) -> some View {
        if let symbol = status.settingsStatusSymbol {
            Label(status.settingsStatusLine, systemImage: symbol)
                .font(.footnote)
                .foregroundStyle(AppColors.text)
        } else {
            Text(status.settingsStatusLine)
                .font(.footnote)
                .foregroundStyle(AppColors.secondaryText)
        }
    }
}

/// "Can't open this folder", with Check Now and Choose Folder Again. Settings' Quick Folder screen and Following's folder
/// screen both show it. Choose Folder Again on the same path keeps the seen and dismissed files; any other folder is a fresh
/// baseline (`QuickFolderReconnectRule`).
struct QuickFolderCantOpenSection: View {
    let model: Gate1AppModel
    let isChecking: Bool

    var body: some View {
        Section {
            Label(QuickFolderStatus.cantOpenTitle, systemImage: QuickFolderStatus.cantOpenSymbol)
                .font(.headline)
                .foregroundStyle(AppColors.text)
            Text(QuickFolderStatus.cantOpenMessage)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            QuickFolderCheckNowButton(model: model, isChecking: isChecking)
            QuickFolderPickerButton(
                hasWorkingFolder: false,
                title: "Choose Folder Again",
                accessibilityIdentifier: "quickFolderSettings.chooseAgain",
                choose: { model.reconnectQuickAccessFolder(url: $0) },
                failed: { model.reportImportFailure($0) }
            )
        }
    }
}

/// Scans the folder now. While a scan runs it is disabled and reads "Checking…".
struct QuickFolderCheckNowButton: View {
    let model: Gate1AppModel
    let isChecking: Bool

    var body: some View {
        Button(isChecking ? "Checking…" : "Check Now") { model.refreshQuickAccessFolder() }
            .disabled(isChecking)
            .accessibilityIdentifier("quickFolderSettings.checkNow")
    }
}

/// The Quick Folder's own screen (Design PR 3): where it is, when it was last checked, how many files are new, and Check
/// Now, Change Folder and Remove Folder. Removing never touches the Library, the play queue or the folder's files.
struct QuickFolderSettingsScreen: View {
    let model: Gate1AppModel
    @ObservedObject private var quickAccess: QuickAccessFolderState
    @State private var confirmsRemove = false
    @Environment(\.dismiss) private var dismiss

    init(model: Gate1AppModel) {
        self.model = model
        _quickAccess = ObservedObject(wrappedValue: model.quickAccess)
    }

    var body: some View {
        let status = quickAccess.status(newCount: model.quickFolderNewFiles.count)
        let isChecking = quickAccess.isRefreshing
        Form {
            if status.cantOpen {
                QuickFolderCantOpenSection(model: model, isChecking: isChecking)
            }
            Section {
                if let location = status.locationLine {
                    LabeledContent("Location", value: location)
                        .accessibilityIdentifier("quickFolderSettings.location")
                }
                LabeledContent("Last checked", value: status.lastCheckedValue(isChecking: isChecking))
                    .accessibilityIdentifier("quickFolderSettings.lastChecked")
                LabeledContent("New files", value: status.newFilesValue)
                    .accessibilityIdentifier("quickFolderSettings.newFilesCount")
            } header: {
                Text("Folder")
            } footer: {
                Text(QuickFolderStatus.newFilesFooter)
            }
            Section("Actions") {
                // The can't-open section above has its own Check Now.
                if !status.cantOpen {
                    QuickFolderCheckNowButton(model: model, isChecking: isChecking)
                }
                QuickFolderPickerButton(
                    hasWorkingFolder: true,
                    accessibilityIdentifier: "quickFolderSettings.change",
                    choose: { model.configureQuickAccessFolder(url: $0) },
                    failed: { model.reportImportFailure($0) }
                )
                Button("Remove Folder", role: .destructive) { confirmsRemove = true }
                    .accessibilityIdentifier("quickFolderSettings.remove")
            }
        }
        .navigationTitle(status.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("quickFolderSettings.screen")
        .confirmationDialog(status.removeConfirmationTitle, isPresented: $confirmsRemove, titleVisibility: .visible) {
            Button("Remove Folder", role: .destructive) {
                model.removeQuickAccessFolder()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(QuickFolderStatus.removeConfirmationMessage)
        }
    }
}
