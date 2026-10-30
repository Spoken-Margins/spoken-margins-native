import Foundation
import SessionKit
import SessionKitSharing
import ShippedPacketReader
import XCTest

/// Writes a packet, then imports it with the last shipped build's reader (#317). A new build's packets
/// must import there, and that reader rejects manifest keys it doesn't know. Tests that export a packet
/// call this instead of SpokenMarginsPackageArchive.write; the test below keeps it that way.
@discardableResult
func exportPacket(
    _ prepared: PreparedSpokenMarginsPackage,
    to url: URL,
    shippedBuildReader: (URL) throws -> [String] = { try ShippedPacketReader.importPacket(at: $0) }
) throws -> SpokenMarginsPackageManifest {
    let manifest = try SpokenMarginsPackageArchive.write(prepared, to: url)
    let shippedReadIDs = try shippedBuildReader(url)
    // Build 29 must decode every Margin the new writer put in (#1039 PKT-01): a packet whose Margins its reader
    // drops comes back "successfully" with a short list. This compares what its reader decoded from the zip, not
    // what its importer then saved. Skipped only when the packet has no commentary layer to compare with.
    let sent = try marginIDs(in: prepared)
    if let mismatch = shippedMarginsMismatch(sent: sent, shippedBuildRead: shippedReadIDs) {
        throw mismatch
    }
    try keepForLaterShippedBuilds(url, sent: sent)
    return manifest
}

/// Builds 32 and 34 have no frozen copy here. When `SM_SHIPPED_PACKETS_DIR` is set, scripts/check-build29-database.sh
/// collects every packet Build 29 read, with the Margin ids it carries, and opens them with each shipped build's
/// own reader built from its tag (#1900). Without the variable this does nothing.
func keepForLaterShippedBuilds(_ url: URL, sent: [String]?, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    guard let folder = environment["SM_SHIPPED_PACKETS_DIR"], !folder.isEmpty else { return }
    let name = "\(UUID().uuidString)-\(url.lastPathComponent)"
    let destination = URL(fileURLWithPath: folder).appendingPathComponent(name)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: url, to: destination)
    let expected: [String: Any] = ["margins": sent.map { $0.sorted() } ?? NSNull()]
    try JSONSerialization.data(withJSONObject: expected).write(to: destination.appendingPathExtension("expected.json"))
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

/// The gate's comparison, on its own so a test can feed it a reader that drops a Margin (#1898). Margin ids only:
/// anchors, transcripts, reply links and audio are not compared here. `sent` is nil when the packet has no
/// commentary layer.
func shippedMarginsMismatch(sent: [String]?, shippedBuildRead: [String]) -> ShippedReaderGateError? {
    guard let sent, sent.sorted() != shippedBuildRead.sorted() else { return nil }
    return .marginsDiffer(sent: sent.sorted(), shippedBuildRead: shippedBuildRead.sorted())
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

    /// The packets Builds 32 and 34 import come from here (#1900): each one Build 29 read, with its Margin ids.
    func testAPacketBuild29ReadIsKeptForTheLaterShippedBuilds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kept-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packet = root.appendingPathComponent("written.spokenmargins")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("packet bytes".utf8).write(to: packet)
        let kept = root.appendingPathComponent("kept", isDirectory: true)

        try keepForLaterShippedBuilds(packet, sent: ["margin-002", "margin-001"], environment: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path), "nothing is kept without SM_SHIPPED_PACKETS_DIR")

        try keepForLaterShippedBuilds(packet, sent: ["margin-002", "margin-001"], environment: ["SM_SHIPPED_PACKETS_DIR": kept.path])
        try keepForLaterShippedBuilds(packet, sent: nil, environment: ["SM_SHIPPED_PACKETS_DIR": kept.path])
        let packets = try FileManager.default.contentsOfDirectory(at: kept, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "spokenmargins" }
        XCTAssertEqual(packets.count, 2, "two exports of the same name are both kept")
        var expected: [String] = []
        for copy in packets {
            XCTAssertEqual(try Data(contentsOf: copy), Data("packet bytes".utf8))
            let sidecar = try JSONSerialization.jsonObject(with: Data(contentsOf: copy.appendingPathExtension("expected.json"))) as? [String: Any]
            expected.append((sidecar?["margins"] as? [String])?.joined(separator: ",") ?? "null")
        }
        XCTAssertEqual(expected.sorted(), ["margin-001,margin-002", "null"])
    }
}
