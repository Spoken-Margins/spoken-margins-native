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
    let shippedReadIDs = try ShippedPacketReader.importPacket(at: url)
    // Build 29 must decode every Margin the new writer put in (#1039 PKT-01): a packet whose Margins its reader
    // drops comes back "successfully" with a short list. This compares what its reader decoded from the zip, not
    // what its importer then saved. Skipped only when the packet has no commentary layer to compare with.
    if let sentIDs = try marginIDs(in: prepared), sentIDs.sorted() != shippedReadIDs.sorted() {
        throw ShippedReaderGateError.marginsDiffer(sent: sentIDs.sorted(), shippedBuildRead: shippedReadIDs.sorted())
    }
    return manifest
}

/// Writes a map-only packet (#1471), then checks the shipped build refuses it by its ordinary "unsupported capability"
/// path: not a crash, not a half import, not a different complaint. This is the one packet that must NOT import there.
@discardableResult
func exportMapOnlyPacket(_ prepared: PreparedSpokenMarginsPackage, to url: URL) throws -> SpokenMarginsPackageManifest {
    let manifest = try SpokenMarginsPackageArchive.write(prepared, to: url)
    do {
        _ = try ShippedPacketReader.importPacket(at: url)
    } catch let rejected as ShippedPacketReader.Rejected {
        guard rejected.description.contains("unsupportedRequiredCapability") else {
            throw ShippedReaderGateError.mapPacketRefusedForAnotherReason(rejected.description)
        }
        return manifest
    }
    throw ShippedReaderGateError.mapPacketImportedByTheShippedBuild
}

enum ShippedReaderGateError: Error, Equatable {
    case marginsDiffer(sent: [String], shippedBuildRead: [String])
    case mapPacketImportedByTheShippedBuild
    case mapPacketRefusedForAnotherReason(String)
}

/// The package-scoped IDs of the Margins in a prepared packet's commentary layers, or nil when there is no layer.
/// A layer the packet declares but this helper cannot decode is an error, not a reason to skip the comparison.
private func marginIDs(in prepared: PreparedSpokenMarginsPackage) throws -> [String]? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let layers = try prepared.manifest.artifacts
        .filter { $0.kind == SpokenMarginsArtifactKind.commentaryLayer }
        .compactMap { prepared.artifactData[$0.path] }
        .map { try decoder.decode(SharedCommentaryLayerArtifact.self, from: $0) }
    return layers.isEmpty ? nil : layers.flatMap { $0.interjections.map(\.packageScopedId) }
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
