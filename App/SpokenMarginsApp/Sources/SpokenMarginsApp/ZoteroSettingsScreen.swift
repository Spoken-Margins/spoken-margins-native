import SessionKit
import SessionKitFeeds
import SwiftUI

/// Settings › Import & Export › Zotero (#4341, slice 3): connect the listener's own Zotero library with their user ID and
/// an API key they make on zotero.org. Connect checks the key with Zotero before keeping it; the key goes to the
/// Keychain and is sent only to api.zotero.org, never to our server, a log or Diagnostics. Once connected, Follow papers
/// lists Your collections, and PDFs stored in Zotero come in too.
struct ZoteroSettingsScreen: View {
    @ObservedObject private var papers = PaperSourcesState.shared
    @State private var userID = ""
    @State private var apiKey = ""
    @State private var problem: String?
    @State private var isConnecting = false

    var body: some View {
        Form {
            if let connection = papers.connection {
                Section {
                    Label(connection.statusLine, systemImage: "checkmark.circle")
                        .accessibilityIdentifier("zotero.connected")
                    Button("Disconnect", role: .destructive) { papers.disconnect() }
                        .frame(minHeight: 44)
                        .accessibilityHint("Forgets the key on this iPhone. Lists you follow from your library keep their papers.")
                        .accessibilityIdentifier("zotero.disconnect")
                } footer: {
                    Text("Follow your collections from Following, then +, then Papers from Zotero.")
                }
            } else {
                Section {
                    TextField("Zotero user ID", text: $userID)
                        .keyboardType(.numberPad)
                        .textContentType(.username)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("zotero.userID")
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("zotero.apiKey")
                    Link("Create a key on zotero.org", destination: ZoteroConnectionInput.keysPage)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("zotero.createKey")
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Text("Connect")
                            if isConnecting { ProgressView().padding(.leading, 6) }
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(isConnecting || userID.trimmingCharacters(in: .whitespaces).isEmpty || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("zotero.connect")
                } footer: {
                    if let problem {
                        Text(problem)
                            .foregroundStyle(AppColors.text)
                            .accessibilityIdentifier("zotero.problem")
                    } else {
                        Text("Your user ID and keys are on your API keys page on zotero.org. A read-only key that can read files is enough. The key stays on this iPhone and goes only to Zotero.")
                    }
                }
            }
        }
        .navigationTitle("Zotero")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("zotero.settings.screen")
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        problem = nil
        let id = userID, key = apiKey
        Task {
            problem = await papers.connect(userID: id, apiKey: key)
            isConnecting = false
            if problem == nil { apiKey = "" }
        }
    }
}
