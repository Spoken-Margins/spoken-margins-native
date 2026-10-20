import Foundation
import SessionKit
import SessionKitSharing
import ShippedPacketReader
import XCTest

/// Writes a packet, then imports it with the last shipped build's reader, which must read back every Margin the
/// writer put in. The same gate as SessionKitTests' `exportPacket` (ShippedReaderRoundTrip.swift, #317 and #1039),
/// which this package can't import: test targets are not products (#1873).
@discardableResult
func exportPacket(_ prepared: PreparedSpokenMarginsPackage, to url: URL) throws -> SpokenMarginsPackageManifest {
    let manifest = try SpokenMarginsPackageArchive.write(prepared, to: url)
    let shippedReadIDs = try ShippedPacketReader.importPacket(at: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let sent = try prepared.manifest.artifacts
        .filter { $0.kind == SpokenMarginsArtifactKind.commentaryLayer }
        .compactMap { prepared.artifactData[$0.path] }
        .flatMap { try decoder.decode(SharedCommentaryLayerArtifact.self, from: $0).interjections.map(\.packageScopedId) }
    XCTAssertEqual(sent.sorted(), shippedReadIDs.sorted(), "the shipped build's reader must read every Margin sent")
    return manifest
}
