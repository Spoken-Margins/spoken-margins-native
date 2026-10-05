import SwiftUI
import UniformTypeIdentifiers
import SessionKit

struct MarginOutputSettingsSection: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var choosingFolder = false
    var body: some View {
        Section("Margin Output") {
            Button { choosingFolder = true } label: {
                Label(model.hasBatchExportFolder ? model.batchExportFolderName : "Choose Output Folder", systemImage: "folder")
            }
            Button("Send Test Note", action: model.testMarginOutput).disabled(!model.hasBatchExportFolder)
            Toggle("Save Margins to Notes Folder", isOn: $model.automaticMarginOutputEnabled)
                .disabled(!model.hasBatchExportFolder)
                .onChange(of: model.automaticMarginOutputEnabled) { _, _ in model.automaticMarginOutputChanged() }
            Button("Retry Delivery") { Task { await model.deliverAutomaticMargins() } }
                .disabled(!model.automaticMarginOutputEnabled)
            Text(model.marginOutputStatus).font(.footnote)
            Text("Writes each text Margin as a Markdown note in the folder you choose, such as an Obsidian vault. It doesn’t change how Margins play. Notes are written while the app is active and retried when you return. Existing Margins are included. Audio recordings and full source text are excluded. Your folder provider may sync files to its cloud.").font(.footnote).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): model.configureBatchExportFolder(url: url)
            case .failure(let error): model.reportBatchExportFolderFailure(error)
            }
        }
    }
}

struct ListeningEditionImportScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var json = ""
    @State private var edition: ListeningEdition?
    @State private var message = ""
    @State private var choosingFile = false
    @State private var replaceMap = false
    @State private var notifications = ""
    @FocusState private var editingJSON: Bool
    var body: some View {
        Form {
            Section {
                Button("Enable Ready Notifications") {
                    Task {
                        do { notifications = try await ListeningReadyNotifications.requestPermission() ? "Notifications enabled for completed audio." : "Notifications are off. You can change this in system Settings." }
                        catch { notifications = "Notifications could not be enabled." }
                    }
                }
                if !notifications.isEmpty { Text(notifications).font(.footnote) }
                Button("Choose JSON File") { choosingFile = true }
                TextEditor(text: $json).frame(minHeight: 140, maxHeight: 240)
                    .accessibilityLabel("Listening edition JSON")
                    .focused($editingJSON)
                    .onChange(of: json) { _, _ in edition = nil; replaceMap = false }
                Button("Preview") {
                    editingJSON = false
                    do { edition = try ListeningEdition.decode(Data(json.utf8)); message = "" }
                    catch { message = error.localizedDescription }
                }
            } footer: {
                Text("Use Make Listening Map Prompt, your chosen model, then Assemble Listening Edition in Shortcuts. Import the result here or with Import Listening Edition. No model request is made during import.")
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
                    Button("Import Item and Map") {
                        model.importListeningEditionData(Data(json.utf8), replaceMap: replaceMap)
                    }
                }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.red) }
        }
        .navigationTitle("Listening Edition")
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8_000_000 else { throw EditionError.invalid("File exceeds 8 MB.") }
                let data = try Data(contentsOf: url)
                let parsed = try ListeningEdition.decode(data)
                json = String(data: data, encoding: .utf8) ?? ""
                // Preview is explicit after changing the editor, so old content cannot import.
                message = "Loaded \(parsed.title). Tap Preview to review it."
            } catch { message = error.localizedDescription }
        }
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
                    Button("Disconnect", role: .destructive, action: connection.disconnect)
                }
                Text(connection.service == .reader
                     ? "Reader requires a Readwise account. This view lists Later articles with available text. PDFs, books and highlights are not imported by this adapter."
                     : "Raindrop has a free bookmark account. For personal setup, create an integration and paste its test token. Articles are fetched from their original websites; saved paid/offline copies are not used.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(connection.status).font(.footnote)
            }
            if connection.service == .reader && connection.connected {
                ReadwiseHighlightSection(sync: model.readwiseHighlightSync)
            }
            Section("Choose Articles") {
                if let line = connection.emptyArticlesLine {
                    Text(line).font(.footnote).foregroundStyle(.secondary)
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
            if !sync.status.isEmpty { Text(sync.status).font(.footnote) }
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
