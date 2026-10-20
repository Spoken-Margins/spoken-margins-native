#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import SessionKit

/// #2086: a voice whose files the publisher ships only inside an archive installs from that archive.
/// The installer runs against the real local HTTP server; the archives are real tar bytes, and on Apple
/// platforms real tar.bz2 made by the system's bzip2.
final class VoiceModelArchiveTests: XCTestCase {
    private var root: URL!
    private var scratch: URL!
    private var servers: [LocalHTTPServer] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("voice-archive-\(UUID().uuidString)", isDirectory: true)
        root = scratch.appendingPathComponent("Voices", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Helpers

    private func payload(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &* 7 &+ $0 / 251) })
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fileServer(_ files: [String: Data]) throws -> LocalHTTPServer {
        let server = try LocalHTTPServer { request, _ in
            guard let content = files[request.path] else { return .init(status: 404) }
            return LocalHTTPServer.file(content, for: request)
        }
        servers.append(server)
        return server
    }

    /// The archive is plain tar; this hands it over unchanged under the tar.bz2 label, so the installer's
    /// own logic is tested everywhere SessionKit builds, Linux included.
    private struct PlainTar: VoiceModelArchiveDecompressor {
        var formats: Set<String> { ["tar.bz2"] }
        func tarBytes(of url: URL, format: String, onChunk: (Data) throws -> Void) throws {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // Odd-sized pieces, so headers and members straddle chunk boundaries.
            while let block = try handle.read(upToCount: 777), !block.isEmpty { try onChunk(block) }
        }
    }

    private func installer(_ decompressor: any VoiceModelArchiveDecompressor = PlainTar(), capacity: Int64? = nil, margin: Int64 = 0) -> VoiceModelInstaller {
        VoiceModelInstaller(root: root, configuration: .init(
            marginBytes: margin, attemptsPerSource: 1, retryDelay: .zero,
            availableCapacity: { _ in capacity }, decompressor: decompressor))
    }

    private func member(_ name: String) -> VoiceModelArchiveMember {
        VoiceModelArchiveMember(archive: "int8", member: name)
    }

    private func archive(_ data: Data, sources: [String]) -> VoiceModelInstallArchive {
        VoiceModelInstallArchive(id: "int8", format: "tar.bz2", byteCount: data.count, sha256: sha(data), sources: sources)
    }

    private func staged() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path)) ?? []).sorted()
    }

    /// Every file in a folder, relative, sorted.
    private func listing(_ folder: URL) -> [String] {
        let base = folder.standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var names: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                names.append(String(url.standardizedFileURL.path.dropFirst(base.count)))
            }
        }
        return names.sorted()
    }

    // MARK: The tar reader

    func testReaderPassesOnOnlyTheWantedMembersAcrossAnyChunkSize() throws {
        let a = payload(1_000, seed: 1), b = payload(512, seed: 2), c = payload(3, seed: 3)
        let tar = TarWriter.archive([("top/", nil), ("top/a.onnx", a), ("top/b.json", b), ("top/c.txt", c)])
        for chunkSize in [1, 7, 511, 512, 513, tar.count] {
            var got: [String: Data] = [:]
            var seen: [String] = []
            var current = ""
            let reader = TarStreamReader(
                onMember: { seen.append($0.path); current = $0.path; return $0.path != "top/b.json" },
                onData: { got[current, default: Data()].append($0) },
                onMemberEnd: { _ in }
            )
            var index = 0
            while index < tar.count {
                try reader.feed(tar.subdata(in: index..<min(index + chunkSize, tar.count)))
                index += chunkSize
            }
            try reader.finish()
            XCTAssertTrue(reader.reachedEnd, "chunk \(chunkSize)")
            XCTAssertEqual(seen, ["top/a.onnx", "top/b.json", "top/c.txt"], "folders are not members; chunk \(chunkSize)")
            XCTAssertEqual(got["top/a.onnx"], a, "chunk \(chunkSize)")
            XCTAssertNil(got["top/b.json"], "an unwanted member's bytes are skipped; chunk \(chunkSize)")
            XCTAssertEqual(got["top/c.txt"], c, "chunk \(chunkSize)")
        }
    }

    func testReaderTakesLongNamesFromPaxAndGNURecords() throws {
        let long = String(repeating: "d", count: 120) + "/model.int8.onnx"
        let data = payload(600, seed: 4)
        let paxTar = TarWriter.archive([(long, data)], longNames: .pax)
        let gnuTar = TarWriter.archive([(long, data)], longNames: .gnu)
        for tar in [paxTar, gnuTar] {
            var names: [String] = []
            var bytes = Data()
            let reader = TarStreamReader(onMember: { names.append($0.path); return true }, onData: { bytes.append($0) }, onMemberEnd: { _ in })
            try reader.feed(tar)
            try reader.finish()
            XCTAssertEqual(names, [long])
            XCTAssertEqual(bytes, data)
        }
    }

    func testReaderSaysSoWhenTheStreamStopsInsideAMember() throws {
        let tar = TarWriter.archive([("a.onnx", payload(2_000, seed: 5))])
        let reader = TarStreamReader(onMember: { _ in true }, onData: { _ in }, onMemberEnd: { _ in })
        try reader.feed(tar.prefix(1_200))
        XCTAssertThrowsError(try reader.finish()) { XCTAssertEqual($0 as? VoiceModelArchiveError, .truncated) }
    }

    // MARK: Installing from an archive

    func testInstallsMembersUnderTheirOwnNamesAndDeletesTheArchive() async throws {
        let graph = payload(200_000, seed: 6), vocoder = payload(90_000, seed: 7), unrelated = payload(50_000, seed: 8)
        let style = payload(4_000, seed: 9)
        let notice = Data("Notice of modification\n".utf8)
        let tar = TarWriter.archive([
            ("pkg/", nil), ("pkg/text_encoder.int8.onnx", graph), ("pkg/text_encoder.fp32.onnx", unrelated), ("pkg/vocoder.int8.onnx", vocoder),
        ])
        let server = try fileServer(["/pkg.tar.bz2": tar, "/F1.json": style])
        let log = ProgressRecorder()

        let folder = try await installer().install(voiceId: "supertonic", version: "3", files: [
            VoiceModelInstallFile(path: "onnx/text_encoder.onnx", byteCount: graph.count, sha256: sha(graph), archiveMember: member("pkg/text_encoder.int8.onnx")),
            VoiceModelInstallFile(path: "onnx/vocoder.onnx", byteCount: vocoder.count, sha256: sha(vocoder), archiveMember: member("pkg/vocoder.int8.onnx")),
            VoiceModelInstallFile(path: "onnx/MODIFIED.txt", byteCount: notice.count, sha256: sha(notice), content: notice),
            VoiceModelInstallFile(path: "voice_styles/F1.json", byteCount: style.count, sha256: sha(style), sources: [server.url("/F1.json")]),
        ], archives: [archive(tar, sources: [server.url("/pkg.tar.bz2")])], progress: { log.add($0) })

        XCTAssertEqual(listing(folder), ["onnx/MODIFIED.txt", "onnx/text_encoder.onnx", "onnx/vocoder.onnx", "voice_styles/F1.json"],
                       "only the named members, under the catalog's names; no archive, no other member")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("onnx/text_encoder.onnx")), graph)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("onnx/vocoder.onnx")), vocoder)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("onnx/MODIFIED.txt")), notice)
        XCTAssertEqual(staged(), [])
        XCTAssertEqual(server.requests(for: "/pkg.tar.bz2").count, 1, "the archive downloads once for both members")
        XCTAssertEqual(log.last, VoiceModelInstallProgress(bytesDownloaded: Int64(tar.count + style.count), totalBytes: Int64(tar.count + style.count)),
                       "progress counts what downloads: the archive and the separate file, not the unpacked members")
    }

    func testAMemberWhoseBytesAreWrongInstallsNothingAndKeepsThePreviousVersion() async throws {
        let good = payload(30_000, seed: 10)
        let v1Tar = TarWriter.archive([("m.onnx", good)])
        var bad = good
        bad[100] ^= 0x01
        let v2Tar = TarWriter.archive([("m.onnx", bad)])
        let server = try fileServer(["/v1.tar.bz2": v1Tar, "/v2.tar.bz2": v2Tar])
        let installer = installer()
        try await installer.install(voiceId: "v", version: "1", files: [
            VoiceModelInstallFile(path: "model.onnx", byteCount: good.count, sha256: sha(good), archiveMember: member("m.onnx")),
        ], archives: [archive(v1Tar, sources: [server.url("/v1.tar.bz2")])])

        do {
            // The archive matches its own hash; the member inside it doesn't match the catalog.
            try await installer.install(voiceId: "v", version: "2", files: [
                VoiceModelInstallFile(path: "model.onnx", byteCount: good.count, sha256: sha(good), archiveMember: member("m.onnx")),
            ], archives: [archive(v2Tar, sources: [server.url("/v2.tar.bz2")])])
            XCTFail("a member with the wrong bytes must not install")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .checksumMismatch(path: "model.onnx"))
        }
        XCTAssertEqual(installer.installedVersions(voiceId: "v"), ["1"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("v/1/model.onnx")), good)
        XCTAssertEqual(staged(), [], "the failed upgrade's staging, archive included, is gone")
    }

    func testAnArchiveWithTheWrongHashIsThrownAwayBeforeAnythingIsUnpacked() async throws {
        let model = payload(20_000, seed: 11)
        let tar = TarWriter.archive([("m.onnx", model)])
        var tampered = tar
        tampered[tampered.count - 2_000] ^= 0xff
        let server = try fileServer(["/a.tar.bz2": tampered])
        do {
            try await installer().install(voiceId: "v", version: "1", files: [
                VoiceModelInstallFile(path: "model.onnx", byteCount: model.count, sha256: sha(model), archiveMember: member("m.onnx")),
            ], archives: [archive(tar, sources: [server.url("/a.tar.bz2")])])
            XCTFail("an archive that doesn't match its hash must not be used")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .checksumMismatch(path: ".archives/int8.tar.bz2"))
        }
        XCTAssertEqual(installer().installedVersions(voiceId: "v"), [])
        XCTAssertEqual(staged(), [])
    }

    func testAMemberTheArchiveDoesNotHoldFailsTheInstall() async throws {
        let model = payload(5_000, seed: 12)
        let tar = TarWriter.archive([("other.onnx", model)])
        let server = try fileServer(["/a.tar.bz2": tar])
        do {
            try await installer().install(voiceId: "v", version: "1", files: [
                VoiceModelInstallFile(path: "model.onnx", byteCount: model.count, sha256: sha(model), archiveMember: member("m.onnx")),
            ], archives: [archive(tar, sources: [server.url("/a.tar.bz2")])])
            XCTFail("a missing member must fail the install")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .downloadFailed(path: "model.onnx", problem: "the archive has no member m.onnx"))
        }
        XCTAssertEqual(installer().installedVersions(voiceId: "v"), [])
    }

    func testAnInstallThatStoppedAfterUnpackingDoesNotDownloadTheArchiveAgain() async throws {
        let model = payload(40_000, seed: 13), style = payload(1_000, seed: 14)
        let tar = TarWriter.archive([("m.onnx", model)])
        let server = try fileServer(["/a.tar.bz2": tar, "/style.json": style])
        let files = [
            VoiceModelInstallFile(path: "model.onnx", byteCount: model.count, sha256: sha(model), archiveMember: member("m.onnx")),
            VoiceModelInstallFile(path: "style.json", byteCount: style.count, sha256: sha(style), sources: [server.url("/style.json")]),
        ]
        // As if an earlier install unpacked the member and was stopped before the style file finished.
        let staging = root.appendingPathComponent(".staging/v@1", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try model.write(to: staging.appendingPathComponent("model.onnx"))

        try await installer().install(voiceId: "v", version: "1", files: files, archives: [archive(tar, sources: [server.url("/a.tar.bz2")])])
        XCTAssertEqual(server.requests(for: "/a.tar.bz2").count, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("v/1/model.onnx")), model)
    }

    func testRoomIsCheckedForTheArchiveAndItsMembersTogether() async throws {
        let model = payload(60_000, seed: 15)
        let tar = TarWriter.archive([("m.onnx", model)])
        let server = try fileServer(["/a.tar.bz2": tar])
        let needed = Int64(tar.count + model.count)
        do {
            try await installer(capacity: needed - 1).install(voiceId: "v", version: "1", files: [
                VoiceModelInstallFile(path: "model.onnx", byteCount: model.count, sha256: sha(model), archiveMember: member("m.onnx")),
            ], archives: [archive(tar, sources: [server.url("/a.tar.bz2")])])
            XCTFail("the archive and its member don't both fit")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .insufficientSpace(neededBytes: needed, availableBytes: needed - 1))
        }
        XCTAssertEqual(server.requests(for: "/a.tar.bz2").count, 0, "refused before downloading anything")
    }

    func testRefusesArchiveRequestsThatDoNotAddUp() async throws {
        let model = payload(100, seed: 16)
        let tar = TarWriter.archive([("m.onnx", model)])
        let good = archive(tar, sources: ["https://example.org/a.tar.bz2"])
        let memberFile = VoiceModelInstallFile(path: "model.onnx", byteCount: model.count, sha256: sha(model), archiveMember: member("m.onnx"))
        var both = memberFile
        both.sources = ["https://example.org/m.onnx"]
        var otherFormat = good
        otherFormat.format = "tar.zst"
        let cases: [(String, [VoiceModelInstallFile], [VoiceModelInstallArchive])] = [
            ("unknown archive", [memberFile], []),
            ("two places for one file", [both], [good]),
            ("a format this build can't open", [memberFile], [otherFormat]),
            ("an archive no file uses", [VoiceModelInstallFile(path: "x", byteCount: 1, sha256: sha(Data([1])), sources: ["https://example.org/x"])], [good]),
            ("one member twice", [memberFile, VoiceModelInstallFile(path: "copy.onnx", byteCount: model.count, sha256: sha(model), archiveMember: member("m.onnx"))], [good]),
        ]
        for (label, files, archives) in cases {
            do {
                try await installer().install(voiceId: "v", version: "1", files: files, archives: archives)
                XCTFail("\(label) must be refused")
            } catch let error as VoiceModelInstallError {
                guard case .invalidRequest = error else { return XCTFail("\(label): \(error)") }
            }
        }
    }

    func testCarriedContentMustMatchItsHash() async throws {
        let notice = Data("Notice\n".utf8)
        do {
            try await installer().install(voiceId: "v", version: "1", files: [
                VoiceModelInstallFile(path: "MODIFIED.txt", byteCount: notice.count, sha256: sha(Data("other\n".utf8)), content: notice),
            ])
            XCTFail("carried bytes with the wrong hash must not install")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .checksumMismatch(path: "MODIFIED.txt"))
        }
    }

    // MARK: Real tar.bz2 (Apple platforms, the system's libbz2)

    #if canImport(CBZip2)
    private func bzip2(_ data: Data, name: String) throws -> Data {
        let input = scratch.appendingPathComponent(name)
        try data.write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bzip2")
        process.arguments = ["-k", "-f", "-9", input.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: input.appendingPathExtension("bz2"))
    }

    func testInstallsFromARealTarBZip2() async throws {
        let graph = payload(700_000, seed: 17), other = payload(300_000, seed: 18)
        let tar = TarWriter.archive([("sherpa/", nil), ("sherpa/vocoder.int8.onnx", graph), ("sherpa/vocoder.onnx", other)])
        let compressed = try bzip2(tar, name: "real.tar")
        let server = try fileServer(["/real.tar.bz2": compressed])
        let folder = try await installer(BZip2ArchiveDecompressor()).install(voiceId: "supertonic", version: "3", files: [
            VoiceModelInstallFile(path: "onnx/vocoder.onnx", byteCount: graph.count, sha256: sha(graph), archiveMember: member("sherpa/vocoder.int8.onnx")),
        ], archives: [archive(compressed, sources: [server.url("/real.tar.bz2")])])
        XCTAssertEqual(listing(folder), ["onnx/vocoder.onnx"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("onnx/vocoder.onnx")), graph)
    }

    func testDecompressesStreamsWrittenBackToBack() throws {
        // A parallel bzip2 (pbzip2, lbzip2) writes one stream per block; the reader must not stop after the first.
        let first = payload(10_000, seed: 19), second = payload(20_000, seed: 20)
        let joined = try bzip2(first, name: "one") + bzip2(second, name: "two")
        let url = scratch.appendingPathComponent("joined.bz2")
        try joined.write(to: url)
        var out = Data()
        try BZip2ArchiveDecompressor().tarBytes(of: url, format: "tar.bz2") { out.append($0) }
        XCTAssertEqual(out, first + second)
    }

    func testDamagedCompressedBytesAreAnErrorNotSilence() throws {
        var damaged = try bzip2(payload(50_000, seed: 21), name: "damaged")
        damaged[damaged.count / 2] ^= 0xff
        let url = scratch.appendingPathComponent("damaged.bz2")
        try damaged.write(to: url)
        XCTAssertThrowsError(try BZip2ArchiveDecompressor().tarBytes(of: url, format: "tar.bz2") { _ in })
        let cut = scratch.appendingPathComponent("cut.bz2")
        try damaged.prefix(damaged.count / 3).write(to: cut)
        XCTAssertThrowsError(try BZip2ArchiveDecompressor().tarBytes(of: cut, format: "tar.bz2") { _ in })
    }
    #endif
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VoiceModelInstallProgress] = []
    func add(_ value: VoiceModelInstallProgress) { lock.withLock { values.append(value) } }
    var last: VoiceModelInstallProgress? { lock.withLock { values.last } }
}

/// Writes ustar archives for the tests: folders (nil data) and regular files, with long names as pax
/// `path` records or GNU `L` entries.
enum TarWriter {
    enum LongNames { case pax, gnu }

    static func archive(_ entries: [(String, Data?)], longNames: LongNames = .pax) -> Data {
        var out = Data()
        for (name, data) in entries {
            if name.utf8.count > 100 {
                switch longNames {
                case .pax:
                    let body = paxRecord("path", name)
                    out += header(name: "PaxHeader", size: body.count, type: "x") + padded(body)
                case .gnu:
                    let body = Data(name.utf8) + Data([0])
                    out += header(name: "././@LongLink", size: body.count, type: "L") + padded(body)
                }
            }
            // The header keeps the last 100 bytes; the record before it carries the whole name.
            let short = name.utf8.count > 100 ? String(decoding: name.utf8.suffix(100), as: UTF8.self) : name
            out += header(name: short, size: data?.count ?? 0, type: data == nil ? "5" : "0")
            if let data { out += padded(data) }
        }
        return out + Data(count: 1_024)
    }

    private static func paxRecord(_ key: String, _ value: String) -> Data {
        let body = " \(key)=\(value)\n"
        var length = body.utf8.count + 1
        while "\(length)\(body)".utf8.count != length { length += 1 }
        return Data("\(length)\(body)".utf8)
    }

    private static func padded(_ data: Data) -> Data {
        data + Data(count: (512 - data.count % 512) % 512)
    }

    private static func header(name: String, size: Int, type: Character) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, width: Int) {
            for (index, byte) in text.utf8.prefix(width).enumerated() { block[offset + index] = byte }
        }
        put(name, at: 0, width: 100)
        put("0000644", at: 100, width: 8)
        put("0000000", at: 108, width: 8)
        put("0000000", at: 116, width: 8)
        put(String(format: "%011o", size), at: 124, width: 12)
        put("00000000000", at: 136, width: 12)
        put("        ", at: 148, width: 8)
        block[156] = type.asciiValue!
        put("ustar", at: 257, width: 6)
        put("00", at: 263, width: 2)
        let sum = block.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), at: 148, width: 6)
        block[154] = 0
        block[155] = UInt8(ascii: " ")
        return Data(block)
    }
}
