import SwiftUI
import SessionKit

/// The Settings row for the Import Inbox: one line that says what is waiting, and a page behind it (#4781).
///
/// The Inbox used to be a group inside Settings that opened itself on every visit while it held a failure, so the
/// listener scrolled past it to reach Share Diagnostics. The row shows the count instead, and opening it is a tap.
struct ImportInboxRow: View {
    let summary: ImportInboxSummary

    var body: some View {
        NavigationLink(value: SettingsPage.importInbox) {
            LabeledContent {
                if let text = summary.trailingText {
                    HStack(spacing: 4) {
                        if let symbol = summary.symbolName {
                            Image(systemName: symbol).accessibilityHidden(true)
                        }
                        Text(text)
                    }
                    // Amber, never red or green alone, and always with its icon and words.
                    .foregroundStyle(AppColors.warningText)
                }
            } label: {
                Label("Import Inbox", systemImage: "tray")
            }
        }
        .accessibilityValue(summary.accessibilityValue)
        .accessibilityIdentifier("settings.importInbox.link")
    }
}

/// Failed shares, each with Retry and Delete, and the links waiting for a connection (#4781).
///
/// It reads through its own feed and is shown `.equatable()`, like Settings (#4028, #4066): a playback tick doesn't
/// redraw it. It calls no refresh of its own; Settings' `onAppear` refresh, Delete and the import drain keep it current.
struct ImportInboxScreen: View, Equatable {
    let model: Gate1AppModel
    @StateObject private var feed: ScreenInputsFeed<Inputs>
    @State private var pendingDeletion: ImportInboxEntry?
    /// Entries whose retry is queued. Their Retry waits while the import runs, so a second tap can't hit a payload
    /// already being imported. Cleared whenever the list changes: a retry that fails again comes back with Retry on.
    @State private var retryingIDs: Set<String> = []

    init(model: Gate1AppModel) {
        self.model = model
        _feed = StateObject(wrappedValue: ScreenInputsFeed(model: model, read: Inputs.init))
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
    }

    struct Inputs: Equatable {
        var entries: [ImportInboxEntry]
        var waitingCount: Int

        @MainActor init(_ model: Gate1AppModel) {
            entries = model.importInbox
            waitingCount = model.sourceLinksWaitingForNetwork
        }
    }

    var body: some View {
        let inputs = feed.inputs
        Form {
            if inputs.waitingCount > 0 {
                Section {
                    PendingLinksWaitingLine(count: inputs.waitingCount)
                } footer: {
                    Text("They import on their own once the connection works again.")
                }
            }
            if !inputs.entries.isEmpty {
                Section("Failed shares") {
                    ForEach(inputs.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.title)
                                .font(.headline)
                            Text(entry.source)
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .lineLimit(2)
                            FailureMessageLabel(entry.reason)
                                .font(.caption)
                            HStack {
                                Button("Retry") {
                                    if model.retryImportInboxEntry(entry) { retryingIDs.insert(entry.id) }
                                }
                                .buttonStyle(.borderless)
                                .disabled(retryingIDs.contains(entry.id))
                                .accessibilityIdentifier("importInbox.retry.\(entry.id)")
                                Button("Delete", role: .destructive) {
                                    pendingDeletion = entry
                                }
                                .buttonStyle(.borderless)
                                .accessibilityIdentifier("importInbox.delete.\(entry.id)")
                            }
                        }
                    }
                }
            }
            if inputs.entries.isEmpty && inputs.waitingCount == 0 {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No failed shares.")
                            .foregroundStyle(AppColors.secondaryText)
                        Text("Links and articles you share to Spoken Margins that can't be added show up here, so you can retry or delete them.")
                            .font(.footnote)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityIdentifier("importInbox.screen")
        .scrollContentBackground(.hidden)
        .background(AppColors.bone)
        .tint(AppColors.evergreen)
        .navigationTitle("Import Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .onCompatibleChange(of: inputs.entries) { _ in retryingIDs.removeAll() }
        .confirmationDialog(
            "Delete this?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { entry in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.deleteImportInboxEntry(entry)
                pendingDeletion = nil
            }
            .accessibilityIdentifier("importInbox.delete.confirm")
        } message: { entry in
            Text("\(entry.title) will be removed. You would have to share it again to add it.")
        }
    }
}
