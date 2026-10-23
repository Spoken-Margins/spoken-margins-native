#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// #1816: the voice catalog is trusted only when its signature, key and version check out, and an
/// entry that breaks a rule is left out instead of installed. Fixtures live in
/// Contracts/fixtures/voice-model-catalog/ (scripts/voice_catalog_tools.py makes them).
final class VoiceModelCatalogTests: XCTestCase {
    private static let folder = "fixtures/voice-model-catalog"

    private struct TestKeys: Decodable {
        struct Key: Decodable { var keyId: String; var publicKey: String }
        var trusted: Key
        var untrusted: Key
    }

    private func fixture(_ name: String) throws -> Data {
        try TestInputs.data(.contracts, "\(Self.folder)/\(name)")
    }

    private func trustedKeys(includingOther: Bool = false) throws -> [VoiceCatalogTrustedKey] {
        let keys = try JSONDecoder().decode(TestKeys.self, from: fixture("test-keys.json"))
        var result = [VoiceCatalogTrustedKey(keyId: keys.trusted.keyId, publicKey: try XCTUnwrap(Data(base64Encoded: keys.trusted.publicKey)))]
        if includingOther {
            result.append(VoiceCatalogTrustedKey(keyId: keys.untrusted.keyId, publicKey: try XCTUnwrap(Data(base64Encoded: keys.untrusted.publicKey))))
        }
        return result
    }

    /// The private half of the test key, derived the way scripts/voice_catalog_tools.py derives it, so a
    /// test can sign a catalog it built. It signs nothing real.
    private func fixtureSigningKey() throws -> Curve25519.Signing.PrivateKey {
        let seed = Data(SHA256.hash(data: Data("spoken-margins voice-model-catalog test key".utf8)))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    private func signedEnvelope(_ payload: Data, keyId: String = "sm-test-1", context: Data = VoiceModelCatalogVerifier.signingContext) throws -> Data {
        let signature = try fixtureSigningKey().signature(for: context + payload)
        let envelope = VoiceModelCatalogEnvelope(keyId: keyId, payload: payload.base64EncodedString(), signature: Data(signature).base64EncodedString())
        return try JSONEncoder().encode(envelope)
    }

    private func verify(_ fixtureName: String, last: Int? = nil, keys: [VoiceCatalogTrustedKey]? = nil) throws -> VerifiedVoiceModelCatalog {
        try verify(envelope: fixture(fixtureName), last: last, keys: keys)
    }

    private func verify(envelope: Data, last: Int? = nil, keys: [VoiceCatalogTrustedKey]? = nil) throws -> VerifiedVoiceModelCatalog {
        try VoiceModelCatalogVerifier.verify(
            envelopeData: envelope,
            trustedKeys: keys ?? trustedKeys(),
            lastAcceptedCatalogVersion: last
        )
    }

    private func assertVerifyThrows(_ expected: VoiceCatalogError, _ data: Data, last: Int? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let keys = try trustedKeys()
        XCTAssertThrowsError(try VoiceModelCatalogVerifier.verify(envelopeData: data, trustedKeys: keys, lastAcceptedCatalogVersion: last), file: file, line: line) {
            XCTAssertEqual($0 as? VoiceCatalogError, expected, file: file, line: line)
        }
    }

    // MARK: Fixtures

    func testTheTestKeyInTheFixturesIsTheOneThePythonToolSigns() throws {
        let published = try trustedKeys()[0].publicKey
        XCTAssertEqual(try fixtureSigningKey().publicKey.rawRepresentation, published)
    }

    func testEveryFixtureDecodes() throws {
        let folder = try TestInputs.url(.contracts, Self.folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        var decoded = 0
        for name in names where name.hasPrefix("catalog-") || name.hasSuffix(".catalog.json") {
            XCTAssertNoThrow(try VoiceModelCatalog.decode(fixture(name)), name)
            decoded += 1
        }
        for name in names where name.hasPrefix("envelope-") {
            XCTAssertNoThrow(try JSONDecoder().decode(VoiceModelCatalogEnvelope.self, from: fixture(name)), name)
            decoded += 1
        }
        XCTAssertGreaterThanOrEqual(decoded, 12, "fixtures went missing")
    }

    // MARK: The whole catalog

    func testValidCatalogVerifiesAndShowsWhatTheListenerMustAgreeTo() throws {
        let catalog = try verify("envelope-valid.json")
        XCTAssertEqual(catalog.catalogVersion, 3)
        XCTAssertEqual(catalog.keyId, "sm-test-1")
        XCTAssertEqual(catalog.voices.map(\.id), ["fixture-bundled", "fixture-voice"])
        XCTAssertEqual(catalog.rejected, [])
        XCTAssertEqual(catalog.available.count, 2)

        let bundled = try XCTUnwrap(catalog.voice(id: "fixture-bundled"))
        XCTAssertTrue(bundled.bundled)
        XCTAssertEqual(bundled.downloadByteCount, 0)
        XCTAssertEqual(bundled.licenses.first?.spdxId, "Apache-2.0")
        XCTAssertTrue(bundled.licensesRequiringAcceptance.isEmpty)

        let downloadable = try XCTUnwrap(catalog.voice(id: "fixture-voice"))
        XCTAssertEqual(downloadable.files.map(\.path), ["model.onnx", "styles/a.json"])
        XCTAssertEqual(downloadable.downloadByteCount, downloadable.files.map(\.byteCount).reduce(0, +))
        XCTAssertEqual(downloadable.files[0].sources.count, 2, "upstream first, then the mirror")
        XCTAssertEqual(downloadable.licensesRequiringAcceptance.map(\.id), ["fixture-rail"])
        XCTAssertFalse(downloadable.licensesRequiringAcceptance[0].restrictionsSummary?.isEmpty ?? true)
    }

    func testPayloadEditedAfterSigningIsRejected() throws {
        try assertVerifyThrows(.badSignature, fixture("envelope-bad-signature.json"))
    }

    func testSignatureFromAKeyTheBuildDoesNotTrustIsRejected() throws {
        try assertVerifyThrows(.unknownKey("sm-unknown-key"), fixture("envelope-unknown-key.json"))
    }

    func testRotationTrustsEitherKeyWhileBothAreCompiledIn() throws {
        let catalog = try verify("envelope-unknown-key.json", keys: trustedKeys(includingOther: true))
        XCTAssertEqual(catalog.keyId, "sm-unknown-key")
        XCTAssertEqual(try verify("envelope-valid.json", keys: trustedKeys(includingOther: true)).keyId, "sm-test-1")
    }

    func testKnownKeyIdWithTheWrongKeysSignatureIsRejected() throws {
        // The unknown-key fixture's bytes, relabelled with the trusted key's id.
        var envelope = try JSONDecoder().decode(VoiceModelCatalogEnvelope.self, from: fixture("envelope-unknown-key.json"))
        envelope.keyId = "sm-test-1"
        try assertVerifyThrows(.badSignature, JSONEncoder().encode(envelope))
    }

    func testProductionKeyListDoesNotTrustTheTestKey() throws {
        let envelope = try fixture("envelope-valid.json")
        XCTAssertThrowsError(try VoiceModelCatalogVerifier.verify(envelopeData: envelope, trustedKeys: VoiceCatalogTrust.production)) {
            XCTAssertEqual($0 as? VoiceCatalogError, .unknownKey("sm-test-1"))
        }
        XCTAssertEqual(VoiceCatalogTrust.production.map(\.keyId), ["sm-voices-1"])
        XCTAssertTrue(VoiceCatalogTrust.production.allSatisfy { $0.publicKey.count == 32 })
    }

    func testOlderCatalogThanTheLastAcceptedIsARollback() throws {
        let rollback = try fixture("envelope-rollback.json")
        let valid = try fixture("envelope-valid.json")
        let withdrawn = try fixture("envelope-withdrawn.json")
        let keys = try trustedKeys()
        XCTAssertThrowsError(try verify(envelope: rollback, last: 3, keys: keys)) {
            XCTAssertEqual($0 as? VoiceCatalogError, .rollback(lastAccepted: 3, offered: 1))
        }
        XCTAssertEqual(try verify(envelope: rollback, last: nil, keys: keys).catalogVersion, 1)
        XCTAssertEqual(try verify(envelope: rollback, last: 1, keys: keys).catalogVersion, 1)
        XCTAssertEqual(try verify(envelope: valid, last: 3, keys: keys).catalogVersion, 3, "the same version again is a refresh, not a rollback")
        XCTAssertEqual(try verify(envelope: withdrawn, last: 3, keys: keys).catalogVersion, 4)
    }

    func testEnvelopeShapesTheSchemaRejectAreRejectedHere() throws {
        try assertVerifyThrows(.malformedEnvelope, fixture("../invalid/voice-model-catalog/envelope-missing-signature.json"))
        try assertVerifyThrows(.unsupportedAlgorithm("rsa"), fixture("../invalid/voice-model-catalog/envelope-wrong-algorithm.json"))
        try assertVerifyThrows(.badSignature, fixture("../invalid/voice-model-catalog/envelope-short-signature.json"))
        try assertVerifyThrows(.malformedEnvelope, Data("not json".utf8))
        try assertVerifyThrows(.malformedEnvelope, Data())
        try assertVerifyThrows(.oversized, Data(repeating: 0x20, count: VoiceModelCatalogVerifier.maximumEnvelopeBytes + 1))

        var envelope = try JSONDecoder().decode(VoiceModelCatalogEnvelope.self, from: fixture("envelope-valid.json"))
        envelope.schemaVersion = "voice-model-catalog-envelope.v2"
        try assertVerifyThrows(.unsupportedEnvelopeVersion("voice-model-catalog-envelope.v2"), JSONEncoder().encode(envelope))
    }

    func testSignatureOverAnotherContextIsRejected() throws {
        let payload = try fixture("catalog-valid.json")
        try assertVerifyThrows(.badSignature, signedEnvelope(payload, context: Data("something else\n".utf8)))
        let envelope = try signedEnvelope(payload)
        let keys = try trustedKeys()
        XCTAssertNoThrow(try VoiceModelCatalogVerifier.verify(envelopeData: envelope, trustedKeys: keys))
    }

    func testSignedButBrokenPayloadsAreRejectedWhole() throws {
        let valid = try fixture("catalog-valid.json")
        func rewritten(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            edit(&object)
            return try JSONSerialization.data(withJSONObject: object)
        }
        try assertVerifyThrows(.malformedPayload, signedEnvelope(Data("{".utf8)))
        try assertVerifyThrows(.malformedPayload, signedEnvelope(rewritten { $0["voices"] = nil }))
        try assertVerifyThrows(.unsupportedSchemaVersion("voice-model-catalog.v2"), signedEnvelope(rewritten { $0["schemaVersion"] = "voice-model-catalog.v2" }))
        try assertVerifyThrows(.invalidCatalogVersion, signedEnvelope(rewritten { $0["catalogVersion"] = 0 }))
        try assertVerifyThrows(.invalidIssuedAt, signedEnvelope(rewritten { $0["issuedAt"] = "yesterday" }))
        try assertVerifyThrows(.invalidIssuedAt, signedEnvelope(rewritten { $0["issuedAt"] = "2026-10-17" }))
        try assertVerifyThrows(.duplicateVoiceID("fixture-voice"), signedEnvelope(rewritten {
            let voices = $0["voices"] as? [[String: Any]] ?? []
            $0["voices"] = voices + [voices[1]]
        }))
    }

    // MARK: One entry

    func testWithdrawnAndSupersededVoicesStayVisibleButAreNotAvailable() throws {
        let catalog = try verify("envelope-withdrawn.json")
        XCTAssertEqual(catalog.voices.map(\.id), ["fixture-bundled", "fixture-voice", "fixture-voice-old", "fixture-voice-older"])
        XCTAssertEqual(catalog.voice(id: "fixture-voice-old")?.status, .withdrawn)
        XCTAssertEqual(catalog.voice(id: "fixture-voice-older")?.status, .superseded)
        XCTAssertEqual(catalog.voice(id: "fixture-voice-older")?.supersededBy, "fixture-voice")
        XCTAssertEqual(catalog.available.map(\.id), ["fixture-bundled", "fixture-voice"])
        XCTAssertEqual(catalog.rejected, [])
    }

    func testVoiceForARuntimeThisBuildCannotRunIsLeftOutAndTheRestStay() throws {
        let catalog = try verify("envelope-unknown-runtime.json")
        XCTAssertEqual(catalog.voices.map(\.id), ["fixture-bundled", "fixture-voice"])
        XCTAssertEqual(catalog.rejected, [RejectedVoiceEntry(id: "fixture-future-runtime", reason: .unknownRuntime("coreml"))])
    }

    func testEntryThatCannotBeReadIsLeftOutAndTheRestStay() throws {
        let payload = try fixture("catalog-valid.json")
        let keys = try trustedKeys()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        var voices = try XCTUnwrap(object["voices"] as? [[String: Any]])
        var broken = voices[1]
        broken["id"] = "fixture-broken"
        broken["files"] = nil
        var wrongType = voices[1]
        wrongType["id"] = "fixture-wrong-type"
        wrongType["status"] = "retired"
        voices += [broken, wrongType, ["displayName": "no id at all"]]
        object["voices"] = voices
        let envelope = try signedEnvelope(JSONSerialization.data(withJSONObject: object))
        let catalog = try VoiceModelCatalogVerifier.verify(envelopeData: envelope, trustedKeys: keys)
        XCTAssertEqual(catalog.voices.map(\.id), ["fixture-bundled", "fixture-voice"])
        XCTAssertEqual(catalog.rejected, [
            RejectedVoiceEntry(id: "fixture-broken", reason: .malformed),
            RejectedVoiceEntry(id: "fixture-wrong-type", reason: .malformed),
            RejectedVoiceEntry(id: nil, reason: .malformed),
        ])
    }

    func testEachRuleLeavesOutOnlyTheEntryThatBreaksIt() throws {
        let valid = try VoiceModelCatalog.decode(fixture("catalog-valid.json"))
        let downloadable = try XCTUnwrap(valid.voices.first { $0.id == "fixture-voice" })
        let cases: [(String, (inout VoiceModelEntry) -> Void, VoiceEntryRejection)] = [
            ("http source", { $0.files[0].sources = ["http://models.example.org/model.onnx"] }, .insecureSource(path: "model.onnx")),
            ("second source is http", { $0.files[0].sources.append("http://mirror.example.net/model.onnx") }, .insecureSource(path: "model.onnx")),
            ("source with trailing space", { $0.files[0].sources = ["https://models.example.org/model.onnx "] }, .insecureSource(path: "model.onnx")),
            ("source with credentials", { $0.files[0].sources = ["https://user@models.example.org/model.onnx"] }, .insecureSource(path: "model.onnx")),
            ("empty source", { $0.files[0].sources = [""] }, .insecureSource(path: "model.onnx")),
            ("no sources", { $0.files[0].sources = [] }, .emptySources(path: "model.onnx")),
            ("uppercase hash", { $0.files[0].sha256 = $0.files[0].sha256.uppercased() }, .invalidHash(path: "model.onnx")),
            ("63-character hash", { $0.files[0].sha256 = String($0.files[0].sha256.dropLast()) }, .invalidHash(path: "model.onnx")),
            ("empty hash", { $0.files[0].sha256 = "" }, .invalidHash(path: "model.onnx")),
            ("hash with trailing newline", { $0.files[0].sha256 += "\n" }, .invalidHash(path: "model.onnx")),
            ("licence text hash malformed", { $0.licenses[0].textSHA256 = "abc" }, .invalidHash(path: "licenses.fixture-rail.textSHA256")),
            ("licence text over http", { $0.licenses[0].textURL = "http://models.example.org/LICENSE" }, .insecureSource(path: "licenses.fixture-rail.textURL")),
            ("origin over http", { $0.files[0].origin = VoiceModelFileOrigin(url: "http://models.example.org/archive.tar.bz2") }, .insecureSource(path: "model.onnx.origin")),
            ("zero bytes", { $0.files[0].byteCount = 0 }, .invalidField("files.model.onnx.byteCount")),
            ("path climbs out", { $0.files[0].path = "../model.onnx" }, .invalidField("files.path")),
            ("duplicate path", { $0.files[1].path = $0.files[0].path }, .duplicatePath("model.onnx")),
            ("paths differing only by case", { $0.files[1].path = "Model.onnx" }, .duplicatePath("Model.onnx")),
            ("a file that is also a folder", { $0.files[1].path = "model.onnx/extra.json" }, .duplicatePath("model.onnx")),
            ("path with a colon", { $0.files[0].path = "a:b" }, .invalidField("files.path")),
            ("superseded by itself", { $0.status = .superseded; $0.supersededBy = $0.id }, .supersededWithoutSuccessor),
            ("successor that is not an id", { $0.supersededBy = "NOT AN ID" }, .invalidField("supersededBy")),
            ("source URL over 2,048 characters", { $0.files[0].sources = ["https://models.example.org/" + String(repeating: "a", count: 2_048)] }, .insecureSource(path: "model.onnx")),
            ("too many sources", { $0.files[0].sources = (0..<9).map { "https://models.example.org/\($0)/model.onnx" } }, .invalidField("files.model.onnx.sources")),
            ("too many files", { voice in voice.files = (0..<257).map { VoiceModelFile(path: "f\($0).bin", byteCount: 1, sha256: String(repeating: "a", count: 64), sources: ["https://models.example.org/f"]) } }, .invalidField("files")),
            ("summary over 1,500 characters", { $0.licenses[0].restrictionsSummary = String(repeating: "x", count: 1_501) }, .invalidField("licenses.restrictionsSummary")),
            ("SPDX id with a space", { $0.licenses[0].spdxId = "Apache 2.0" }, .invalidField("licenses.spdxId")),
            ("runtime name that is not a name", { $0.runtime.name = "ONNX Runtime" }, .invalidField("runtime.name")),
            ("file names a licence the voice lacks", { $0.files[0].licenseId = "nope" }, .unknownLicense("nope")),
            ("acceptance with no summary", { $0.licenses[0].restrictionsSummary = "  " }, .acceptanceWithoutSummary(licenseId: "fixture-rail")),
            ("superseded by nothing", { $0.status = .superseded; $0.supersededBy = nil }, .supersededWithoutSuccessor),
            ("downloadable with no files", { $0.files = [] }, .noFiles),
            ("no licence at all", { $0.licenses = []; $0.files[0].licenseId = nil; $0.files[1].licenseId = nil }, .invalidField("licenses")),
            ("bad id", { $0.id = "Fixture Voice" }, .invalidField("id")),
            ("zero memory", { $0.minimumMemoryMegabytes = 0 }, .invalidField("minimumMemoryMegabytes")),
            ("bad iOS version", { $0.minimumIOSVersion = "26.x" }, .invalidField("minimumIOSVersion")),
            ("blank name", { $0.displayName = " " }, .invalidField("displayName")),
            ("other runtime", { $0.runtime.name = "tflite" }, .unknownRuntime("tflite")),
        ]
        for (label, edit, expected) in cases {
            var broken = downloadable
            edit(&broken)
            var catalog = valid
            catalog.voices = [valid.voices[0], broken]
            let screened = try VoiceModelCatalogVerifier.screen(catalog)
            XCTAssertEqual(screened.voices.map(\.id), ["fixture-bundled"], label)
            XCTAssertEqual(screened.rejected, [RejectedVoiceEntry(id: broken.id, reason: expected)], label)
        }
    }

    // MARK: Archives and carried content (#2086)

    func testVoiceWithAnArchiveMemberAndCarriedContentVerifies() throws {
        let catalog = try verify("envelope-archive.json")
        XCTAssertEqual(catalog.rejected, [])
        let voice = try XCTUnwrap(catalog.voice(id: "fixture-archive-voice"))
        XCTAssertEqual(voice.archives.map(\.id), ["int8"])
        let graph = try XCTUnwrap(voice.files.first { $0.path == "onnx/model.onnx" })
        XCTAssertEqual(graph.archiveMember, VoiceModelArchiveMember(archive: "int8", member: "fixture-int8-1.0/model.int8.onnx"))
        XCTAssertEqual(graph.sources, [])
        let notice = try XCTUnwrap(voice.files.first { $0.path == "onnx/MODIFIED.txt" })
        XCTAssertEqual(notice.content.map { Data($0.utf8).count }, notice.byteCount)
        // What downloads is the archive and the style file; the member and the notice come from them.
        let style = try XCTUnwrap(voice.files.first { $0.path == "styles/a.json" })
        XCTAssertEqual(voice.downloadByteCount, voice.archives[0].byteCount + style.byteCount)
        XCTAssertEqual(voice.installedByteCount, voice.files.map(\.byteCount).reduce(0, +))
        // The installer gets one archive and each file from its one place.
        XCTAssertEqual(voice.installArchives.map(\.id), ["int8"])
        XCTAssertEqual(voice.installFiles.map { $0.archiveMember != nil }, [true, false, false])
        XCTAssertEqual(voice.installFiles[1].content, Data(try XCTUnwrap(notice.content).utf8))
    }

    func testCatalogsWithoutArchivesStillReadTheSameAndRoundTrip() throws {
        let valid = try VoiceModelCatalog.decode(fixture("catalog-valid.json"))
        let voice = try XCTUnwrap(valid.voices.first { $0.id == "fixture-voice" })
        XCTAssertEqual(voice.archives, [])
        XCTAssertEqual(voice.downloadByteCount, voice.installedByteCount)
        // Encoding writes no archive or member fields the older shape lacks.
        let encoded = try JSONEncoder().encode(voice)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["archives"])
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        XCTAssertTrue(files.allSatisfy { $0["sources"] != nil && $0["archiveMember"] == nil && $0["content"] == nil })
        XCTAssertEqual(try JSONDecoder().decode(VoiceModelEntry.self, from: encoded), voice)
        let archiveCatalog = try VoiceModelCatalog.decode(fixture("catalog-archive.json"))
        let archiveVoice = try XCTUnwrap(archiveCatalog.voices.last)
        XCTAssertEqual(try JSONDecoder().decode(VoiceModelEntry.self, from: JSONEncoder().encode(archiveVoice)), archiveVoice)
    }

    func testEachArchiveRuleLeavesOutOnlyTheEntryThatBreaksIt() throws {
        let catalog = try VoiceModelCatalog.decode(fixture("catalog-archive.json"))
        let voice = try XCTUnwrap(catalog.voices.first { $0.id == "fixture-archive-voice" })
        XCTAssertNil(VoiceModelCatalogVerifier.rejection(for: voice))
        let cases: [(String, (inout VoiceModelEntry) -> Void, VoiceEntryRejection)] = [
            ("member of an archive the voice lacks", { $0.files[0].archiveMember?.archive = "fp32" }, .unknownArchive("fp32")),
            ("archive in a format this build can't open", { $0.archives[0].format = "tar.zst" }, .unsupportedArchiveFormat("tar.zst")),
            ("member with sources too", { $0.files[0].sources = ["https://models.example.org/model.onnx"] }, .ambiguousFileSource(path: "onnx/model.onnx")),
            ("content with sources too", { $0.files[1].sources = ["https://models.example.org/MODIFIED.txt"] }, .ambiguousFileSource(path: "onnx/MODIFIED.txt")),
            ("member and content", { $0.files[0].content = "x" }, .ambiguousFileSource(path: "onnx/model.onnx")),
            ("content whose hash is wrong", { $0.files[1].content = String(repeating: "x", count: $0.files[1].byteCount) }, .invalidHash(path: "onnx/MODIFIED.txt")),
            ("content whose size is wrong", { $0.files[1].byteCount += 1 }, .invalidField("files.onnx/MODIFIED.txt.content")),
            ("member path climbs out", { $0.files[0].archiveMember?.member = "../model.onnx" }, .invalidField("files.onnx/model.onnx.archiveMember.member")),
            ("one member for two files", { $0.files.append(VoiceModelFile(path: "onnx/copy.onnx", byteCount: $0.files[0].byteCount, sha256: $0.files[0].sha256, sources: [], archiveMember: $0.files[0].archiveMember)) }, .invalidField("files.onnx/copy.onnx.archiveMember")),
            ("archive over http", { $0.archives[0].sources = ["http://github.example.com/a.tar.bz2"] }, .insecureSource(path: "archives.int8")),
            ("archive with no sources", { $0.archives[0].sources = [] }, .emptySources(path: "archives.int8")),
            ("archive hash malformed", { $0.archives[0].sha256 = "abc" }, .invalidHash(path: "archives.int8")),
            ("archive of zero bytes", { $0.archives[0].byteCount = 0 }, .invalidField("archives.int8.byteCount")),
            ("two archives with one id", { $0.archives.append($0.archives[0]) }, .invalidField("archives.id")),
        ]
        for (label, edit, expected) in cases {
            var broken = voice
            edit(&broken)
            XCTAssertEqual(VoiceModelCatalogVerifier.rejection(for: broken), expected, label)
        }
    }

    func testCatalogWithMoreThanTheMaximumVoicesIsRejected() throws {
        let valid = try VoiceModelCatalog.decode(fixture("catalog-valid.json"))
        var catalog = valid
        catalog.voices = (0...VoiceModelCatalogRules.maximumVoices).map { index in
            var voice = valid.voices[1]
            voice.id = "voice-\(index)"
            return voice
        }
        XCTAssertThrowsError(try VoiceModelCatalogVerifier.screen(catalog)) {
            XCTAssertEqual($0 as? VoiceCatalogError, .malformedPayload)
        }
    }

    func testBundledVoiceNeedsNoFilesButStillNeedsItsLicence() throws {
        let valid = try VoiceModelCatalog.decode(fixture("catalog-valid.json"))
        var bundled = try XCTUnwrap(valid.voices.first { $0.bundled })
        XCTAssertNil(VoiceModelCatalogVerifier.rejection(for: bundled))
        bundled.licenses = []
        XCTAssertEqual(VoiceModelCatalogVerifier.rejection(for: bundled), .invalidField("licenses"))
    }

    // MARK: Neighbouring inputs

    func testFieldRulesAgreeWithTheNeighbouringInputTable() throws {
        struct Row: Decodable { var value: String; var valid: Bool; var why: String }
        struct Table: Decodable { var sha256: [Row]; var httpsURL: [Row]; var filePath: [Row]; var id: [Row]; var spdxId: [Row]; var runtimeName: [Row] }
        let table = try JSONDecoder().decode(Table.self, from: fixture("neighbour-inputs.json"))
        let rules: [(String, [Row], (String) -> Bool)] = [
            ("sha256", table.sha256, VoiceModelCatalogRules.isLowercaseSHA256),
            ("httpsURL", table.httpsURL, VoiceModelCatalogRules.isHTTPSURL),
            ("filePath", table.filePath, VoiceModelCatalogRules.isRelativeFilePath),
            ("id", table.id, VoiceModelCatalogRules.isVoiceID),
            ("spdxId", table.spdxId, VoiceModelCatalogRules.isSPDXId),
            ("runtimeName", table.runtimeName, VoiceModelCatalogRules.isRuntimeName),
        ]
        for (name, rows, rule) in rules {
            XCTAssertGreaterThanOrEqual(rows.count, 6, name)
            for row in rows {
                XCTAssertEqual(rule(row.value), row.valid, "\(name): \(row.why): \(row.value.debugDescription)")
            }
        }
    }

    // MARK: The Supertonic draft

    func testSupertonicDraftPassesEveryRuleThatSigningWillEnforce() throws {
        let draft = try VoiceModelCatalog.decode(fixture("draft-supertonic.catalog.json"))
        let screened = try VoiceModelCatalogVerifier.screen(draft)
        XCTAssertEqual(screened.rejected, [])
        let voice = try XCTUnwrap(screened.voice(id: "supertonic-3-int8"))
        XCTAssertEqual(voice.status, .available)
        XCTAssertFalse(voice.bundled)
        XCTAssertEqual(voice.runtime, VoiceModelRuntime(name: "onnxruntime", version: "1.24.2"))

        // Weights need the listener's agreement to the Open RAIL-M use restrictions first.
        let rail = try XCTUnwrap(voice.licenses.first { $0.id == "supertonic-model-openrail-m" })
        XCTAssertTrue(rail.requiresAcceptance)
        XCTAssertNil(rail.spdxId)
        let weights = try XCTUnwrap(voice.files.first { $0.path == "onnx/vector_estimator.onnx" })
        XCTAssertEqual(weights.licenseId, "supertonic-model-openrail-m")
        XCTAssertEqual(weights.byteCount, 78_400_833)
        XCTAssertEqual(weights.sha256, "20cd86fa5c6effedfda0e7cffe5b0569ca401c440a0c3a1d72bf39286c0db3fd")
        XCTAssertEqual(weights.sources, ["https://huggingface.co/csukuangfj2/sherpa-onnx-supertonic-3-tts-int8-2026-05-11/resolve/cca5a0e6c96e1d2c720986bf7e75fcc81dee3ae4/vector_estimator.int8.onnx"],
                       "the INT8 graphs come from the sherpa-onnx author's pinned Hugging Face revision")

        // Every file comes from its publisher at a pinned revision, never the owner's server (owner, 2026-10-19).
        let style = try XCTUnwrap(voice.files.first { $0.path == "voice_styles/F1.json" })
        XCTAssertEqual(style.sources, ["https://huggingface.co/Supertone/supertonic-3/resolve/3cadd1ee6394adea1bd021217a0e650ede09a323/voice_styles/F1.json"])
        XCTAssertFalse(voice.files.flatMap(\.sources).contains { $0.contains("proximitytoprogress") })
        // Our notice of modification has no publisher copy, so the catalog carries it.
        let notice = try XCTUnwrap(voice.files.first { $0.path == "onnx/MODIFIED.txt" })
        XCTAssertEqual(notice.sources, [])
        XCTAssertEqual(notice.content?.utf8.count, notice.byteCount)

        let total = voice.downloadByteCount
        XCTAssertGreaterThan(total, 140_000_000)
        XCTAssertLessThan(total, 150_000_000, "the bundled Supertonic is about 141 MB")
    }
}
