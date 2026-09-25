import CryptoKit
import Foundation
import SessionKit
import SessionKitSharing

// Usage: swift run --package-path Packages/SessionKit CoopPacketGenerator <original.spokenmargins> <output-directory>
// The output directory must contain scripts.json and audio/{alex,blair,casey}.m4a plus audio-metadata.json.
private enum GeneratorError: Error { case missing(String), invalid(String) }

private func sha256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
private func require<T>(_ value: T?, _ description: String) throws -> T {
    guard let value else { throw GeneratorError.missing(description) }
    return value
}
private func selection(
    id: String, transcript: String, anchor: PortableAnchorEvidence, conversation: MarginConversation,
    audio: URL, duration: Int, forwarded: Bool, createdAt: Date
) -> ReviewedInterjectionSelection {
    let revision = InterjectionShareRevision(id: "fixture-review-\(id)", interjectionId: "fixture-\(id)",
        itemId: "fixture-episode", sessionId: "fixture-session", createdAt: createdAt,
        approvedTranscript: transcript, anchorBefore: anchor.prefix ?? "", anchorAfter: anchor.suffix ?? "",
        status: .senderApproved)
    var result = ReviewedInterjectionSelection(packageScopedId: "margin-\(id)", revision: revision,
        anchor: anchor, representation: forwarded ? .forwardedAudio(sourceURL: audio, durationMs: duration)
                                            : .syntheticTTS(sourceURL: audio, durationMs: duration))
    result.conversation = conversation
    return result
}

private func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw GeneratorError.invalid("expected original package and output directory")
    }
    let originalURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let source = try SpokenMarginsPackageArchive.read(from: originalURL,
        extractingAssetsTo: output.appendingPathComponent("original-verified-assets"))
    let digest = try require(source.manifest.contentDigest, "verified source digest")
    let original = try require(source.commentaryLayers.first?.interjections.first(where: { $0.packageScopedId == "margin-0002" }), "Cole margin-0002")
    let originalRepresentation = try require(original.defaultRepresentation, "Cole default representation")
    let originalAssetID = try require(originalRepresentation.assetId, "Cole voice asset")
    let originalAudio = try require(source.extractedAssetURLs[originalAssetID], "Cole verified audio")
    let originalDuration = try require(source.manifest.assets.first(where: { $0.id == originalAssetID })?.durationMs, "Cole audio duration")
    let stable = sha256("\(digest):\(original.packageScopedId)")
    let coleReference = MarginReference(contributionID: "legacy-\(stable)", revisionID: "legacy-v1")
    let cole = MarginConversation(reference: coleReference, authorID: "legacy-\(digest)", authorLabel: "Cole")
    let alex = MarginConversation(reference: .init(contributionID: "fixture.alex.20260924", revisionID: "v1"),
        authorID: "fixture.alex", authorLabel: "Alex (AI test)", parent: coleReference)
    let blair = MarginConversation(reference: .init(contributionID: "fixture.blair.20260924", revisionID: "v1"),
        authorID: "fixture.blair", authorLabel: "Blair (AI test)", parent: coleReference)
    let casey = MarginConversation(reference: .init(contributionID: "fixture.casey.20260924", revisionID: "v1"),
        authorID: "fixture.casey", authorLabel: "Casey (AI test)", parents: [alex.reference, blair.reference])
    let scripts = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: output.appendingPathComponent("scripts.json")))
    let durations = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: output.appendingPathComponent("audio-metadata.json")))
    let createdAt = Date(timeIntervalSince1970: 1_790_259_200)
    let voiceAnchor = original.anchor.withoutMachineEvidence
    let evidence: [ReviewedMachineEvidenceAsset] = try original.anchor.machineEvidenceAssetIds.map { id in
        let descriptor = try require(source.manifest.assets.first { $0.id == id }, "source evidence descriptor \(id)")
        return ReviewedMachineEvidenceAsset(id: id, path: descriptor.path,
            sourceURL: try require(source.extractedAssetURLs[id], "source evidence bytes \(id)"),
            durationMs: try require(descriptor.durationMs, "source evidence duration \(id)"),
            anchorOffsetMs: try require(descriptor.anchorOffsetMs, "source evidence offset \(id)"),
            provenance: descriptor.provenance)
    }
    func ai(_ name: String, _ conversation: MarginConversation, forwarded: Bool = false) throws -> ReviewedInterjectionSelection {
        selection(id: name, transcript: try require(scripts[name], "script \(name)"), anchor: voiceAnchor,
            conversation: conversation, audio: output.appendingPathComponent("audio/\(name).m4a"),
            duration: try require(durations[name], "duration \(name)"), forwarded: forwarded, createdAt: createdAt)
    }
    let root = selection(id: "cole", transcript: originalRepresentation.approvedTranscript,
        anchor: original.anchor, conversation: cole, audio: originalAudio,
        duration: originalDuration, forwarded: true, createdAt: original.createdAt)
    let definitions: [(String, String, [ReviewedInterjectionSelection])] = [
        ("01-alex-reply", "Alex (AI test)", [root, try ai("alex", alex)]),
        ("02-blair-reply", "Blair (AI test)", [root, try ai("blair", blair)]),
        ("03-casey-replies-to-both", "Casey (AI test)", [root, try ai("alex", alex, forwarded: true),
            try ai("blair", blair, forwarded: true), try ai("casey", casey)])
    ]
    var verified: [String: VerifiedSpokenMarginsPackage] = [:]
    for (name, sender, selections) in definitions {
        let prepared = try SpokenMarginsPackageBuilder.prepare(packageId: "coop-fixture-\(name)",
            createdAt: createdAt, item: source.manifest.item, itemTransportSelection: .reference,
            selections: selections, machineEvidence: evidence, senderDisplayLabel: sender)
        let url = output.appendingPathComponent("\(name).spokenmargins")
        _ = try SpokenMarginsPackageArchive.write(prepared, to: url)
        verified[name] = try SpokenMarginsPackageArchive.read(from: url,
            extractingAssetsTo: output.appendingPathComponent("verified-\(name)"))
        let packet = try require(verified[name], "verified packet \(name)")
        let records = try require(packet.commentaryLayers.first?.interjections, "commentary records \(name)")
        guard records.first?.anchor.machineEvidenceAssetIds == original.anchor.machineEvidenceAssetIds,
              records.first?.defaultRepresentation?.provenance == .forwardedApprovedCopy,
              records.last?.defaultRepresentation?.provenance == .senderApprovedTTS,
              (name != "03-casey-replies-to-both" ||
                  (packet.manifest.requiredCapabilities.contains(MarginConversation.multipleTargetsCapability)
                   && records.last?.conversation?.parents == [alex.reference, blair.reference])) else {
            throw GeneratorError.invalid("provenance, evidence or capability was lost in \(name)")
        }
        print("verified archive \(name): \(try require(verified[name]?.manifest.contentDigest, "digest"))")
    }
    for order in [["01-alex-reply", "02-blair-reply", "03-casey-replies-to-both"],
                  ["03-casey-replies-to-both", "02-blair-reply", "01-alex-reply", "03-casey-replies-to-both"]] {
        let repository = InMemorySessionRepository()
        for name in order {
            _ = try SpokenMarginsPackageImporter.importPackage(try require(verified[name], "verified packet \(name)"),
                itemId: "recipient-fixture-episode", importedAt: createdAt, repository: repository)
        }
        let snapshots = try repository.loadConversationSnapshots()
        guard snapshots.count == 4,
              snapshots.first(where: { $0.id == casey.reference.id })?.conversation.parents == [alex.reference, blair.reference],
              MarginConversationGraph.ancestors(of: casey.reference, in: snapshots).map(\.id)
                == [coleReference.id, alex.reference.id, blair.reference.id, casey.reference.id] else {
            throw GeneratorError.invalid("packet import did not preserve the four-node conversation")
        }
        print("verified order \(order.joined(separator: " → ")): four exact revisions and two Casey targets")
    }
}

do {
    try run()
} catch {
    fputs("CoopPacketGenerator failed: \(error)\n", stderr)
    exit(1)
}
