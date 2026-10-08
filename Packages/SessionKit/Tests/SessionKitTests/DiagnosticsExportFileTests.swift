import XCTest
@testable import SessionKit

final class DiagnosticsExportFileTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-08 13:37:02 UTC, the owner's export that prompted #903.
    private let exportedAt = Date(timeIntervalSince1970: 1_791_466_622)

    func testFileNameCarriesBuildAndMinute() {
        XCTAssertEqual(DiagnosticsExportFile.fileName(build: "0.1 (30) · 41a591e", exportedAt: exportedAt, timeZone: utc),
                       "Spoken Margins diagnostics 0.1 (30) 41a591e 2026-10-08 1337.json")
    }

    func testFileNameDropsCharactersFileSystemsReject() {
        let cases = [
            "0.1 (30)": "Spoken Margins diagnostics 0.1 (30) 2026-10-08 1337.json",
            "unknown (unknown)": "Spoken Margins diagnostics unknown (unknown) 2026-10-08 1337.json",
            "0.1/30:41a\\591e": "Spoken Margins diagnostics 0.1 30 41a 591e 2026-10-08 1337.json",
            "  0.1   (30)  ": "Spoken Margins diagnostics 0.1 (30) 2026-10-08 1337.json",
            "": "Spoken Margins diagnostics 2026-10-08 1337.json",
        ]
        for (build, expected) in cases {
            XCTAssertEqual(DiagnosticsExportFile.fileName(build: build, exportedAt: exportedAt, timeZone: utc), expected, build)
        }
    }

    func testFileNameUsesTheGivenTimeZone() {
        let eastern = TimeZone(identifier: "America/New_York")!
        XCTAssertTrue(DiagnosticsExportFile.fileName(build: "0.1 (30)", exportedAt: exportedAt, timeZone: eastern)
            .hasSuffix("2026-10-08 0937.json"))
    }

    func testWriteReplacesEarlierExportAndKeepsTheText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsExportFileTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DiagnosticsExportFile.write("{\"a\":\"1\"}", build: "0.1 (30)", exportedAt: exportedAt,
                                                    to: directory, timeZone: utc)
        let text = "{\n  \"schemaVersion\" : \"spoken-margins.diagnostics.v1\"\n}"
        let second = try DiagnosticsExportFile.write(text, build: "0.1 (30) · 41a591e",
                                                     exportedAt: exportedAt.addingTimeInterval(60), to: directory, timeZone: utc)

        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [second.lastPathComponent])
    }
}
