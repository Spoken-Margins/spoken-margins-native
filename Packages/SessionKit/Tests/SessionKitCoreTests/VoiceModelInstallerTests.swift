#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import SessionKit

/// #1817: a downloadable voice installs completely or not at all. Every download here goes through the
/// real `URLSessionVoiceModelTransport` to a real local HTTP server (LocalHTTPServer), on real files.
final class VoiceModelInstallerTests: XCTestCase {
    private var root: URL!
    private var servers: [LocalHTTPServer] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-installer-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Voices", isDirectory: true)
    }

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers = []
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: Helpers

    /// Deterministic bytes that differ by `seed`, so a mix-up between files or versions shows.
    private func payload(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &* 7 &+ $0 / 251) })
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func startServer(_ handler: @escaping LocalHTTPServer.Handler) throws -> LocalHTTPServer {
        let server = try LocalHTTPServer(handler: handler)
        servers.append(server)
        return server
    }

    /// Serves `files` (path on the server -> bytes), as a plain file server.
    private func fileServer(_ files: [String: Data]) throws -> LocalHTTPServer {
        try startServer { request, _ in
            guard let content = files[request.path] else { return .init(status: 404) }
            return LocalHTTPServer.file(content, for: request)
        }
    }

    private func installFile(_ path: String, _ data: Data, sources: [String]) -> VoiceModelInstallFile {
        VoiceModelInstallFile(path: path, byteCount: data.count, sha256: sha(data), sources: sources)
    }

    private func installer(
        marginBytes: Int64 = 0,
        attemptsPerSource: Int = 3,
        availableCapacity: @escaping @Sendable (URL) -> Int64? = { _ in nil }
    ) -> VoiceModelInstaller {
        VoiceModelInstaller(
            root: root,
            configuration: .init(marginBytes: marginBytes, attemptsPerSource: attemptsPerSource, retryDelay: .zero, availableCapacity: availableCapacity)
        )
    }

    private func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    private func stagedFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".staging").path)) ?? []).sorted()
    }

    // MARK: Installing

    func testInstallsEveryFileAndPutsTheVoiceInOnePlace() async throws {
        let config = payload(2_000, seed: 1)
        let model = payload(300_000, seed: 2)
        let server = try fileServer(["/config.json": config, "/model.onnx": model])

        let folder = try await installer().install(voiceId: "supertonic", version: "2026-05-11", files: [
            installFile("tts.json", config, sources: [server.url("/config.json")]),
            installFile("onnx/model.onnx", model, sources: [server.url("/model.onnx")]),
        ])

        XCTAssertEqual(folder.standardizedFileURL, root.appendingPathComponent("supertonic/2026-05-11").standardizedFileURL)
        XCTAssertEqual(try read(folder.appendingPathComponent("tts.json")), config)
        XCTAssertEqual(try read(folder.appendingPathComponent("onnx/model.onnx")), model)
        XCTAssertEqual(installer().installedVersions(voiceId: "supertonic"), ["2026-05-11"])
        XCTAssertEqual(installer().installedFolder(voiceId: "supertonic", version: "2026-05-11")?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(stagedFolders(), [], "the staging folder moved into place; nothing is left behind")
    }

    func testReportsProgressUpToTheWholeVoice() async throws {
        let first = payload(120_000, seed: 3)
        let second = payload(80_000, seed: 4)
        let server = try fileServer(["/a": first, "/b": second])
        let seen = ProgressLog()

        try await installer().install(voiceId: "v", version: "1", files: [
            installFile("a.bin", first, sources: [server.url("/a")]),
            installFile("b.bin", second, sources: [server.url("/b")]),
        ]) { seen.add($0) }

        let values = seen.values
        XCTAssertEqual(values.last, VoiceModelInstallProgress(bytesDownloaded: 200_000, totalBytes: 200_000))
        XCTAssertEqual(values.map(\.bytesDownloaded), values.map(\.bytesDownloaded).sorted(), "progress never goes backwards")
        XCTAssertTrue(values.allSatisfy { $0.totalBytes == 200_000 })
    }

    // MARK: Interrupted transfers

    func testResumesATransferTheConnectionCutHalfway() async throws {
        let model = payload(400_000, seed: 5)
        let server = try startServer { request, index in
            var reply = LocalHTTPServer.file(model, for: request)
            if index == 0 { reply.cutAfter = 150_000 }
            return reply
        }

        let folder = try await installer().install(voiceId: "v", version: "1", files: [
            installFile("model.onnx", model, sources: [server.url("/m")]),
        ])

        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
        let requests = server.requests(for: "/m")
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].headers["range"])
        let resumedAt = try XCTUnwrap(requests[1].headers["range"].flatMap { Int($0.dropFirst("bytes=".count).dropLast()) })
        XCTAssertGreaterThan(resumedAt, 0, "the second request continues instead of starting over")
        XCTAssertLessThanOrEqual(resumedAt, 150_000)
    }

    func testAnEarlierFailedInstallLeavesAPartialFileThatALaterInstallResumes() async throws {
        let model = payload(300_000, seed: 6)
        let server = try startServer { request, index in
            var reply = LocalHTTPServer.file(model, for: request)
            if index == 0 { reply.cutAfter = 100_000 }
            return reply
        }
        let files = [installFile("model.onnx", model, sources: [server.url("/m")])]

        // One attempt per source: the cut connection fails this install.
        do {
            try await installer(attemptsPerSource: 1).install(voiceId: "v", version: "1", files: files)
            XCTFail("a cut transfer with no retries should fail")
        } catch let error as VoiceModelInstallError {
            guard case .downloadFailed(let path, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(path, "model.onnx")
        }
        XCTAssertFalse(exists("v"), "nothing is installed")
        XCTAssertEqual(stagedFolders(), ["v@1"], "the partial download stays staged so it can resume")

        let folder = try await installer().install(voiceId: "v", version: "1", files: files)

        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
        let range = try XCTUnwrap(server.requests(for: "/m").last?.headers["range"])
        XCTAssertTrue(range.hasPrefix("bytes=") && range != "bytes=0-", "the second install asked only for the rest: \(range)")
    }

    func testAServerThatIgnoresRangeRestartsTheFileFromTheStart() async throws {
        let model = payload(250_000, seed: 7)
        let server = try startServer { request, index in
            var reply = LocalHTTPServer.file(model, for: request, honoringRange: false)
            if index == 0 { reply.cutAfter = 90_000 }
            return reply
        }

        let folder = try await installer().install(voiceId: "v", version: "1", files: [
            installFile("model.onnx", model, sources: [server.url("/m")]),
        ])

        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model, "bytes from the cut transfer aren't kept in front of a full copy")
    }

    // MARK: Bad bytes and bad sources

    func testRejectsAFileWhoseChecksumIsWrongAndInstallsNothing() async throws {
        let good = payload(50_000, seed: 8)
        var corrupted = good
        corrupted[corrupted.count / 2] ^= 0xFF
        let server = try fileServer(["/m": corrupted])

        do {
            try await installer().install(voiceId: "v", version: "1", files: [installFile("model.onnx", good, sources: [server.url("/m")])])
            XCTFail("a wrong checksum must not install")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .checksumMismatch(path: "model.onnx"))
        }
        XCTAssertFalse(exists("v"))
        XCTAssertEqual(stagedFolders(), [], "a corrupt download is thrown away")
    }

    func testMovesToTheNextSourceWhenTheFirstIsMissing() async throws {
        let model = payload(80_000, seed: 9)
        let server = try fileServer(["/mirror/m": model])

        let folder = try await installer().install(voiceId: "v", version: "1", files: [
            installFile("model.onnx", model, sources: [server.url("/upstream/m"), server.url("/mirror/m")]),
        ])

        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
        XCTAssertEqual(server.requests(for: "/upstream/m").count, 1, "a 404 isn't retried")
        XCTAssertEqual(server.requests(for: "/mirror/m").count, 1)
    }

    func testMovesToTheNextSourceWhenTheFirstSendsThreeBytesTooMany() async throws {
        let model = payload(60_000, seed: 10)
        let server = try startServer { request, _ in
            switch request.path {
            case "/long": .init(body: model + Data([1, 2, 3]))
            default: LocalHTTPServer.file(model, for: request)
            }
        }

        let folder = try await installer().install(voiceId: "v", version: "1", files: [
            installFile("model.onnx", model, sources: [server.url("/long"), server.url("/right")]),
        ])

        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
    }

    func testStopsWritingWhenASourceSendsFarMoreThanTheExpectedBytes() async throws {
        let model = payload(60_000, seed: 29)
        let tooMuch = model + payload(3_000_000, seed: 30)
        let server = try startServer { request, _ in
            request.path == "/long" ? .init(body: tooMuch) : LocalHTTPServer.file(model, for: request)
        }
        let rootURL: URL = root
        let watching = SizeWatchingTransport(root: { rootURL })
        let installer = VoiceModelInstaller(
            root: root,
            transport: watching,
            configuration: .init(marginBytes: 0, attemptsPerSource: 3, retryDelay: .zero, availableCapacity: { _ in nil })
        )

        do {
            try await installer.install(voiceId: "v", version: "1", files: [installFile("model.onnx", model, sources: [server.url("/long")])])
            XCTFail("a source that sends too many bytes must fail")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .downloadFailed(path: "model.onnx", problem: "the server sent more bytes than expected"))
        }
        XCTAssertGreaterThan(watching.largestFileSeen, 0, "the watcher saw the partial file")
        XCTAssertLessThanOrEqual(watching.largestFileSeen, Int64(model.count), "nothing past the expected size is ever written to disk")
        XCTAssertEqual(server.requests(for: "/long").count, 1, "an oversize source isn't retried")

        // The next source is still tried afterwards.
        let folder = try await installer.install(voiceId: "w", version: "1", files: [
            installFile("model.onnx", model, sources: [server.url("/long"), server.url("/right")]),
        ])
        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
        XCTAssertLessThanOrEqual(watching.largestFileSeen, Int64(model.count))
    }

    func testMovesToTheNextSourceWhenTheFirstOneKeepsFailing() async throws {
        let model = payload(40_000, seed: 11)
        let server = try startServer { request, _ in
            request.path == "/down" ? .init(status: 503) : LocalHTTPServer.file(model, for: request)
        }

        try await installer().install(voiceId: "v", version: "1", files: [
            installFile("model.onnx", model, sources: [server.url("/down"), server.url("/up")]),
        ])

        XCTAssertEqual(server.requests(for: "/down").count, 3, "a server error is retried up to the attempt limit")
    }

    func testFailsWithTheLastProblemWhenEverySourceFails() async throws {
        let model = payload(10_000, seed: 12)
        let server = try fileServer([:])

        do {
            try await installer().install(voiceId: "v", version: "1", files: [
                installFile("model.onnx", model, sources: [server.url("/a"), server.url("/b")]),
            ])
            XCTFail("no source has the file")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .downloadFailed(path: "model.onnx", problem: "the server answered HTTP 404"))
        }
        XCTAssertFalse(exists("v"))
    }

    func testUsesOnlyHTTPSAddressesWithoutCredentials() async throws {
        let model = payload(20_000, seed: 13)
        let refused = [
            "http://example.com/m", "ftp://example.com/m", "file:///etc/passwd",
            "https://user:secret@example.com/m", "https://:secret@example.com/m", "not a url", "https:///no-host",
        ]
        let allowed = "https://downloads.example.com/m"

        // The refused addresses are never requested; the one plain HTTPS address is, and installs.
        let transport = RecordingTransport(serving: model)
        let installer = VoiceModelInstaller(
            root: root,
            transport: transport,
            configuration: .init(marginBytes: 0, attemptsPerSource: 1, retryDelay: .zero, availableCapacity: { _ in nil })
        )
        let folder = try await installer.install(voiceId: "v", version: "1", files: [
            installFile("model.onnx", model, sources: refused + [allowed]),
        ])
        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
        XCTAssertEqual(transport.fetched, [allowed], "only the HTTPS address without credentials was requested")

        // With nothing usable the install fails without a single request, naming the last refused address.
        let onlyRefused = RecordingTransport(serving: model)
        let refusingInstaller = VoiceModelInstaller(
            root: root,
            transport: onlyRefused,
            configuration: .init(marginBytes: 0, attemptsPerSource: 1, retryDelay: .zero, availableCapacity: { _ in nil })
        )
        do {
            try await refusingInstaller.install(voiceId: "w", version: "1", files: [installFile("model.onnx", model, sources: refused)])
            XCTFail("only refused addresses")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .downloadFailed(path: "model.onnx", problem: "https:///no-host is not a usable address"))
        }
        XCTAssertEqual(onlyRefused.fetched, [])
        XCTAssertFalse(exists("w"))
    }

    func testNeverSendsARequestToAnAddressThatCarriesCredentialsEvenOnThisMachine() async throws {
        let model = payload(20_000, seed: 28)
        let server = try fileServer(["/m": model])
        let withUser = server.url("/m").replacingOccurrences(of: "http://", with: "http://user@")
        let withPassword = server.url("/m").replacingOccurrences(of: "http://", with: "http://user:pw@")
        let withPasswordOnly = server.url("/m").replacingOccurrences(of: "http://", with: "http://:pw@")

        do {
            try await installer().install(voiceId: "v", version: "1", files: [
                installFile("model.onnx", model, sources: [withUser, withPasswordOnly, withPassword]),
            ])
            XCTFail("an address with credentials must not be used")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .downloadFailed(path: "model.onnx", problem: "\(withPassword) is not a usable address"))
        }
        XCTAssertEqual(server.requests.count, 0, "the loopback server never saw a request")

        // The same server without credentials is a usable source, so the refusal above is about the credentials.
        let folder = try await installer().install(voiceId: "v", version: "1", files: [installFile("model.onnx", model, sources: [server.url("/m")])])
        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
        XCTAssertEqual(server.requests.count, 1)
    }

    // MARK: Upgrades

    func testAFailedUpgradeLeavesThePreviousVersionPlayable() async throws {
        let v1 = payload(70_000, seed: 14)
        let v2 = payload(90_000, seed: 15)
        var v2Corrupted = v2
        v2Corrupted[10] ^= 0x55
        let server = try fileServer(["/v1": v1, "/v2": v2Corrupted])
        let installer = installer()

        try await installer.install(voiceId: "v", version: "1", files: [installFile("model.onnx", v1, sources: [server.url("/v1")])])
        do {
            try await installer.install(voiceId: "v", version: "2", files: [installFile("model.onnx", v2, sources: [server.url("/v2")])])
            XCTFail("the corrupt upgrade must fail")
        } catch is VoiceModelInstallError {}

        XCTAssertEqual(installer.installedVersions(voiceId: "v"), ["1"])
        XCTAssertEqual(try read(root.appendingPathComponent("v/1/model.onnx")), v1)
        XCTAssertEqual(stagedFolders(), [], "only the failed upgrade's staging folder was deleted")
    }

    func testAnUpgradeThatCannotFinishLeavesThePreviousVersionAndItsStagedPartial() async throws {
        let v1 = payload(30_000, seed: 16)
        let v2 = payload(90_000, seed: 17)
        let server = try startServer { request, _ in
            guard request.path == "/v2" else { return LocalHTTPServer.file(v1, for: request) }
            var reply = LocalHTTPServer.file(v2, for: request)
            reply.cutAfter = 40_000
            return reply
        }
        let installer = installer(attemptsPerSource: 1)

        try await installer.install(voiceId: "v", version: "1", files: [installFile("model.onnx", v1, sources: [server.url("/v1")])])
        do {
            try await installer.install(voiceId: "v", version: "2", files: [installFile("model.onnx", v2, sources: [server.url("/v2")])])
            XCTFail("the connection is cut")
        } catch is VoiceModelInstallError {}

        XCTAssertEqual(installer.installedVersions(voiceId: "v"), ["1"])
        XCTAssertEqual(try read(root.appendingPathComponent("v/1/model.onnx")), v1)
        XCTAssertEqual(stagedFolders(), ["v@2"], "the unfinished upgrade stays staged")
        let partial = try read(root.appendingPathComponent(".staging/v@2/model.onnx.partial"))
        XCTAssertGreaterThan(partial.count, 0)
        XCTAssertLessThan(partial.count, v2.count)
        XCTAssertEqual(partial, v2.prefix(partial.count), "what was kept is the start of the new version")
    }

    func testASuccessfulUpgradeReplacesTheOldVersion() async throws {
        let v1 = payload(30_000, seed: 18)
        let v2 = payload(35_000, seed: 19)
        let server = try fileServer(["/v1": v1, "/v2": v2])
        let installer = installer()

        try await installer.install(voiceId: "v", version: "1", files: [installFile("model.onnx", v1, sources: [server.url("/v1")])])
        try await installer.install(voiceId: "v", version: "2", files: [installFile("model.onnx", v2, sources: [server.url("/v2")])])

        XCTAssertEqual(installer.installedVersions(voiceId: "v"), ["2"])
        XCTAssertEqual(try read(root.appendingPathComponent("v/2/model.onnx")), v2)
    }

    func testInstallingTheSameVersionAgainReplacesItAndKeepsItWorkingIfThatFails() async throws {
        let original = payload(30_000, seed: 20)
        let changed = payload(30_000, seed: 21)
        let server = try startServer { request, _ in
            switch request.path {
            case "/original": LocalHTTPServer.file(original, for: request)
            case "/changed": LocalHTTPServer.file(changed, for: request)
            default: .init(status: 404)
            }
        }
        let installer = installer()
        try await installer.install(voiceId: "v", version: "1", files: [installFile("model.onnx", original, sources: [server.url("/original")])])

        do {
            try await installer.install(voiceId: "v", version: "1", files: [installFile("model.onnx", changed, sources: [server.url("/nothing")])])
            XCTFail("no source has the file")
        } catch is VoiceModelInstallError {}
        XCTAssertEqual(try read(root.appendingPathComponent("v/1/model.onnx")), original)

        try await installer.install(voiceId: "v", version: "1", files: [installFile("model.onnx", changed, sources: [server.url("/changed")])])
        XCTAssertEqual(try read(root.appendingPathComponent("v/1/model.onnx")), changed)
        XCTAssertEqual(stagedFolders(), [])
    }

    func testAStalePartialFileGetsOneCleanStartBeforeTheSourceIsBlamed() async throws {
        let model = payload(120_000, seed: 28)
        var staleBytes = model
        for index in 0..<30_000 { staleBytes[index] ^= 0x5A }
        let different = staleBytes
        // The first request is cut after bytes that don't belong to the file the catalog describes.
        let server = try startServer { request, index in
            var reply = LocalHTTPServer.file(index == 0 ? different : model, for: request)
            if index == 0 { reply.cutAfter = 40_000 }
            return reply
        }

        let folder = try await installer().install(voiceId: "v", version: "1", files: [installFile("m.bin", model, sources: [server.url("/m")])])

        XCTAssertEqual(try read(folder.appendingPathComponent("m.bin")), model)
        XCTAssertNil(server.requests(for: "/m").last?.headers["range"], "the retry started from byte zero")
    }

    func testAPartialFromAnEarlierSourceIsContinuedByTheNextOne() async throws {
        let model = payload(200_000, seed: 29)
        let server = try startServer { request, index in
            if request.path == "/down" { return .init(status: 404) }
            var reply = LocalHTTPServer.file(model, for: request)
            if index == 0 { reply.cutAfter = 80_000 }
            return reply
        }
        let files = [installFile("m.bin", model, sources: [server.url("/down"), server.url("/up")])]
        _ = try? await installer(attemptsPerSource: 1).install(voiceId: "v", version: "1", files: files)

        let folder = try await installer().install(voiceId: "v", version: "1", files: files)

        XCTAssertEqual(try read(folder.appendingPathComponent("m.bin")), model)
        XCTAssertNotNil(server.requests(for: "/up").last?.headers["range"], "the first source being down doesn't throw the partial away")
    }

    func testAnInstalledVersionSetAsideByAnInterruptedReinstallComesBack() async throws {
        let original = payload(10_000, seed: 30)
        let server = try fileServer([:])
        // What a reinstall leaves if the app is killed between setting the copy aside and moving the new one in.
        let aside = root.appendingPathComponent(".staging/v@1.replaced-ABC", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try original.write(to: aside.appendingPathComponent("m.bin"))

        _ = try? await installer().install(voiceId: "v", version: "2", files: [installFile("m.bin", original, sources: [server.url("/none")])])

        XCTAssertEqual(try read(root.appendingPathComponent("v/1/m.bin")), original)
        XCTAssertEqual(stagedFolders(), ["v@2"], "only the failed install's own staging folder remains")
    }

    // MARK: Space

    func testRefusesBeforeDownloadingAnythingWhenThereIsNotEnoughRoom() async throws {
        let server = try fileServer([:])
        let installer = installer(marginBytes: 0, availableCapacity: { _ in 90_000_000 })
        let files = [
            VoiceModelInstallFile(path: "a.onnx", byteCount: 100_000_000, sha256: String(repeating: "a", count: 64), sources: [server.url("/a")]),
            VoiceModelInstallFile(path: "b.onnx", byteCount: 60_000_000, sha256: String(repeating: "b", count: 64), sources: [server.url("/b")]),
        ]

        do {
            try await installer.install(voiceId: "v", version: "1", files: files)
            XCTFail("160 MB doesn't fit in 90 MB")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .insufficientSpace(neededBytes: 160_000_000, availableBytes: 90_000_000))
            XCTAssertEqual(error.errorDescription, "This voice needs 160 MB, 90 MB free.")
        }
        XCTAssertEqual(server.requests.count, 0, "not one byte was requested")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "not even a folder was created")
    }

    func testTheMarginCountsAgainstFreeSpaceAndAlreadyStagedBytesDoNot() async throws {
        let model = payload(200_000, seed: 22)
        let server = try startServer { request, index in
            var reply = LocalHTTPServer.file(model, for: request)
            if index == 0 { reply.cutAfter = 120_000 }
            return reply
        }
        let files = [installFile("model.onnx", model, sources: [server.url("/m")])]
        // 100_000 free: too little for 200_000 + margin 50_000, so it refuses.
        do {
            try await installer(marginBytes: 50_000, availableCapacity: { _ in 100_000 }).install(voiceId: "v", version: "1", files: files)
            XCTFail("not enough room")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .insufficientSpace(neededBytes: 250_000, availableBytes: 100_000))
        }
        XCTAssertEqual(server.requests.count, 0)

        // Leave about 120_000 bytes staged, then ask again with room for only the rest plus the margin.
        do {
            try await installer(attemptsPerSource: 1).install(voiceId: "v", version: "1", files: files)
            XCTFail("the first request is cut")
        } catch is VoiceModelInstallError {}
        let folder = try await installer(marginBytes: 50_000, availableCapacity: { _ in 150_000 }).install(voiceId: "v", version: "1", files: files)
        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
    }

    // MARK: Removing

    func testRemoveDeletesOnlyThatVoice() async throws {
        let a = payload(20_000, seed: 23)
        let b = payload(25_000, seed: 24)
        let server = try startServer { request, index in
            if request.path == "/stalled", index == 0 { return .init(status: 500) }
            return LocalHTTPServer.file(request.path == "/a" ? a : b, for: request)
        }
        let installer = installer(attemptsPerSource: 1)
        try await installer.install(voiceId: "alpha", version: "1", files: [installFile("a.bin", a, sources: [server.url("/a")])])
        try await installer.install(voiceId: "beta", version: "1", files: [installFile("b.bin", b, sources: [server.url("/b")])])
        // A third voice that never finished leaves a staged folder.
        _ = try? await installer.install(voiceId: "alpha2", version: "1", files: [installFile("c.bin", b, sources: [server.url("/stalled")])])

        try await installer.remove(voiceId: "alpha")

        XCTAssertFalse(exists("alpha"))
        XCTAssertEqual(try read(root.appendingPathComponent("beta/1/b.bin")), b)
        XCTAssertEqual(installer.installedVersions(voiceId: "alpha"), [])
        XCTAssertNil(installer.installedFolder(voiceId: "alpha", version: "1"))
        XCTAssertEqual(stagedFolders(), ["alpha2@1"], "another voice's staged download is not touched")
    }

    func testRemoveAlsoClearsWhatWasStagedForThatVoice() async throws {
        let model = payload(20_000, seed: 25)
        let server = try startServer { request, index in
            var reply = LocalHTTPServer.file(model, for: request)
            if index == 0 { reply.cutAfter = 5_000 }
            return reply
        }
        _ = try? await installer(attemptsPerSource: 1).install(voiceId: "v", version: "1", files: [installFile("m.bin", model, sources: [server.url("/m")])])
        XCTAssertEqual(stagedFolders(), ["v@1"])

        try await installer().remove(voiceId: "v")

        XCTAssertEqual(stagedFolders(), [])
    }

    // MARK: Unsafe requests

    func testRefusesRequestsThatCouldWriteOutsideTheVoiceFolderOrAreMalformed() async throws {
        let good = installFile("a.bin", payload(10, seed: 1), sources: ["https://example.com/a"])
        func file(_ path: String? = nil, sha: String? = nil, sources: [String]? = nil, byteCount: Int? = nil) -> VoiceModelInstallFile {
            VoiceModelInstallFile(path: path ?? good.path, byteCount: byteCount ?? good.byteCount, sha256: sha ?? good.sha256, sources: sources ?? good.sources)
        }
        let cases: [(voice: String, version: String, files: [VoiceModelInstallFile])] = [
            ("", "1", [good]), ("../x", "1", [good]), (".hidden", "1", [good]), ("a/b", "1", [good]),
            ("v", "", [good]), ("v", "..", [good]), ("v", "1/2", [good]), ("v", String(repeating: "x", count: 65), [good]),
            ("v", "1", []),
            ("v", "1", [file("../escape")]), ("v", "1", [file("/abs/path")]), ("v", "1", [file("a//b")]),
            ("v", "1", [file("a/./b")]), ("v", "1", [file("a/../b")]), ("v", "1", [file("")]),
            ("v", "1", [file("back\\slash")]), ("v", "1", [file("new\nline")]), ("v", "1", [file("model.onnx.partial")]),
            ("v", "1", [good, good]),
            ("v", "1", [file("a"), file("a/b")]),
            ("v", "1", [file(sha: good.sha256.uppercased())]), ("v", "1", [file(sha: String(good.sha256.dropLast()))]),
            ("v", "1", [file(sha: good.sha256 + "0")]), ("v", "1", [file(sha: String(repeating: "g", count: 64))]),
            ("v", "1", [file(sources: [])]), ("v", "1", [file(byteCount: -1)]),
        ]

        for (voice, version, files) in cases {
            do {
                try await installer().install(voiceId: voice, version: version, files: files)
                XCTFail("accepted voice \"\(voice)\" version \"\(version)\" files \(files.map(\.path))")
            } catch let error as VoiceModelInstallError {
                guard case .invalidRequest = error else { XCTFail("wrong error \(error) for \"\(voice)\" \"\(version)\" \(files.map(\.path))"); continue }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "an invalid request creates nothing")
        do {
            try await installer().remove(voiceId: "../v")
            XCTFail("remove accepted a path")
        } catch let error as VoiceModelInstallError {
            guard case .invalidRequest = error else { return XCTFail("wrong error \(error)") }
        }
    }

    // MARK: Cancelling and overlap

    func testCancellingKeepsThePartialDownloadAndOnlyOneInstallRunsPerVoice() async throws {
        let model = payload(300_000, seed: 26)
        let server = try startServer { request, index in
            var reply = LocalHTTPServer.file(model, for: request)
            if index == 0 {
                reply.cutAfter = 100_000
                reply.stallAfterCut = true
            }
            return reply
        }
        let installer = installer()
        let files = [installFile("model.onnx", model, sources: [server.url("/m")])]
        let reachedPartial = expectation(description: "part of the file arrived")
        let log = ProgressLog { $0.bytesDownloaded >= 50_000 ? reachedPartial.fulfill() : () }

        let first = Task { try await installer.install(voiceId: "v", version: "1", files: files) { log.add($0) } }
        await fulfillment(of: [reachedPartial], timeout: 20)

        do {
            try await installer.install(voiceId: "v", version: "2", files: files)
            XCTFail("a second install of the same voice should be refused")
        } catch let error as VoiceModelInstallError {
            XCTAssertEqual(error, .busy(voiceId: "v"))
        }

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("a cancelled install should throw")
        } catch is CancellationError {}

        XCTAssertFalse(exists("v"))
        XCTAssertEqual(stagedFolders(), ["v@1"], "the partial download is kept for a later resume")
        server.stop()
        let folder = try await self.installer().install(voiceId: "v", version: "1", files: [installFile("model.onnx", model, sources: [try fileServer(["/m": model]).url("/m")])])
        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
    }

    // MARK: Files left staged by an earlier attempt

    private func stage(_ relative: String, _ data: Data) throws {
        let url = root.appendingPathComponent(".staging/v@1").appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testAFinishedFileThatNoLongerMatchesItsChecksumIsDownloadedAgain() async throws {
        let model = payload(40_000, seed: 31)
        var damaged = model
        damaged[1_000] ^= 0xFF
        try stage("model.onnx", damaged)
        let server = try fileServer(["/m": model])

        let folder = try await installer().install(voiceId: "v", version: "1", files: [installFile("model.onnx", model, sources: [server.url("/m")])])

        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model, "a staged file of the right size is not trusted without hashing it")
        XCTAssertEqual(server.requests(for: "/m").count, 1)
    }

    func testAFinishedFileThatStillMatchesIsNotDownloadedAgain() async throws {
        let model = payload(40_000, seed: 32)
        try stage("model.onnx", model)
        let server = try fileServer([:])

        let folder = try await installer().install(voiceId: "v", version: "1", files: [installFile("model.onnx", model, sources: [server.url("/m")])])

        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
        XCTAssertEqual(server.requests.count, 0)
    }

    func testAPartialFileAlreadyHoldingEveryByteIsCheckedNotTrusted() async throws {
        let model = payload(40_000, seed: 33)
        let server = try fileServer(["/m": model])

        // Complete and right: checked, then used with no request.
        try stage("model.onnx.partial", model)
        let folder = try await installer().install(voiceId: "v", version: "1", files: [installFile("model.onnx", model, sources: [server.url("/m")])])
        XCTAssertEqual(try read(folder.appendingPathComponent("model.onnx")), model)
        XCTAssertEqual(server.requests.count, 0)

        // Full length but wrong bytes: thrown away and fetched from the start.
        try FileManager.default.removeItem(at: root)
        var damaged = model
        damaged[20_000] ^= 0x01
        try stage("model.onnx.partial", damaged)
        let again = try await installer().install(voiceId: "v", version: "1", files: [installFile("model.onnx", model, sources: [server.url("/m")])])
        XCTAssertEqual(try read(again.appendingPathComponent("model.onnx")), model)
        XCTAssertEqual(server.requests(for: "/m").count, 1)
        XCTAssertNil(server.requests(for: "/m").first?.headers["range"], "the damaged bytes were dropped, so the fetch starts at zero")
    }

    // MARK: Backup

    func testInstalledVoicesAreExcludedFromBackup() async throws {
        #if canImport(Darwin)
        let model = payload(10_000, seed: 27)
        let server = try fileServer(["/m": model])
        let folder = try await installer().install(voiceId: "v", version: "1", files: [installFile("m.bin", model, sources: [server.url("/m")])])

        for url in [root!, root.appendingPathComponent("v"), folder] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, url.lastPathComponent)
        }
        #else
        throw XCTSkip("Backup exclusion is an Apple platform attribute.")
        #endif
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [VoiceModelInstallProgress] = []
    private let onEach: (@Sendable (VoiceModelInstallProgress) -> Void)?

    init(onEach: (@Sendable (VoiceModelInstallProgress) -> Void)? = nil) { self.onEach = onEach }

    func add(_ progress: VoiceModelInstallProgress) {
        lock.lock()
        all.append(progress)
        lock.unlock()
        onEach?(progress)
    }

    var values: [VoiceModelInstallProgress] {
        lock.lock()
        defer { lock.unlock() }
        return all
    }
}

/// Answers every request with `body` and records which addresses were asked for. No network.
private final class RecordingTransport: VoiceModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: Data
    private var urls: [String] = []

    init(serving body: Data) { self.body = body }

    var fetched: [String] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    private func record(_ url: URL) {
        lock.lock()
        urls.append(url.absoluteString)
        lock.unlock()
    }

    func fetch(
        _ url: URL,
        from offset: Int,
        onHead: @escaping @Sendable (VoiceModelResponseHead) throws -> Bool,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        record(url)
        guard try onHead(VoiceModelResponseHead(statusCode: 200)) else { return }
        try onChunk(body)
    }
}

/// The real transport, plus a note of the biggest file under `root` after every piece of body.
private final class SizeWatchingTransport: VoiceModelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let root: @Sendable () -> URL
    private let inner = URLSessionVoiceModelTransport()
    private var largest: Int64 = 0

    init(root: @escaping @Sendable () -> URL) { self.root = root }

    var largestFileSeen: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return largest
    }

    private func measure() {
        guard let files = FileManager.default.enumerator(at: root(), includingPropertiesForKeys: [.fileSizeKey]) else { return }
        var biggest: Int64 = 0
        for case let url as URL in files {
            biggest = max(biggest, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        lock.lock()
        largest = max(largest, biggest)
        lock.unlock()
    }

    func fetch(
        _ url: URL,
        from offset: Int,
        onHead: @escaping @Sendable (VoiceModelResponseHead) throws -> Bool,
        onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        try await inner.fetch(url, from: offset, onHead: onHead) { data in
            defer { self.measure() }
            try onChunk(data)
        }
    }
}
