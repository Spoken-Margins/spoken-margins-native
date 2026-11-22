import XCTest
import SessionKitTestInputs

/// #1387: Pocket's renderer tests find their weights, scoring Python and evidence folder through `TestInputs`.
/// The renderer tests are Apple-only, so the helper's rules are checked here, where Linux runs them too.
final class PocketTestInputsTests: XCTestCase {
    func testPocketPythonPrefersTheVariableAndIgnoresAnEmptyOne() throws {
        let named = try TestInputs.pocketPython(environment: ["POCKET_TTS_PYTHON": "/opt/pocket/bin/python"])
        XCTAssertEqual(named, "/opt/pocket/bin/python")
        // An empty variable falls through to the research folder's own environment, or skips when the package is alone.
        let fallback: String
        do {
            fallback = try TestInputs.pocketPython(environment: ["POCKET_TTS_PYTHON": ""])
        } catch is XCTSkip {
            XCTAssertNil(TestInputs.repositoryRoot, "a skip is only right when the package is checked out alone")
            return
        }
        XCTAssertTrue(fallback.hasSuffix("C2/.venv/bin/python"), fallback)
    }

    func testArtifactsFolderIsTheRepositorysIgnoredEvidenceFolderOrASkip() throws {
        let folder: URL
        do {
            folder = try TestInputs.artifactsFolder("pocket")
        } catch is XCTSkip {
            XCTAssertNil(TestInputs.repositoryRoot, "a skip is only right when the package is checked out alone")
            return
        }
        XCTAssertTrue(folder.path.hasSuffix("/artifacts/pocket"), folder.path)
        XCTAssertEqual(folder.deletingLastPathComponent().lastPathComponent, "artifacts")
    }

    func testPocketWeightsFolderIsFoundOrSkippedWithTheInputNamed() throws {
        let environment = ProcessInfo.processInfo.environment
        do {
            let folder = try TestInputs.pocketModel()
            if let override = environment["POCKET_TTS_MODEL_DIR"], !override.isEmpty {
                XCTAssertEqual(folder.path, URL(fileURLWithPath: override, isDirectory: true).path)
            } else {
                XCTAssertTrue(folder.path.hasSuffix("C2/models/pocket"), folder.path)
            }
        } catch let skip as XCTSkip {
            XCTAssertNil(TestInputs.repositoryRoot)
            XCTAssertTrue("\(skip)".contains("pocketModel"), "the skip names the input: \(skip)")
        }
    }
}
