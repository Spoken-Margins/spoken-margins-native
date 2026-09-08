import Foundation
import CryptoKit

/// Bounded, opt-in event history. Call from the main actor; disk writes are serial
/// and off-main. Fields at call sites are state/counters, never source content.
@MainActor
final class DeveloperDiagnosticRecording {
    static let buildIdentity = "device-diagnostics-20260908-C"
    struct Event: Codable {
        let time: String
        let elapsedMs: Int
        let kind: String
        let fields: [String: String]
    }
    struct Capture: Codable {
        let schemaVersion: String
        let build: String
        let captureID: String
        let events: [Event]
    }
    private(set) var enabled = false
    private(set) var events: [Event] = []
    private var recordedCount = 0
    private var captureID = UUID().uuidString
    private var started = ProcessInfo.processInfo.systemUptime
    private let limit: Int
    private let fileURL: URL?
    private let writer = DispatchQueue(label: "spoken-margins.diagnostic-recording", qos: .utility)
    private let formatter = ISO8601DateFormatter()

    init(limit: Int = 1200, fileURL: URL? = nil) {
        self.limit = max(2, limit)
        self.fileURL = fileURL
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    static func token(_ value: String?) -> String {
        guard let value else { return "none" }
        return SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    func start() {
        events.removeAll(keepingCapacity: true)
        recordedCount = 0
        captureID = UUID().uuidString
        started = ProcessInfo.processInfo.systemUptime
        enabled = true
        record("recording.started")
        persist()
    }
    func stop() {
        record("recording.stopped")
        enabled = false
        persist()
    }
    func record(_ kind: String, _ fields: [String: String] = [:]) {
        guard enabled else { return }
        events.append(Event(time: formatter.string(from: Date()),
                            elapsedMs: Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                            kind: kind, fields: fields))
        if events.count > limit { events.removeFirst(events.count - limit) }
        recordedCount += 1
        if recordedCount % 20 == 0 { persist() }
    }
    func exportJSON() -> String? {
        if events.isEmpty, let fileURL,
           let data = try? Data(contentsOf: fileURL),
           (try? JSONDecoder().decode(Capture.self, from: data)) != nil {
            return String(data: data, encoding: .utf8)
        }
        guard let data = encoded() else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func encoded() -> Data? {
        try? JSONEncoder().encode(Capture(schemaVersion: "spoken-margins.developer-recording.v1",
                                        build: Self.buildIdentity, captureID: captureID, events: events))
    }
    private func persist() {
        guard let fileURL, let data = encoded() else { return }
        writer.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
