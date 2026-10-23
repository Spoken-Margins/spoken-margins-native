import SwiftUI
import UniformTypeIdentifiers
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

/// The Margin Output status line. A failure is drawn with the failure icon, so a listener can
/// tell it from ordinary status without relying on colour (#308).
struct MarginOutputStatus: Equatable {
    let message: String
    var isFailure = false

    init(_ message: String, isFailure: Bool = false) {
        self.message = message
        self.isFailure = isFailure
    }

    static func failure(_ message: String) -> MarginOutputStatus {
        MarginOutputStatus(message, isFailure: true)
    }
}

/// Plain footnote text, or the failure label when the message reports a failure (#308).
struct StatusMessageText: View {
    let message: String
    let isFailure: Bool

    var body: some View {
        if isFailure { FailureMessageLabel(message).font(.footnote) } else { Text(message).font(.footnote) }
    }
}

/// Margin Output in Settings (#492): the listener's notes destinations, each opening to its own settings.
struct MarginOutputSettingsSection: View {
    @EnvironmentObject private var model: Gate1AppModel
    var body: some View {
        MarginOutputDestinationsSection(coordinator: model.marginOutput)
    }
}

struct MarginOutputDestinationsSection: View {
    private enum FolderPick: Equatable {
        case add
        case reselect(String)
    }

    @ObservedObject var coordinator: MarginOutputCoordinator
    @State private var pick = FolderPick.add
    @State private var choosingFolder = false

    var body: some View {
        Section("Margin Output") {
            ForEach(coordinator.rows) { row in
                NavigationLink {
                    MarginOutputDestinationScreen(coordinator: coordinator, id: row.id)
                        .miniPlayerKeepOut()
                } label: {
                    MarginOutputDestinationRow(row: row)
                }
                if row.needsAccess {
                    Button("Reselect Folder", systemImage: "folder.badge.questionmark") { choose(.reselect(row.id)) }
                }
            }
            Button { choose(.add) } label: {
                Label(coordinator.destinations.isEmpty ? "Choose Notes Folder" : "Add Destination", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier("settings.marginOutput.add")
            if let notice = coordinator.notice { StatusMessageText(message: notice.message, isFailure: notice.isFailure) }
            if coordinator.destinations.contains(where: \.isEnabled) {
                Button("Retry Delivery") { Task { await coordinator.retry() } }
            }
            Text("Writes each text Margin as a Markdown note in a folder you choose, such as an Obsidian vault. Add more than one to send different Margins to different places. It doesn’t change how Margins play. Notes are written while the app is active and retried when you return. Existing Margins are included. Audio recordings and full source text are excluded. Your folder provider may sync files to its cloud.").font(.footnote).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                switch pick {
                case .add: _ = coordinator.addDestination(folder: url)
                case .reselect(let id): coordinator.replaceFolder(of: id, with: url)
                }
            case .failure(let error): coordinator.reportFolderPickFailure(error)
            }
        }
    }

    private func choose(_ target: FolderPick) {
        pick = target
        choosingFolder = true
    }
}

private struct MarginOutputDestinationRow: View {
    let row: MarginOutputCoordinator.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(row.destination.name, systemImage: "folder")
            if row.needsAccess {
                FailureMessageLabel("Needs folder access").font(.footnote)
            } else {
                Text(summary).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        let scope = row.destination.scope == .starred ? "Starred Margins" : "All Margins"
        return "\(row.folderName) · \(scope) · \(row.destination.isEnabled ? "Delivering" : "Paused")"
    }
}

/// One destination's folder, contents and delivery. Test, Pause and Remove live here; Remove never deletes written files.
struct MarginOutputDestinationScreen: View {
    @ObservedObject var coordinator: MarginOutputCoordinator
    let id: String
    @State private var name = ""
    @State private var choosingFolder = false
    @State private var confirmingRemove = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if let row = coordinator.rows.first(where: { $0.id == id }) {
                Section("Destination") {
                    TextField("Name", text: $name)
                        .onSubmit { coordinator.rename(id, to: name) }
                    Label(row.folderName, systemImage: "folder")
                    Button(row.needsAccess ? "Reselect Folder" : "Change Folder", systemImage: "folder.badge.gearshape") { choosingFolder = true }
                    if row.needsAccess { FailureMessageLabel("Needs folder access").font(.footnote) }
                }
                Section("Notes") {
                    Picker("Shape", selection: Binding(
                        get: { row.destination.shape },
                        set: { coordinator.setShape(of: id, $0) }
                    )) {
                        ForEach(MarginNotesShape.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    if row.destination.shape == .itemOnCompletion {
                        Text("One note per item, written when you mark it complete. It holds every Margin from your listening, with the item’s properties. Items you finished before choosing this don’t get one. Finishing an item by listening is picked up within about half an hour.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Contents") {
                    Picker("Margins", selection: Binding(
                        get: { row.destination.scope },
                        set: { coordinator.setContent(of: id, scope: $0) }
                    )) {
                        Text("All Margins").tag(MarginOutputDestination.Scope.all)
                        Text("Starred only").tag(MarginOutputDestination.Scope.starred)
                    }
                    Toggle("Include source context", isOn: Binding(
                        get: { row.destination.includesContext },
                        set: { coordinator.setContent(of: id, includesContext: $0) }
                    ))
                    Picker("Text", selection: Binding(
                        get: { row.destination.text },
                        set: { coordinator.setContent(of: id, text: $0) }
                    )) {
                        Text("Cleaned").tag(MarginOutputDestination.TextChoice.cleaned)
                        Text("Original").tag(MarginOutputDestination.TextChoice.original)
                    }
                    Text(row.destination.shape == .itemOnCompletion
                         ? "These choices shape notes for single Margins. A note for a whole item keeps its own form."
                         : "Source context is the passage around each Margin. The title, source link and position are always included. Changing a choice rewrites the notes this app wrote, never ones you edited.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Delivery") {
                    StatusMessageText(message: row.status.message, isFailure: row.status.isFailure)
                    Button("Send Test Note") { Task { await coordinator.sendTestNote(to: id) } }
                    Button(row.destination.isEnabled ? "Pause" : "Start Delivery") {
                        coordinator.setEnabled(id, !row.destination.isEnabled)
                    }
                    .disabled(row.needsAccess && !row.destination.isEnabled)
                    Button("Remove Destination", role: .destructive) { confirmingRemove = true }
                }
            }
        }
        .confirmationDialog("Remove \(coordinator.destination(id)?.name ?? "this destination")?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove Destination", role: .destructive) {
                coordinator.remove(id)
                dismiss()
            }
        } message: {
            Text("Notes already written stay in the folder. Your Margins stay in the Library.")
        }
        .navigationTitle(coordinator.destination(id)?.name ?? "Destination")
        .onAppear { name = coordinator.destination(id)?.name ?? "" }
        .onDisappear { coordinator.rename(id, to: name) }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): coordinator.replaceFolder(of: id, with: url)
            case .failure(let error): coordinator.reportFolderPickFailure(error)
            }
        }
    }
}

struct ListeningEditionImportScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var json = ""
    @State private var edition: ListeningEdition?
    @State private var message = ""
    @State private var messageIsFailure = false
    @State private var choosingFile = false
    @State private var replaceMap = false
    @State private var notifications = ""
    @State private var notificationsFailed = false
    /// Files chosen but not imported yet, already decoded so each row shows its title or its error (#1472).
    @State private var picked: [ListeningEditionBatch.Entry] = []
    @State private var nextEntryID = 0
    @State private var results: [ListeningEditionBatch.Line] = []
    @State private var loadingForReview = false
    @FocusState private var editingJSON: Bool
    private static let pastedEntryID = -1

    /// What the last Preview or Import said: the message from Preview or a failed import, else one line per file imported.
    private var resultLines: [(text: String, isFailure: Bool)] {
        if !message.isEmpty { return [(message, messageIsFailure)] }
        return results.map { ($0.message, $0.outcome.isFailure) }
    }

    private var hasPastedJSON: Bool { !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// What the pinned button will import: every valid chosen file, plus the pasted JSON when there is any.
    private var importCount: Int { picked.filter(\.isValid).count + (hasPastedJSON ? 1 : 0) }

    var body: some View {
        Form {
            Section {
                Button("Enable Ready Notifications") {
                    Task {
                        do {
                            notifications = try await ListeningReadyNotifications.requestPermission() ? "Notifications enabled for completed audio." : "Notifications are off. You can change this in system Settings."
                            notificationsFailed = false
                        } catch {
                            notifications = "Notifications could not be enabled."
                            notificationsFailed = true
                        }
                    }
                }
                if !notifications.isEmpty { StatusMessageText(message: notifications, isFailure: notificationsFailed) }
                Button("Choose JSON Files") { choosingFile = true }
                if !picked.isEmpty {
                    ForEach(picked) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.subheadline.weight(.semibold))
                            if entry.isValid { Text(entry.detail).font(.footnote).foregroundStyle(.secondary) }
                            else { FailureMessageLabel(entry.detail).font(.footnote) }
                            if let loaded = entry.edition {
                                Button("Review on its own") { review(loaded, id: entry.id) }.font(.footnote).buttonStyle(.borderless)
                            }
                        }
                        .accessibilityElement(children: .contain)
                    }
                    .onDelete { picked.remove(atOffsets: $0) }
                }
                TextEditor(text: $json).frame(minHeight: 140, maxHeight: 240)
                    .accessibilityLabel("Listening edition JSON")
                    .focused($editingJSON)
                    .onChange(of: json) { _, _ in
                        // Loading a file for review sets the editor text and its preview together.
                        if loadingForReview { loadingForReview = false; return }
                        edition = nil; replaceMap = false
                    }
                Button("Preview") {
                    editingJSON = false
                    do { edition = try ListeningEdition.decode(Data(json.utf8)); message = "" }
                    catch { message = error.localizedDescription; messageIsFailure = true }
                }
            } footer: {
                Text("Use Make Listening Map Prompt, your chosen model, then Assemble Listening Edition in Shortcuts. Import the result here or with Import Listening Edition. Choose several files to import them together; Preview is optional. No model request is made during import.")
            }
            if let edition {
                Section(edition.title) {
                    Text("\(edition.text.count) source characters · \(edition.scenes.count) scenes")
                    Text("Supplied by: \(edition.generator)").font(.caption)
                    Text(edition.overview)
                    ForEach(Array(edition.scenes.enumerated()), id: \.offset) { _, scene in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scene.title).bold(); Text(scene.description); Text(scene.summary).font(.caption)
                        }
                    }
                    Toggle("Replace existing map for this exact source", isOn: $replaceMap)
                    Text("Replacing applies when this is the only edition you import.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Listening Edition")
        // Pinned, so Import never needs a scroll, at any screen size or text size.
        // The result sits right above the button, so a tap is never answered below the fold (#2063).
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if !resultLines.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(resultLines.enumerated()), id: \.offset) { _, line in
                                StatusMessageText(message: line.text, isFailure: line.isFailure)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("listeningEdition.result")
                }
                Button(action: importAll) {
                    Text(ListeningEditionBatch.buttonTitle(count: importCount))
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .filledActionButton()
                .disabled(importCount == 0)
                .accessibilityIdentifier("listeningEdition.import")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onChange(of: resultLines.map { $0.text }) { _, texts in
            #if canImport(UIKit)
            if !texts.isEmpty { UIAccessibility.post(notification: .announcement, argument: texts.joined(separator: " ")) }
            #endif
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() {
                    picked.append(.reading(url: url, id: nextEntryID))
                    nextEntryID += 1
                }
                results = []
                message = ""
            } catch { message = error.localizedDescription; messageIsFailure = true }
        }
    }

    /// Moves one chosen file into the editor with its preview, where the replace toggle lives.
    private func review(_ loaded: ListeningEdition, id: Int) {
        guard let data = try? loaded.encoded(), let text = String(data: data, encoding: .utf8) else { return }
        if json != text { loadingForReview = true }
        json = text
        edition = loaded
        replaceMap = false
        picked.removeAll { $0.id == id }
        message = ""
    }

    private func importAll() {
        editingJSON = false
        var entries = picked
        if hasPastedJSON {
            entries.append(ListeningEditionBatch.Entry(id: Self.pastedEntryID, name: "Pasted JSON", data: Data(json.utf8)))
        }
        results = []
        message = ""
        // One edition is imported and opened, as it always was. Several are saved where the listener is.
        if entries.count == 1, let single = entries[0].edition {
            let replace = entries[0].id == Self.pastedEntryID && replaceMap
            if model.importListeningEdition(single, replaceMap: replace) { picked = []; json = ""; edition = nil; replaceMap = false }
            else { message = model.lastError ?? "The edition could not be imported."; messageIsFailure = true }
            return
        }
        let lines = model.importListeningEditions(entries)
        results = lines
        let done = Set(lines.filter { $0.outcome.isSuccess }.map(\.id))
        // What imported leaves the list; what did not stays, so it can be fixed, reviewed on its own, or removed.
        picked.removeAll { done.contains($0.id) }
        if done.contains(Self.pastedEntryID) { json = ""; edition = nil; replaceMap = false }
    }
}

struct ReadLaterScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @StateObject private var connection = ReadLaterModel()
    var body: some View {
        Form {
            Section("Service") {
                Picker("Service", selection: $connection.service) {
                    ForEach(ReadLaterService.allCases, id: \.self) { Text($0.title).tag($0) }
                }.onChange(of: connection.service) { _, _ in connection.selectService() }
                SecureField("Access token", text: $connection.token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Link("Get an access token", destination: URL(string: connection.service == .reader ? "https://readwise.io/access_token" : "https://app.raindrop.io/settings/integrations")!)
                Button("Connect", action: connection.connect).disabled(connection.isLoading)
                if connection.connected {
                    Button("Refresh") { connection.refresh() }.disabled(connection.isLoading)
                    Button("Disconnect", role: .destructive) {
                        // Readwise is also where Margins are sent; a later connection is a new destination (#1467).
                        let wasReader = connection.service == .reader
                        if connection.disconnect(), wasReader { model.readwiseHighlightSync.destinationDisconnected() }
                    }
                }
                Text(connection.service == .reader
                     ? "Reader requires a Readwise account. This view lists Later articles with available text. PDFs, books and highlights are not imported by this adapter."
                     : "Raindrop has a free bookmark account. For personal setup, create an integration and paste its test token. Articles are fetched from their original websites; saved paid/offline copies are not used.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let symbol = connection.statusSymbol {
                    Label(connection.status, systemImage: symbol.rawValue).font(.footnote)
                } else {
                    StatusMessageText(message: connection.status, isFailure: connection.statusIsFailure)
                }
            }
            if connection.service == .reader && connection.connected {
                ReadwiseHighlightSection(sync: model.readwiseHighlightSync)
            }
            Section("Choose Articles") {
                if let line = connection.emptyArticlesLine {
                    // Only "No articles loaded. <failure>" is a failure; the other lines are guidance.
                    if connection.connected, connection.failure != nil, !connection.isLoading {
                        FailureMessageLabel(line).font(.footnote)
                    } else {
                        Text(line).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(connection.documents) { document in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(document.title).font(.headline)
                        Text(URL(string: document.url)?.host ?? "Article").font(.caption)
                        Button("Add to Spoken Margins") { model.importReadLaterDocument(document) }
                            .disabled(model.isImportingReadLater)
                    }
                }
                if connection.nextCursor != nil {
                    Button("Load More") { connection.refresh(more: true) }.disabled(connection.isLoading)
                }
            }
        }.navigationTitle("Read Later")
    }
}

struct ReadwiseHighlightSection: View {
    @ObservedObject var sync: ReadwiseHighlightSync
    var body: some View {
        Section("Send Margins") {
            Toggle("Send Margins to Readwise", isOn: $sync.enabled)
                .onChange(of: sync.enabled) { _, _ in sync.enabledChanged() }
            if !sync.status.isEmpty { StatusMessageText(message: sync.status, isFailure: sync.statusIsFailure) }
            Text("Each Margin with text becomes a Readwise highlight: the passage around it, your Margin as the note, filed under the article or episode. Margins are checked once a minute while the app is open. Private feed links are never sent.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct ListeningEditionScenes: View {
    @EnvironmentObject private var model: Gate1AppModel
    let edition: ListeningEdition
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Imported Listening Map").font(.headline)
            Text("Supplied by \(edition.generator). Descriptions and summaries are user-supplied.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(edition.scenes.enumerated()), id: \.offset) { index, scene in
                VStack(alignment: .leading, spacing: 5) {
                    Text(scene.title).bold()
                    Text(scene.description)
                    DisclosureGroup("Summary") { Text(scene.summary) }
                    Button("Go to Scene") { model.jumpToChapter(edition.listeningMap().chapters[index]) }
                }
            }
        }
    }
}
