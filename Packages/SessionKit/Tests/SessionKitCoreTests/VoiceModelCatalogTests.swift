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
    private func testSigningKey() throws -> Curve25519.Signing.PrivateKey {
        let seed = Data(SHA256.hash(data: Data("spoken-margins voice-model-catalog test key".utf8)))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    private func signedEnvelope(_ payload: Data, keyId: String = "sm-test-1", context: Data = VoiceModelCatalogVerifier.signingContext) throws -> Data {
        let signature = try testSigningKey().signature(for: context + payload)
        let envelope = VoiceModelCatalogEnvelope(keyId: keyId, payload: payload.base64EncodedString(), signature: Data(signature).base64EncodedString())
        return try JSONEncoder().encode(envelope)
    }

    private func verify(_ fixtureName: String, last: Int? = nil, keys: [VoiceCatalogTrustedKey]? = nil) throws -> VerifiedVoiceModelCatalog {
        try VoiceModelCatalogVerifier.verify(
            envelopeData: fixture(fixtureName),
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
        XCTAssertEqual(try testSigningKey().publicKey.rawRepresentation, published)
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

    func testEmptyProductionKeyListFailsClosed() throws {
        XCTAssertThrowsError(try VoiceModelCatalogVerifier.verify(envelopeData: fixture("envelope-valid.json"), trustedKeys: VoiceCatalogTrust.production)) {
            XCTAssertEqual($0 as? VoiceCatalogError, .unknownKey("sm-test-1"))
        }
    }

    func testOlderCatalogThanTheLastAcceptedIsARollback() throws {
        XCTAssertThrowsError(try verify("envelope-rollback.json", last: 3)) {
            XCTAssertEqual($0 as? VoiceCatalogError, .rollback(lastAccepted: 3, offered: 1))
        }
        XCTAssertEqual(try verify("envelope-rollback.json", last: nil).catalogVersion, 1)
        XCTAssertEqual(try verify("envelope-rollback.json", last: 1).catalogVersion, 1)
        XCTAssertEqual(try verify("envelope-valid.json", last: 3).catalogVersion, 3, "the same version again is a refresh, not a rollback")
        XCTAssertEqual(try verify("envelope-withdrawn.json", last: 3).catalogVersion, 4)
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
        XCTAssertNoThrow(try VoiceModelCatalogVerifier.verify(envelopeData: signedEnvelope(payload), trustedKeys: trustedKeys()))
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
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("catalog-valid.json")) as? [String: Any])
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
        let catalog = try VoiceModelCatalogVerifier.verify(envelopeData: envelope, trustedKeys: trustedKeys())
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
        struct Table: Decodable { var sha256: [Row]; var httpsURL: [Row]; var filePath: [Row]; var id: [Row] }
        let table = try JSONDecoder().decode(Table.self, from: fixture("neighbour-inputs.json"))
        let rules: [(String, [Row], (String) -> Bool)] = [
            ("sha256", table.sha256, VoiceModelCatalogRules.isLowercaseSHA256),
            ("httpsURL", table.httpsURL, VoiceModelCatalogRules.isHTTPSURL),
            ("filePath", table.filePath, VoiceModelCatalogRules.isRelativeFilePath),
            ("id", table.id, VoiceModelCatalogRules.isVoiceID),
        ]
        for (name, rows, rule) in rules {
            XCTAssertGreaterThanOrEqual(rows.count, 10, name)
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
        XCTAssertNotNil(weights.origin, "the INT8 files exist only inside the pinned sherpa-onnx archive")

        // Files the pinned upstream revision serves are fetched from there first, the mirror second.
        let style = try XCTUnwrap(voice.files.first { $0.path == "voice_styles/F1.json" })
        XCTAssertTrue(style.sources[0].hasPrefix("https://huggingface.co/Supertone/supertonic-3/resolve/3cadd1ee6394adea1bd021217a0e650ede09a323/"))
        XCTAssertEqual(style.sources.count, 2)

        let total = voice.downloadByteCount
        XCTAssertGreaterThan(total, 140_000_000)
        XCTAssertLessThan(total, 150_000_000, "the bundled Supertonic is about 141 MB")
    }
}
