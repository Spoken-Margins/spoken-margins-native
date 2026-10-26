import CryptoKit
import SessionKit
import SwiftUI

/// Settings › Voices (#1819): each voice with its publisher, size and licence; one tap to download (after
/// agreeing to use restrictions where the licence has them), progress while it downloads, and Remove.
/// Blue carries progress and orange a problem, each with words and an icon (Design/brief.md rule 3).
struct VoicesSettingsScreen: View {
    @ObservedObject var voices: VoiceDownloadsModel
    @State private var agreementRow: VoiceCatalogRow?
    @State private var pendingRemoval: VoiceCatalogRow?

    var body: some View {
        Form {
            let included = voices.rows.filter { $0.state == .bundled }
            let downloadable = voices.rows.filter { $0.state != .bundled }
            Section {
                if downloadable.isEmpty {
                    Text(voices.source == .none ? "Voices to download can't be listed right now. Check your connection and open this screen again." : "No voices to download for this iPhone.")
                        .foregroundStyle(AppColors.secondaryText)
                }
                ForEach(downloadable) { row in
                    VoiceRow(row: row, activity: voices.activity[row.id] ?? .idle,
                             download: { start(row) }, cancel: { voices.cancel(row.id) }, remove: { pendingRemoval = row })
                }
            } header: {
                Text("Download")
            } footer: {
                Text("Downloaded voices run on this iPhone. Spoken text never leaves it.")
            }
            if !included.isEmpty {
                Section("Included with the app") {
                    ForEach(included) { row in
                        VoiceRow(row: row, activity: .idle, download: {}, cancel: {}, remove: {})
                    }
                }
            }
        }
        .navigationTitle("Voices")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.voices.screen")
        .task { await voices.open() }
        .sheet(item: $agreementRow) { row in
            VoiceAgreementSheet(row: row) {
                agreementRow = nil
                voices.agreeAndDownload(row)
            } cancel: {
                agreementRow = nil
            }
        }
        .confirmationDialog(
            pendingRemoval.map { "Remove \($0.entry.displayName)?" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let row = pendingRemoval { voices.remove(row.id) }
                pendingRemoval = nil
            }
        } message: {
            Text("Its files are deleted. You can download it again here.")
        }
    }

    private func start(_ row: VoiceCatalogRow) {
        if row.licensesNeedingAgreement.isEmpty {
            voices.download(row.id)
        } else {
            agreementRow = row
        }
    }
}

private struct VoiceRow: View {
    let row: VoiceCatalogRow
    let activity: VoiceDownloadsModel.Activity
    let download: () -> Void
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.entry.displayName).font(.headline)
            Text(row.entry.publisher)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            // The status on its own line and each licence on its own, so a card with four licences (Supertonic) never
            // squeezes "Downloaded · 148.1 MB" or "Apache-2.0" into a shared row that wraps mid-word, at any text size (#2225).
            Text(sizeText).font(.subheadline).monospacedDigit()
            ForEach(row.entry.licenses, id: \.id) { license in
                NavigationLink {
                    VoiceLicenseView(license: license).miniPlayerKeepOut()
                } label: {
                    Text(license.spdxId ?? "Licence").font(.subheadline)
                }
                .accessibilityLabel("Licence: \(license.name)")
            }
            status
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("settings.voices.row.\(row.id)")
    }

    private var sizeText: String {
        switch row.state {
        case .installed(_, let bytes): "Downloaded · \(Self.size(bytes))"
        case .bundled: "Included"
        case .notInstalled: Self.size(Int64(row.entry.downloadByteCount))
        }
    }

    @ViewBuilder private var status: some View {
        switch activity {
        case .downloading(let bytes, let total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(bytes), total: Double(max(total, 1)))
                    .tint(.blue)
                HStack {
                    Label("Downloading \(Self.size(bytes)) of \(Self.size(total))", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Spacer()
                    Button("Stop", action: cancel)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("settings.voices.stop.\(row.id)")
                }
            }
        case .preparing:
            // Indeterminate: a compile has no byte count, and a full bar that sits still looks stuck (#2700).
            HStack(spacing: 8) {
                ProgressView()
                Text("Preparing voice…")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.voices.preparing.\(row.id)")
        case .removing:
            Label("Removing…", systemImage: "trash").font(.caption).foregroundStyle(AppColors.secondaryText)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppColors.ochre)
                actions
            }
        case .idle:
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        switch row.state {
        case .bundled:
            EmptyView()
        case .installed:
            HStack {
                if let note = row.installedButNotOfferedNote {
                    Text(note).font(.caption).foregroundStyle(AppColors.secondaryText)
                }
                Spacer()
                Button("Remove", action: remove)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("settings.voices.remove.\(row.id)")
            }
        case .notInstalled:
            Button(action: download) {
                Label("Download \(Self.size(Int64(row.entry.downloadByteCount)))", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings.voices.download.\(row.id)")
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}

/// The plain-words use restrictions and an Agree step, before a restricted voice downloads.
private struct VoiceAgreementSheet: View {
    let row: VoiceCatalogRow
    let agree: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(row.entry.displayName) comes with use restrictions from its publisher. To download it, agree to use it within them.")
                }
                ForEach(row.licensesNeedingAgreement, id: \.id) { license in
                    Section(license.name) {
                        Text(license.restrictionsSummary ?? "")
                        NavigationLink("Read the full licence") { VoiceLicenseView(license: license) }
                    }
                }
            }
            .navigationTitle("Before you download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agree and download", action: agree)
                        .accessibilityIdentifier("settings.voices.agree")
                }
            }
        }
    }
}

/// The licence text: the reviewed copy bundled with the app when its hash matches the catalog's, which
/// works offline, otherwise the publisher's page.
struct VoiceLicenseView: View {
    let license: VoiceModelLicense

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let text = Self.bundledText(sha256: license.textSHA256) {
                    Text(text).font(.caption.monospaced()).textSelection(.enabled)
                } else if let url = URL(string: license.textURL) {
                    Text("The licence text is on the publisher's site.")
                    Link("Open the licence", destination: url)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(license.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Finds the bundled licence by its content, so no name mapping can drift from the catalog.
    static func bundledText(sha256: String) -> String? {
        let urls = Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: "licenses") ?? []
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if digest == sha256 { return String(decoding: data, as: UTF8.self) }
        }
        return nil
    }
}
