import Foundation
import SessionKit
import SessionKitAI
import SessionKitAudio
import SessionKitPersistence

@MainActor
final class Gate1AppModel: ObservableObject {
    @Published var snapshot = SessionSnapshot()
    @Published var diagnostics: [String: String] = [:]
    @Published var exportPreview = ""
    @Published var selectedProfileId = "phone-tablet-online"
    @Published var importTitle = "Gate 1 Article With Links"
    @Published var importText = "Read the background at https://example.com/long/url before continuing. A labeled [reference](https://example.com/essay) should stay readable while raw URLs are skipped."
    @Published var knownIssues = [
        "Gate 1 simulator app builds; signed device installation still requires local team/provisioning configuration.",
        "System recording adapter is a production boundary stub until entitlement and permission flows are wired."
    ]

    private var engine: SessionEngine?
    private var store: SQLiteSessionStore?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func resetAndSeed() {
        do {
            let databaseURL = try databaseURL()
            let store = try SQLiteSessionStore(path: databaseURL.path)
            try store.reset()
            let item = try loadFixtureItem(name: "text-with-listening-map")
            let map = try loadFixtureMap(name: "valid-listening-map")
            try store.seed(item: item)
            try store.seed(map: map)
            self.store = store
            self.engine = try makeEngine(store: store)
            snapshot = SessionSnapshot()
            diagnostics = [
                "runtimeProfile": selectedProfileId,
                "seededItems": "1",
                "database": databaseURL.lastPathComponent
            ]
            exportPreview = ""
        } catch {
            diagnostics["recentFailure"] = String(describing: error)
        }
    }

    func importTextItem() {
        do {
            let store = try requireStore()
            let item = Item(
                id: "item-import-\(Int(Date().timeIntervalSince1970))",
                title: importTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Text" : importTitle,
                mediaType: "text",
                text: importText,
                externalReference: "manual-import",
                status: "needs_listening_map"
            )
            try store.seed(item: item)
            self.engine = try makeEngine(store: store)
            snapshot = try engine?.startSession(itemId: item.id) ?? SessionSnapshot()
            diagnostics["lastImport"] = item.id
        } catch {
            diagnostics["recentFailure"] = String(describing: error)
        }
    }

    func start() {
        run { engine in
            snapshot = try engine.startSession(itemId: "item-pill")
        }
    }

    func skipBack() {
        run { engine in
            snapshot = try engine.skipBack(unit: "sentence")
        }
    }

    func skipForward() {
        run { engine in
            snapshot = try engine.skipForward(unit: "sentence")
        }
    }

    func beginInterjection() {
        run { engine in
            snapshot = try engine.beginInterjection()
        }
    }

    func finishInterjection() {
        run { engine in
            snapshot = try engine.finishInterjection(audioRef: "interjections/device-\(Date().timeIntervalSince1970).m4a")
        }
    }

    func summarize() {
        run { engine in
            snapshot = try engine.generateInterjectionSummary(scope: SummaryScope(targetType: "item"))
        }
    }

    func followUp(_ text: String) {
        run { engine in
            snapshot = try engine.submitFollowup(text: text)
        }
    }

    func buildExport() {
        run { engine in
            let export = try engine.buildExport(options: ExportOptions(includeFullText: false, includeReference: true, includeListeningMap: false, includeInterjections: true))
            let data = try encoder.encode(export)
            exportPreview = String(data: data, encoding: .utf8) ?? ""
        }
    }

    func refreshDiagnostics() {
        run { engine in
            diagnostics = try engine.diagnostics()
        }
    }

    private func run(_ operation: (SessionEngine) throws -> Void) {
        guard let engine else {
            resetAndSeed()
            return
        }
        do {
            try operation(engine)
        } catch {
            diagnostics["recentFailure"] = String(describing: error)
        }
    }

    private func makeEngine(store: SQLiteSessionStore) throws -> SessionEngine {
        let profile = try loadProfile(id: selectedProfileId)
        return SessionEngine(
            profile: profile,
            repository: store,
            audio: SystemSpeechPlaybackClient(),
            recorder: SystemRecordingClient(),
            aiProvider: FixtureAIProvider()
        )
    }

    private func requireStore() throws -> SQLiteSessionStore {
        if let store { return store }
        let store = try SQLiteSessionStore(path: databaseURL().path)
        self.store = store
        return store
    }

    private func databaseURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appending(path: "SpokenMarginsGate1.sqlite")
    }

    private func loadFixtureItem(name: String) throws -> Item {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures/items") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.item(at: url)
    }

    private func loadFixtureMap(name: String) throws -> ListeningMap {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "fixtures/maps") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.listeningMap(at: url)
    }

    private func loadProfile(id: String) throws -> RuntimeCapabilityProfile {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "fixtures/capabilities") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContractFixtureLoader.profile(at: url)
    }
}
