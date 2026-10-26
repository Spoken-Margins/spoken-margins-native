import SessionKit
import XCTest

/// #64, #2700: saved audio of a downloaded voice (Phonon, Kokoro) is filed under an identity built from its catalog
/// entry. These pin that the identity changes exactly when the audio would: another model version, other file bytes,
/// another speaker, other synthesis settings or another text front end; and never for the catalog's file order.
final class DownloadedVoiceRenderIdentityTests: XCTestCase {
    private func entry(version: String = "1.0", files: [(String, String)] = [("model.bin", "a"), ("voices/af.bin", "b")]) -> VoiceModelEntry {
        VoiceModelEntry(
            id: "kokoro-82m", displayName: "Kokoro", publisher: "hexgrad", version: version,
            runtime: VoiceModelRuntime(name: "coreml", version: "1"), minimumIOSVersion: "26.0",
            minimumMemoryMegabytes: 1, minimumChip: "A14",
            files: files.map { path, fill in
                VoiceModelFile(path: path, byteCount: 1, sha256: String(repeating: fill, count: 64),
                               sources: ["https://voices.example/\(path)"], licenseId: "model")
            },
            licenses: [VoiceModelLicense(id: "model", name: "Apache 2.0", textURL: "https://voices.example/licence",
                                         textSHA256: String(repeating: "c", count: 64), requiresAcceptance: false)]
        )
    }

    private func make(_ entry: VoiceModelEntry, speaker: String = "af_heart", parameters: [String: String] = ["speed": "1"],
                      normalization: String = "misaki.v1", engine: String = "kokoro") -> TTSRenderSignature {
        DownloadedVoiceRenderIdentity.make(engine: engine, entry: entry, speaker: speaker, parameters: parameters,
                                           normalizationVersion: normalization)
    }

    func testTheSameEntryGivesTheSameIdentityAndCarriesItsEngineAndVersion() {
        let first = make(entry())
        XCTAssertEqual(first, make(entry()))
        XCTAssertEqual(first.engine, "kokoro")
        XCTAssertEqual(first.modelRevision, "1.0")
        XCTAssertEqual(first.digest.count, 64)
        XCTAssertNotEqual(first.engine, "supertonic", "a downloaded voice's chunks must never pass for Supertonic's")
    }

    func testTheCatalogsFileOrderDoesNotChangeTheIdentity() {
        let reordered = entry(files: [("voices/af.bin", "b"), ("model.bin", "a")])
        XCTAssertEqual(make(entry()), make(reordered))
    }

    func testEveryChangeThatChangesTheAudioChangesTheDigest() {
        let base = make(entry()).digest
        let variants: [(String, TTSRenderSignature)] = [
            ("version", make(entry(version: "1.1"))),
            ("file bytes", make(entry(files: [("model.bin", "d"), ("voices/af.bin", "b")]))),
            ("file path", make(entry(files: [("model2.bin", "a"), ("voices/af.bin", "b")]))),
            ("extra file", make(entry(files: [("model.bin", "a"), ("voices/af.bin", "b"), ("NOTICE", "e")]))),
            ("speaker", make(entry(), speaker: "am_adam")),
            ("parameters", make(entry(), parameters: ["speed": "1.1"])),
            ("normalization", make(entry(), normalization: "misaki.v2")),
            ("engine", make(entry(), engine: "phonon"))
        ]
        for (what, signature) in variants {
            XCTAssertNotEqual(signature.digest, base, what)
        }
    }

    func testParameterOrderDoesNotChangeTheIdentity() {
        let one = make(entry(), parameters: ["speed": "1", "steps": "8"])
        let other = make(entry(), parameters: ["steps": "8", "speed": "1"])
        XCTAssertEqual(one, other)
    }

    func testUpperCaseHexInTheCatalogNamesTheSameBytes() {
        let lower = entry(files: [("model.bin", "a")])
        var upper = lower
        upper.files[0].sha256 = upper.files[0].sha256.uppercased()
        XCTAssertEqual(DownloadedVoiceRenderIdentity.assetManifestHash(of: lower),
                       DownloadedVoiceRenderIdentity.assetManifestHash(of: upper))
    }
}
