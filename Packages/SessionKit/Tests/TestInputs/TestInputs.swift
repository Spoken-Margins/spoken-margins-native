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
/// passed silently. `SESSIONKIT_CONTRACTS_DIR` points the Contracts input somewhere else.
/// `scripts/sessionkit_pass.py`'s `READS` lists the same folders, so the lane's pass key covers them.
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

        var environmentOverride: String? {
            self == .contracts ? "SESSIONKIT_CONTRACTS_DIR" : nil
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
            throw XCTSkip("needs \(input.rawValue)/ from the spoken-margins-native checkout; this package is checked out alone")
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
}
