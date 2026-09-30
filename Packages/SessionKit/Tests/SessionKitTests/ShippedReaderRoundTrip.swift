import Foundation
import SessionKit
import SessionKitSharing
import ShippedPacketReader
import XCTest

/// Writes a packet, then imports it with the last shipped build's reader (#317). A new build's packets
/// must import there, and that reader rejects manifest keys it doesn't know. Tests that export a packet
/// call this instead of SpokenMarginsPackageArchive.write; the test below keeps it that way.
@discardableResult
func exportPacket(_ prepared: PreparedSpokenMarginsPackage, to url: URL) throws -> SpokenMarginsPackageManifest {
    let manifest = try SpokenMarginsPackageArchive.write(prepared, to: url)
    try ShippedPacketReader.importPacket(at: url)
    return manifest
}

final class ShippedReaderRoundTripTests: XCTestCase {
    func testEveryExporterTestReadsItsPacketWithTheShippedBuild() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "ShippedReaderRoundTrip.swift" }
        var direct: [String] = []
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where line.contains("SpokenMarginsPackageArchive.write(") && !line.contains("XCTAssertThrowsError(") {
                direct.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertGreaterThan(files.count, 10, "the test sources were not found")
        XCTAssertEqual(direct, [], "export with exportPacket(_:to:) so the shipped build reads the packet")
    }
}
