import Foundation
import XCTest

/// Every file a SessionKit test reads from outside the package, by name (#1387).
///
/// The package is meant to build and test on its own. Its tests still read a few things the package
/// doesn't own: the canonical fixtures in `Contracts/`, the published catalog in `Site/`, recorded
/// research fixtures, and (for a handful of guards) the app's own source. Each one is an `Input` here,
/// so the list of outside reads is this file, not a search for `#filePath` walks.
///
/// Inside the spoken-margins-native checkout every input is found next to the package. A package
/// checked out alone has none of them: a test that needs one is skipped with the input named, never
/// passed silently. `SESSIONKIT_CONTRACTS_DIR`, `SESSIONKIT_VOICE_ASSETS_DIR` and `SESSIONKIT_SUPERTONIC_DIR`
/// point those three inputs somewhere else.
/// `scripts/sessionkit_pass.py`'s `READS` lists the same folders, so the lane's pass key covers them.
///
/// Read an input into a `let` before asserting on it. XCTest records a skip thrown inside an
/// `XCTAssert…` or `XCTUnwrap` expression as a failure, and `try?` turns it into a wrong value.
/// `scripts/check-sessionkit-standalone.sh --test` is what shows a call site that gets this wrong;
/// `scripts/tests/test_sessionkit_test_inputs.py` catches the common shapes in the fast plan.
public enum TestInputs {
    public enum Input: String, CaseIterable, Sendable {
        /// Schemas, fixtures and traces: the canonical home of the listening formats (#1386).
        case contracts = "Contracts"
        /// The onboarding catalog the website publishes.
        case site = "Site"
        /// Recorded fixtures and reference vectors kept with the research notes.
        case research = "research"
        /// The app's Swift sources, for guards that check the app still calls an extracted helper.
        case appSources = "App/SpokenMarginsApp/Sources/SpokenMarginsApp"
        /// The app's test sources, for the shipped-reader gate's scan.
        case appTests = "App/SpokenMarginsAppTests"
        /// Supertonic's licences and `asset-manifest.json`, which pins the model's hashes (#1820); not the model.
        case supertonicResources = "App/SpokenMarginsApp/Resources/Supertonic"
        /// The voice catalog snapshot the app ships, which Settings › Voices and the download card read.
        case voiceCatalogSnapshot = "App/SpokenMarginsApp/Resources/VoiceCatalog"
        /// The bundled Kitten voice: its model, pronunciation lexicon and g2p weights (the voice that stays in the app).
        case voiceAssets = "App/SpokenMarginsApp/Resources/Kitten"
        /// Supertonic's model: the four ONNX graphs, `tts.json`, `unicode_indexer.json` and the voice styles. Neither
        /// the repository nor the app holds it (#1820). `scripts/voice-catalog fetch supertonic-3-int8` downloads it
        /// here, each file checked against `Contracts/voice-models/sources.json`. Read it with `supertonicModel()`.
        case supertonicModel = "artifacts/voice-catalog/files/supertonic-3-int8"

        var environmentOverride: String? {
            switch self {
            case .contracts: return "SESSIONKIT_CONTRACTS_DIR"
            case .voiceAssets: return "SESSIONKIT_VOICE_ASSETS_DIR"
            case .supertonicModel: return "SESSIONKIT_SUPERTONIC_DIR"
            default: return nil
            }
        }
    }

    /// `Packages/SessionKit`, found from this file, so it is right wherever the package is checked out.
    public static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // TestInputs
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()

    /// The repository the package sits in, when it sits at `Packages/SessionKit` of one.
    public static var repositoryRoot: URL? {
        let candidate = packageRoot.deletingLastPathComponent().deletingLastPathComponent()
        guard packageRoot.deletingLastPathComponent().lastPathComponent == "Packages",
              FileManager.default.fileExists(atPath: candidate.appending(path: Input.contracts.rawValue).path)
        else { return nil }
        return candidate
    }

    /// The folder of `input`, or `XCTSkip` naming what is missing.
    public static func directory(_ input: Input) throws -> URL {
        if let name = input.environmentOverride, let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        guard let root = repositoryRoot else {
            throw XCTSkip("needs \(input) (\(input.rawValue)/) from the spoken-margins-native checkout; this package is checked out alone")
        }
        return root.appending(path: input.rawValue, directoryHint: .isDirectory)
    }

    /// A file or folder inside `input`, for example `url(.contracts, "fixtures/feeds/x.xml")`.
    public static func url(_ input: Input, _ relative: String) throws -> URL {
        try directory(input).appending(path: relative)
    }

    /// The text of a file inside `input`.
    public static func text(_ input: Input, _ relative: String) throws -> String {
        try String(contentsOf: url(input, relative), encoding: .utf8)
    }

    /// The bytes of a file inside `input`.
    public static func data(_ input: Input, _ relative: String) throws -> Data {
        try Data(contentsOf: url(input, relative))
    }

    /// A file inside the package itself, for guards that read package sources.
    public static func packageURL(_ relative: String) -> URL {
        packageRoot.appending(path: relative)
    }

    // MARK: Model files

    /// Supertonic's fetched model folder (the `supertonicModel` input), or `XCTSkip` saying how to fetch it. It is a
    /// download, not part of a checkout, so only `SM_REQUIRE_MODELS` turns a missing model into a failure; `CI` alone
    /// doesn't, because no hosted runner fetches it.
    public static func supertonicModel(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let folder = try directory(.supertonicModel)
        let graph = folder.appending(path: "onnx/vector_estimator.onnx")
        let size = (try? FileManager.default.attributesOfItem(atPath: graph.path)[.size] as? Int) ?? 0
        if size > 1_000_000 { return folder }
        if !(environment["SM_REQUIRE_MODELS"] ?? "").isEmpty { throw ModelNotFetched(path: graph.path) }
        throw XCTSkip("needs supertonicModel (\(folder.path)): Supertonic's model is a download, not in the repository (#1820). "
            + "Run `scripts/voice-catalog fetch supertonic-3-int8`, or set SESSIONKIT_SUPERTONIC_DIR to a folder that holds it")
    }

    public struct ModelNotFetched: Error, CustomStringConvertible {
        public let path: String
        public var description: String {
            "Supertonic's model is not at \(path), and this run requires models (SM_REQUIRE_MODELS is set): run `scripts/voice-catalog fetch supertonic-3-int8`"
        }
    }

    /// What a test that needs a Git LFS model should do (#1893).
    public enum ModelCheck: Equatable, Sendable {
        case present
        /// The file is a pointer or missing, and nothing says a model is required: skip.
        case skip
        /// The file is a pointer or missing, and `CI` or `SM_REQUIRE_MODELS` says a runner must have it: fail.
        case fail
    }

    /// Variables that say a missing model is a broken runner, not a reason to skip.
    public static let requireModelsVariables = ["SM_REQUIRE_MODELS", "CI"]

    /// A model larger than `minimumBytes` is present; a Git LFS pointer is a few hundred bytes. Where a runner
    /// is expected to have the models (`CI`, or `SM_REQUIRE_MODELS` set to anything), a pointer fails the test
    /// instead of skipping it, so a runner without LFS can't report green without testing the model.
    public static func modelCheck(
        sizeInBytes: Int, minimumBytes: Int = 1_000_000,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ModelCheck {
        if sizeInBytes > minimumBytes { return .present }
        let required = requireModelsVariables.contains { !(environment[$0] ?? "").isEmpty }
        return required ? .fail : .skip
    }

    public struct ModelNotPulled: Error, CustomStringConvertible {
        public let path: String
        public var description: String {
            "the model at \(path) is missing or a Git LFS pointer, and this run requires models (CI or SM_REQUIRE_MODELS is set): run `git lfs pull`"
        }
    }

    /// Returns when the model at `url` is there; otherwise skips, or throws `ModelNotPulled` where models are required.
    public static func requireModel(at url: URL, minimumBytes: Int = 1_000_000) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        switch modelCheck(sizeInBytes: size, minimumBytes: minimumBytes) {
        case .present: return
        case .skip: throw XCTSkip("skipped: \(url.lastPathComponent) not pulled (git lfs pull)")
        case .fail: throw ModelNotPulled(path: url.path)
        }
    }
}
