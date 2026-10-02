import Foundation
import XCTest

/// The model's source layout is the regression in #319: behavior tests cannot detect
/// putting every concern back into the file that parallel sessions collide in.
final class Gate1AppModelLayoutTests: XCTestCase {
    private var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/SpokenMarginsApp/Sources/SpokenMarginsApp")
    }

    func testMainModelKeepsStateAndInitializationWithoutConcernImplementations() throws {
        let source = try String(contentsOf: appSources.appendingPathComponent("Gate1AppModel.swift"), encoding: .utf8)
        XCTAssertLessThan(source.components(separatedBy: .newlines).count, 1_500,
                          "Keep concern implementations in extensions instead of growing the shared model file")
        XCTAssertTrue(source.contains("final class Gate1AppModel: ObservableObject"))
        XCTAssertTrue(source.contains("    init("))
        XCTAssertTrue(source.contains("    deinit {"))
        for name in ["start", "beginInterjection", "importTextItem", "openLibrary",
                     "followSource", "saveProviderSettings", "refreshDiagnostics", "startGuidedOnboarding"] {
            XCTAssertFalse(source.contains("func \(name)("), "\(name) belongs in its concern extension")
        }
    }

    func testEachConcernHasItsOwnModelExtension() throws {
        let entryPoints = [
            "Playback": "start",
            "Margins": "beginInterjection",
            "ImportAndShare": "importTextItem",
            "Library": "openLibrary",
            "Following": "followSource",
            "Settings": "saveProviderSettings",
            "Diagnostics": "refreshDiagnostics",
            "Onboarding": "startGuidedOnboarding"
        ]
        for (concern, entryPoint) in entryPoints {
            let path = appSources.appendingPathComponent("Gate1AppModel+\(concern).swift")
            guard FileManager.default.fileExists(atPath: path.path) else {
                XCTFail("Missing \(concern) extension")
                continue
            }
            let source = try String(contentsOf: path, encoding: .utf8)
            XCTAssertTrue(source.contains("extension Gate1AppModel {"), concern)
            XCTAssertTrue(source.contains("func \(entryPoint)("), "\(entryPoint) belongs in \(concern)")
        }
    }
}
