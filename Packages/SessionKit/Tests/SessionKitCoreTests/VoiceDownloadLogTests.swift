import Foundation
import XCTest
@testable import SessionKit

/// #2224: the voice download path leaves a short, persisted log the Diagnostics export can read. This file
/// holds the log itself; the catalog and install events are asserted beside the code that writes them.
final class VoiceDownloadLogTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("voice-download-log-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private var fileURL: URL { VoiceDownloadLog.fileURL(stateFolder: folder) }

    func testAnEventFromAnEarlierLaunchIsStillThere() throws {
        let first = VoiceDownloadLog(fileURL: fileURL)
        first.record("install.started", ["voice": "supertonic"])
        first.record("install.finished", ["voice": "supertonic", "bytesOnDisk": "1000"])

        let later = VoiceDownloadLog(fileURL: fileURL)
        XCTAssertEqual(later.snapshot.map(\.kind), ["install.started", "install.finished"])
        let export = try XCTUnwrap(VoiceDownloadLog.exportJSON(fileURL: fileURL), "the export reads the file with no log object")
        XCTAssertTrue(export.contains("\"bytesOnDisk\":\"1000\""))
        XCTAssertTrue(export.contains(VoiceDownloadLog.schemaVersion))
    }

    func testNothingRecordedExportsNothing() {
        XCTAssertNil(VoiceDownloadLog(fileURL: fileURL).exportJSON())
        XCTAssertNil(VoiceDownloadLog.exportJSON(fileURL: fileURL), "no file is no export")
    }

    func testOnlyTheNewestEventsAreKept() {
        let log = VoiceDownloadLog(fileURL: fileURL, limit: 5)
        for number in 0..<12 { log.record("step", ["n": String(number)]) }
        XCTAssertEqual(log.snapshot.map { $0.fields["n"] }, ["7", "8", "9", "10", "11"])
        XCTAssertEqual(VoiceDownloadLog(fileURL: fileURL, limit: 5).snapshot.count, 5, "the file is trimmed the same way")
    }

    func testAnUnreadableFileStartsAnEmptyLogInsteadOfFailing() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let log = VoiceDownloadLog(fileURL: fileURL)
        XCTAssertEqual(log.snapshot, [])
        log.record("catalog.loaded")
        XCTAssertEqual(VoiceDownloadLog(fileURL: fileURL).snapshot.map(\.kind), ["catalog.loaded"])
    }

    /// Neighbouring inputs for what may leave the phone: addresses, paths, both inside longer text.
    func testAddressesBecomeHostsAndPathsAreDropped() {
        let cases: [(String, String)] = [
            ("https://huggingface.co/Supertone/supertonic-3/resolve/abc/onnx/model.onnx", "huggingface.co"),
            ("fetch https://voices.example/v1/catalog.json?token=secret failed", "fetch voices.example failed"),
            ("(https://a.example/x) and https://b.example:8443/y", "(a.example) and b.example"),
            ("wrote /var/mobile/Containers/Data/Application/ABC/Library/Application Support/Voices/x", "wrote <path>"),
            ("/private/var/mobile/tmp/file.partial gone", "<path>"),
            ("ftp://h.example/secret/file not usable", "h.example not usable"),
            ("onnx/model.onnx", "onnx/model.onnx"),
            ("", ""),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(VoiceDownloadLog.sanitized(input), expected, input)
        }
        XCTAssertEqual(VoiceDownloadLog.sanitized(String(repeating: "x", count: 500)).count, 201)
    }

    func testARecordedFieldIsSanitizedBeforeItIsKept() throws {
        let log = VoiceDownloadLog(fileURL: fileURL)
        log.record("file.attempt_failed", ["reason": "https://user@host.example/a/b?c=d refused", "file": "onnx/m.onnx"])
        let event = try XCTUnwrap(log.snapshot.first)
        XCTAssertEqual(event.fields["reason"], "host.example refused")
        XCTAssertEqual(event.fields["file"], "onnx/m.onnx")
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("user@"))
        XCTAssertFalse(onDisk.contains("c=d"))
    }

    func testRecordingFromManyTasksLosesNothing() async throws {
        let log = VoiceDownloadLog(fileURL: fileURL, limit: 500)
        await withTaskGroup(of: Void.self) { group in
            for number in 0..<100 { group.addTask { log.record("step", ["n": String(number)]) } }
        }
        XCTAssertEqual(log.snapshot.count, 100)
        XCTAssertEqual(VoiceDownloadLog(fileURL: fileURL, limit: 500).snapshot.count, 100)
    }
}
