import Foundation
@testable import SessionKit
import SessionKitPersistence
import SessionKitSharing
import XCTest
#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox
#endif

/// One listener with their own SQLite Library, and a local copy of the same recording. Shared by the reply-loop tests
/// (`ReplyBackRoundTripTests`, `WebReplyRoundTripTests`).
final class Person {
    let name: String
    let store: SQLiteSessionStore
    let itemId = "episode"
    var sessionId: String { "session-\(name)" }
    private let folder: URL
    private let episode: SharedItemIdentity
    private var imports = 0

    init(name: String, root: URL, episode: SharedItemIdentity) throws {
        self.name = name
        self.episode = episode
        folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try SQLiteSessionStore(path: folder.appendingPathComponent("library.sqlite").path)
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_777_000_000 + seconds) }

    @discardableResult
    func record(_ id: String, madeAt: Double, atMs: Int, replyingTo parentScopedId: String? = nil, written: Bool = false) throws -> Interjection {
        var audioPath: String?
        if !written {
            let clip = folder.appendingPathComponent("\(id).m4a")
            try Self.writeClip(to: clip)
            audioPath = clip.path
        }
        let margin = Interjection(
            id: id, itemId: itemId, sessionId: sessionId, targetType: .item, targetId: itemId, createdAt: date(madeAt),
            roughPercent: 10,
            anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: atMs),
            audioPath: audioPath, audioStatus: written ? "none" : "ready", transcriptionStatus: "complete",
            transcript: "Words from \(name).", cleanedTranscript: nil, displayText: "Words from \(name).", status: "active",
            captureKind: written ? .written : nil, replyTo: try parentScopedId.map(replyLink(to:))
        )
        try store.saveInterjection(margin)
        return margin
    }

    func margins() throws -> [Interjection] { try store.loadInterjections(sessionId: sessionId) }

    func importedMargins() throws -> [ImportedCommentaryInterjection] {
        try store.loadImportedCommentaryLayers(itemId: itemId).flatMap { try store.loadImportedCommentaryInterjections(layerId: $0.id) }
    }

    private func replyLink(to parentScopedId: String) throws -> MarginReplyLink {
        for layer in try store.loadImportedCommentaryLayers(itemId: itemId) {
            if let parent = try store.loadImportedCommentaryInterjections(layerId: layer.id).first(where: { $0.packageScopedId == parentScopedId }) {
                return parent.replyLink(in: layer)
            }
        }
        throw SessionKitError.persistenceFailed("\(name) has no imported Margin \(parentScopedId)")
    }

    /// Writes a packet that the last shipped build's reader also opens (`exportPacket`), and records what went out.
    func send(_ margins: [Interjection], packageId: String, in directory: URL) throws -> (URL, SpokenMarginsPackageManifest) {
        let selections = margins.map { margin in
            ReviewedInterjectionSelection(
                packageScopedId: margin.id,
                revision: InterjectionShareRevision(
                    id: "revision-\(margin.id)", interjectionId: margin.id, itemId: margin.itemId, sessionId: margin.sessionId,
                    createdAt: margin.createdAt, approvedTranscript: margin.displayText ?? "", anchorBefore: "", anchorAfter: "",
                    status: .senderApproved
                ),
                anchor: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: margin.anchor.mediaTimeMs),
                representation: margin.audioPath.map { ReviewedRepresentationSelection.originalAudio(sourceURL: URL(fileURLWithPath: $0), durationMs: 600) } ?? .textOnly,
                replyTo: margin.replyTo
            )
        }
        let prepared = try SpokenMarginsPackageBuilder.prepare(
            packageId: packageId, createdAt: date(5), item: episode, itemTransportSelection: .recipientSupplied,
            selections: selections, senderDisplayLabel: name, suggestedRevealMode: .companion
        )
        let url = directory.appendingPathComponent("\(packageId).spokenmargins")
        let manifest = try exportPacket(prepared, to: url)
        try SpokenMarginsPackageExportRecord.recordExport(manifest: manifest, selections: selections, repository: store)
        return (url, manifest)
    }

    @discardableResult
    func importPacket(_ url: URL, at seconds: Double) throws -> ImportedCommentaryImportDisposition {
        imports += 1
        let contents = try SpokenMarginsPackageArchive.read(
            from: url, extractingAssetsTo: folder.appendingPathComponent("import-\(imports)", isDirectory: true))
        return try SpokenMarginsPackageImporter.importPackage(
            contents, itemId: itemId, localItem: episode, importedAt: date(seconds), repository: store)
    }

    /// A short voice clip: real AAC on a Mac (the reader decodes it), an `ftyp` header elsewhere.
    static func writeClip(to url: URL) throws {
        #if canImport(AVFoundation)
        let sampleRate = 44_100.0
        let audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate / 10) * 6
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try audioFile.write(from: buffer)
        #else
        let header: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20, 0, 0, 0, 0]
        try (Data(header) + Data(repeating: 6, count: 600)).write(to: url)
        #endif
    }
}
