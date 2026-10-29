#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit

/// The guided tour download (moved to SessionKit with no behaviour change, #318): the manifest and audio come
/// from the product server over a session whose answers a test serves from memory, into a real temporary
/// directory and a ledger over the in-memory repository.
final class GuidedOnboardingCoordinatorTests: XCTestCase {
    private let audio = Data("tour audio bytes".utf8)

    override func setUp() {
        super.setUp()
        GuidedTourServerStub.reset()
    }

    func testAFreshDownloadSavesTheAudioAndTheManifestAndChargesTheLedger() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        GuidedTourServerStub.manifest = try JSONEncoder().encode(manifest())
        GuidedTourServerStub.audio = audio

        let payload = try await fixture.coordinator.refresh()

        XCTAssertEqual(payload.manifest, manifest())
        XCTAssertTrue(payload.audioChanged, "the first download is a change")
        XCTAssertEqual(payload.audioURL.lastPathComponent, "guided-onboarding-3.m4a")
        XCTAssertEqual(try Data(contentsOf: payload.audioURL), audio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "manifest.json").path))
        let inventoryBytes = try await fixture.ledger.inventoryBytes()
        XCTAssertEqual(inventoryBytes, Int64(audio.count))
        XCTAssertTrue(try fixture.repository.loadOfflineStorageReservations().isEmpty, "no reservation is left behind")
    }

    func testARefreshWithTheSameAudioReportsNoChange() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        GuidedTourServerStub.manifest = try JSONEncoder().encode(manifest())
        GuidedTourServerStub.audio = audio
        _ = try await fixture.coordinator.refresh()

        let second = try await fixture.coordinator.refresh()

        XCTAssertFalse(second.audioChanged)
    }

    func testAChecksumMismatchKeepsTheAudioOutAndReleasesTheReservation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        GuidedTourServerStub.manifest = try JSONEncoder().encode(manifest())
        GuidedTourServerStub.audio = Data("tampered audio!!".utf8) // same length as `audio`

        do {
            _ = try await fixture.coordinator.refresh()
            XCTFail("Expected a checksum mismatch")
        } catch let error as GuidedOnboardingError {
            XCTAssertEqual(error.errorDescription, GuidedOnboardingError.checksumMismatch.errorDescription)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appending(path: "guided-onboarding-3.m4a").path))
        XCTAssertTrue(try fixture.repository.loadOfflineStorageReservations().isEmpty)
        let inventoryBytes = try await fixture.ledger.inventoryBytes()
        XCTAssertEqual(inventoryBytes, 0)
    }

    func testAnAnswerThatIsNotTheDeclaredLengthIsRefused() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        GuidedTourServerStub.manifest = try JSONEncoder().encode(manifest())
        GuidedTourServerStub.audio = audio
        GuidedTourServerStub.declaredAudioLength = Int64(audio.count) + 1

        do {
            _ = try await fixture.coordinator.refresh()
            XCTFail("Expected the short audio to be refused")
        } catch {
            XCTAssertNotNil(error as? GuidedOnboardingError)
        }
        XCTAssertTrue(try fixture.repository.loadOfflineStorageReservations().isEmpty)
    }

    func testAnAudioFileOverTheCapIsRefusedBeforeItIsDownloaded() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        GuidedTourServerStub.manifest = try JSONEncoder().encode(manifest())
        GuidedTourServerStub.audio = audio
        GuidedTourServerStub.declaredAudioLength = 64 * 1_024 * 1_024 + 1

        do {
            _ = try await fixture.coordinator.refresh()
            XCTFail("Expected an oversized audio error")
        } catch let error as GuidedOnboardingError {
            XCTAssertEqual(error.errorDescription, GuidedOnboardingError.oversizedAudio.errorDescription)
        }
        XCTAssertEqual(GuidedTourServerStub.audioGets, 0, "the HEAD answer alone ruled it out")
    }

    func testAManifestOverTheCapIsRefused() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        GuidedTourServerStub.manifest = Data(repeating: 0x20, count: 128 * 1_024 + 1)

        do {
            _ = try await fixture.coordinator.refresh()
            XCTFail("Expected an oversized manifest error")
        } catch let error as GuidedOnboardingError {
            XCTAssertEqual(error.errorDescription, GuidedOnboardingError.oversizedManifest.errorDescription)
        }
    }

    func testAManifestWithRepeatedActionIdsOrABadChecksumIsInvalid() async throws {
        let action = OnboardingAction(id: "one", title: "One", route: .addPDF)
        let repeated = manifest(actions: [action, action])
        let shortChecksum = manifest(checksum: "abc123")
        let wrongSchema = manifest(schemaVersion: "guided-onboarding.v2")
        let wrongItem = manifest(itemId: "something-else")
        for bad in [repeated, shortChecksum, wrongSchema, wrongItem] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            GuidedTourServerStub.reset()
            GuidedTourServerStub.manifest = try JSONEncoder().encode(bad)
            GuidedTourServerStub.audio = audio
            do {
                _ = try await fixture.coordinator.refresh()
                XCTFail("Expected an invalid manifest for \(bad)")
            } catch let error as GuidedOnboardingError {
                XCTAssertEqual(error.errorDescription, GuidedOnboardingError.invalidManifest.errorDescription)
            }
            XCTAssertEqual(GuidedTourServerStub.audioGets, 0, "no audio is fetched for a manifest that fails validation")
        }
    }

    func testAnEndpointOffTheProductServerIsNotAskedAnything() async throws {
        let fixture = try makeFixture(manifestURL: URL(string: "https://elsewhere.example/onboarding/v1/manifest.json")!)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try await fixture.coordinator.refresh()
            XCTFail("Expected an untrusted endpoint")
        } catch let error as GuidedOnboardingError {
            XCTAssertEqual(error.errorDescription, GuidedOnboardingError.invalidEndpoint.errorDescription)
        }
        XCTAssertEqual(GuidedTourServerStub.requests, 0)
    }

    func testAManifestNamingAnInsecureAudioAddressIsRefused() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        GuidedTourServerStub.manifest = try JSONEncoder().encode(manifest(audioURL: "http://\(ProductServer.host)/tour.m4a"))
        GuidedTourServerStub.audio = audio

        do {
            _ = try await fixture.coordinator.refresh()
            XCTFail("Expected an untrusted audio address")
        } catch let error as GuidedOnboardingError {
            XCTAssertEqual(error.errorDescription, GuidedOnboardingError.invalidEndpoint.errorDescription)
        }
        XCTAssertEqual(GuidedTourServerStub.audioGets, 0)
    }

    func testWithTheServerDownTheLastGoodTourPlaysFromTheSavedCopy() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        GuidedTourServerStub.manifest = try JSONEncoder().encode(manifest())
        GuidedTourServerStub.audio = audio
        _ = try await fixture.coordinator.refresh()
        GuidedTourServerStub.failEverything = true

        let offline = try await fixture.coordinator.refresh()

        XCTAssertEqual(offline.manifest, manifest())
        XCTAssertFalse(offline.audioChanged)
        XCTAssertEqual(try Data(contentsOf: offline.audioURL), audio)
    }

    func testWithTheServerDownAndNothingSavedTheFailureIsThrown() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        GuidedTourServerStub.failEverything = true

        do {
            _ = try await fixture.coordinator.refresh()
            XCTFail("Expected the network failure")
        } catch {
            XCTAssertNil(error as? GuidedOnboardingError, "the network's own error, not a validation one")
        }
    }

    func testASavedAudioFileThatNoLongerMatchesItsChecksumIsNotPlayed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        GuidedTourServerStub.manifest = try JSONEncoder().encode(manifest())
        GuidedTourServerStub.audio = audio
        let payload = try await fixture.coordinator.refresh()
        try Data("damaged".utf8).write(to: payload.audioURL)
        GuidedTourServerStub.failEverything = true

        do {
            _ = try await fixture.coordinator.refresh()
            XCTFail("Expected the damaged copy to be refused")
        } catch {
            // The cached copy is refused, so the original network failure is what surfaces.
        }
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let directory: URL
        let repository: InMemorySessionRepository
        let ledger: OfflineStorageLedger
        let coordinator: GuidedOnboardingCoordinator
    }

    private func makeFixture(manifestURL: URL = GuidedOnboardingCoordinator.productionManifestURL) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "guided-onboarding-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = InMemorySessionRepository()
        try repository.saveOfflineStorageBudget(OfflineStorageBudget(limitBytes: 10 * 1_024 * 1_024))
        let ledger = OfflineStorageLedger(repository: repository, rootDirectory: root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuidedTourServerStub.self]
        let directory = root.appending(path: "GuidedOnboarding", directoryHint: .isDirectory)
        return Fixture(
            root: root, directory: directory, repository: repository, ledger: ledger,
            coordinator: GuidedOnboardingCoordinator(
                manifestURL: manifestURL, session: URLSession(configuration: configuration),
                directory: directory, ledger: ledger
            )
        )
    }

    private func manifest(
        schemaVersion: String = "guided-onboarding.v1", itemId: String = "guided-onboarding",
        audioURL: String? = nil, checksum: String? = nil, actions: [OnboardingAction]? = nil
    ) -> GuidedOnboardingManifest {
        GuidedOnboardingManifest(
            schemaVersion: schemaVersion, itemId: itemId, contentVersion: 3, title: "Welcome",
            description: "A short tour.",
            audioURL: audioURL ?? "https://\(ProductServer.host)/onboarding/v1/tour.m4a",
            audioChecksumSHA256: checksum ?? SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined(),
            actions: actions ?? [OnboardingAction(id: "pdf", title: "Add a PDF", route: .addPDF)]
        )
    }
}

/// The product server for these tests: the manifest at `/onboarding/v1/manifest.json`, everything else is
/// the tour audio. Static state, since a session builds its protocol instances itself; XCTest runs these
/// tests one at a time.
private final class GuidedTourServerStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var manifest = Data()
    nonisolated(unsafe) static var audio = Data()
    nonisolated(unsafe) static var declaredAudioLength: Int64?
    nonisolated(unsafe) static var failEverything = false
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var audioGets = 0

    static func reset() {
        manifest = Data()
        audio = Data()
        declaredAudioLength = nil
        failEverything = false
        requests = 0
        audioGets = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        guard !Self.failEverything, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let isHead = request.httpMethod == "HEAD"
        let isManifest = url.path.hasSuffix("manifest.json")
        let body = isManifest ? Self.manifest : Self.audio
        if !isManifest && !isHead { Self.audioGets += 1 }
        var headers = ["Content-Type": isManifest ? "application/json" : "audio/mp4"]
        headers["Content-Length"] = String(isManifest ? body.count : Int(Self.declaredAudioLength ?? Int64(body.count)))
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !isHead { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
