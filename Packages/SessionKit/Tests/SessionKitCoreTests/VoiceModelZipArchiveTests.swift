#if canImport(Compression)
import CryptoKit
import Foundation
import XCTest
@testable import SessionKit

/// #2704: Phonon's Core ML bundle is published only as a `.zip` release asset, so the installer takes the
/// catalog's members out of a zip. The archives here are real zips written by the system's `/usr/bin/zip`,
/// deflated and stored, served by the real local HTTP server.
final class VoiceModelZipArchiveTests: XCTestCase {
    private var root: URL!
    private var scratch: URL!
    private var servers: [LocalHTTPServer] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("voice-zip-\(UUID().uuidString)", isDirectory: true)
        root = scratch.appendingPathComponent("Voices", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Helpers

    /// Compressible but not constant, so deflate produces several blocks and a real stream.
    private func payload(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 / 3) &* 31 &+ Int(seed) &* 7 &+ $0 / 251) })
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `files` under a fresh folder and zips it with the system's zip. `store` writes members uncompressed.
    private func zip(_ files: [String: Data], store: Bool = false, name: String = "bundle") throws -> Data {
        let folder = scratch.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        for (path, data) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let output = scratch.appendingPathComponent("\(name)-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = folder
        process.arguments = ["-q", "-r", store ? "-0" : "-9", "-X", output.path, "."]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: output)
    }

    private func read(_ data: Data, wanting: Set<String>) throws -> (seen: [String], got: [String: Data]) {
        let url = scratch.appendingPathComponent("read-\(UUID().uuidString).zip")
        try data.write(to: url)
        var seen: [String] = []
        var got: [String: Data] = [:]
        var current: String?
        try ZipArchiveReader.read(url, onMember: { member in
            seen.append(member.path)
            guard wanting.contains(member.path) else { return false }
            current = member.path
            got[member.path] = Data()
            return true
        }, onData: { chunk in
            got[current!]!.append(chunk)
        }, onMemberEnd: { member in
            XCTAssertEqual(member.path, current)
            current = nil
        })
        return (seen.sorted(), got)
    }

    private func fileServer(_ files: [String: Data]) throws -> LocalHTTPServer {
        let server = try LocalHTTPServer { request, _ in
            guard let content = files[request.path] else { return .init(status: 404) }
            return LocalHTTPServer.file(content, for: request)
        }
        servers.append(server)
        return server
    }

    private func installer() -> VoiceModelInstaller {
        VoiceModelInstaller(root: root, configuration: .init(marginBytes: 0, attemptsPerSource: 1, retryDelay: .zero, availableCapacity: { _ in nil }))
    }

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

    // MARK: The reader

    func testReaderInflatesOnlyTheWantedMembers() throws {
        let weights = payload(3_000_000, seed: 1), tokenizer = payload(40_000, seed: 2), unwanted = payload(70_000, seed: 3)
        let archive = try zip([
            "bundle/flow.mlpackage/Data/weight.bin": weights,
            "bundle/tokenizer.json": tokenizer,
            "bundle/voices/Character Voice.safetensors": unwanted,
        ])
        let result = try read(archive, wanting: ["bundle/flow.mlpackage/Data/weight.bin", "bundle/tokenizer.json"])
        XCTAssertEqual(result.seen, ["bundle/flow.mlpackage/Data/weight.bin", "bundle/tokenizer.json", "bundle/voices/Character Voice.safetensors"],
                       "every regular file is offered, folders are not")
        XCTAssertEqual(result.got["bundle/flow.mlpackage/Data/weight.bin"], weights, "a multi-megabyte deflated member comes out byte for byte")
        XCTAssertEqual(result.got["bundle/tokenizer.json"], tokenizer)
        XCTAssertNil(result.got["bundle/voices/Character Voice.safetensors"])
    }

    func testReaderCopiesStoredMembers() throws {
        let data = payload(1_500_000, seed: 4)
        let result = try read(try zip(["a/b.bin": data], store: true), wanting: ["a/b.bin"])
        XCTAssertEqual(result.got["a/b.bin"], data)
    }

    func testReaderReadsEmptyMembers() throws {
        let result = try read(try zip(["empty.txt": Data(), "x.bin": payload(10, seed: 5)]), wanting: ["empty.txt"])
        XCTAssertEqual(result.got["empty.txt"], Data())
    }

    func testDamagedDeflateIsAnErrorNotShortData() throws {
        var archive = try zip(["m.bin": payload(400_000, seed: 6)])
        // Overwrite part of the member's compressed bytes, past its local header.
        for index in 200..<4_000 { archive[index] = 0xff }
        XCTAssertThrowsError(try read(archive, wanting: ["m.bin"]))
    }

    func testATruncatedZipHasNoIndex() throws {
        let archive = try zip(["m.bin": payload(100_000, seed: 7)])
        XCTAssertThrowsError(try read(archive.prefix(archive.count - 30), wanting: ["m.bin"])) { error in
            XCTAssertEqual(error as? VoiceModelArchiveError, .corrupt("no zip end record"))
        }
        XCTAssertThrowsError(try read(Data("not a zip".utf8), wanting: []))
    }

    // MARK: The installer

    func testInstallsMembersOfAZipUnderTheCatalogsNamesAndDeletesTheArchive() async throws {
        let model = payload(900_000, seed: 8), voice = payload(256_080, seed: 9), skipped = payload(256_080, seed: 10)
        let archive = try zip([
            "phonon/mimi.mlpackage/Data/com.apple.CoreML/weights/weight.bin": model,
            "phonon/voices/Pippa.safetensors": voice,
            "phonon/voices/Grub the Ogre.safetensors": skipped,
        ])
        let server = try fileServer(["/phonon.zip": archive])
        let zipArchive = VoiceModelInstallArchive(id: "coreml-bundle", format: "zip", byteCount: archive.count, sha256: sha(archive),
                                                  sources: [server.url("/phonon.zip")])
        let folder = try await installer().install(voiceId: "phonon-31m-en", version: "0.4.2", files: [
            VoiceModelInstallFile(path: "mimi.mlpackage/Data/com.apple.CoreML/weights/weight.bin", byteCount: model.count, sha256: sha(model),
                                  archiveMember: VoiceModelArchiveMember(archive: "coreml-bundle", member: "phonon/mimi.mlpackage/Data/com.apple.CoreML/weights/weight.bin")),
            VoiceModelInstallFile(path: "voices/Pippa.safetensors", byteCount: voice.count, sha256: sha(voice),
                                  archiveMember: VoiceModelArchiveMember(archive: "coreml-bundle", member: "phonon/voices/Pippa.safetensors")),
        ], archives: [zipArchive])
        XCTAssertEqual(listing(folder), ["mimi.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "voices/Pippa.safetensors"],
                       "only the catalog's members, at the catalog's paths; no archive left behind")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("voices/Pippa.safetensors")), voice)
        XCTAssertEqual(server.requests(for: "/phonon.zip").count, 1)
    }

    func testAZipMemberWithTheWrongHashInstallsNothing() async throws {
        let model = payload(50_000, seed: 11)
        let archive = try zip(["p/m.bin": model])
        let server = try fileServer(["/p.zip": archive])
        do {
            _ = try await installer().install(voiceId: "phonon-31m-en", version: "0.4.2", files: [
                VoiceModelInstallFile(path: "m.bin", byteCount: model.count, sha256: String(repeating: "0", count: 64),
                                      archiveMember: VoiceModelArchiveMember(archive: "b", member: "p/m.bin")),
            ], archives: [VoiceModelInstallArchive(id: "b", format: "zip", byteCount: archive.count, sha256: sha(archive), sources: [server.url("/p.zip")])])
            XCTFail("a member that doesn't hash to the catalog's value must not install")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .checksumMismatch(path: "m.bin"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("phonon-31m-en/0.4.2").path))
    }

    /// Gradium's own zip, when a local copy is named by `SM_PHONON_BUNDLE_ZIP` (it is 137 MB, so it isn't
    /// downloaded here): every member the bundle's `bundle.json` lists comes out with its listed SHA-256.
    func testGradiumsPhononBundleUnpacksToItsListedHashes() throws {
        guard let path = ProcessInfo.processInfo.environment["SM_PHONON_BUNDLE_ZIP"] else {
            throw XCTSkip("set SM_PHONON_BUNDLE_ZIP to a copy of phonon-31m-en-coreml.zip to run this")
        }
        let url = URL(fileURLWithPath: path)
        var listing = Data()
        try ZipArchiveReader.read(url, onMember: { $0.path == "phonon-31m-en-coreml/bundle.json" },
                                  onData: { listing.append($0) }, onMemberEnd: { _ in })
        struct Bundle: Decodable { struct File: Decodable { let path: String; let sha256: String; let size: Int }; let files: [File] }
        let expected = Dictionary(uniqueKeysWithValues: try JSONDecoder().decode(Bundle.self, from: listing).files
            .map { ("phonon-31m-en-coreml/" + $0.path, $0) })
        var hashers: [String: SHA256] = [:]
        var current = ""
        var finished: [String: String] = [:]
        try ZipArchiveReader.read(url, onMember: { member in
            current = member.path
            hashers[member.path] = SHA256()
            return expected[member.path] != nil
        }, onData: { hashers[current]!.update(data: $0) }, onMemberEnd: { member in
            finished[member.path] = hashers[member.path]!.finalize().map { String(format: "%02x", $0) }.joined()
        })
        XCTAssertEqual(finished.count, expected.count)
        for (path, file) in expected { XCTAssertEqual(finished[path], file.sha256, path) }
    }

    func testTheCatalogAcceptsZipArchives() {
        XCTAssertTrue(VoiceModelArchive.supportedFormats.contains("zip"))
        XCTAssertTrue(ZipArchiveReader.formats.contains("zip"))
    }
}
#endif
