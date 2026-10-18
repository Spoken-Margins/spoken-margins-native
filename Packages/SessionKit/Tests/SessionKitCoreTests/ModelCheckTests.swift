import XCTest
import SessionKitTestInputs

/// #1893: a runner that is expected to have the Git LFS models must fail, not skip, when it has only pointers.
final class ModelCheckTests: XCTestCase {
    private let pointer = 133
    private let model = 56_767_095

    func testAPulledModelIsPresentWhateverTheEnvironment() {
        XCTAssertEqual(TestInputs.modelCheck(sizeInBytes: model, environment: [:]), .present)
        XCTAssertEqual(TestInputs.modelCheck(sizeInBytes: model, environment: ["CI": "true"]), .present)
    }

    func testAPointerSkipsWhenNothingRequiresModels() {
        XCTAssertEqual(TestInputs.modelCheck(sizeInBytes: pointer, environment: [:]), .skip)
        XCTAssertEqual(TestInputs.modelCheck(sizeInBytes: 0, environment: ["PATH": "/usr/bin"]), .skip)
        XCTAssertEqual(TestInputs.modelCheck(sizeInBytes: pointer, environment: ["CI": ""]), .skip, "an empty variable doesn't count")
    }

    func testAPointerFailsWhereCIOrSMRequireModelsIsSet() {
        XCTAssertEqual(TestInputs.modelCheck(sizeInBytes: pointer, environment: ["CI": "true"]), .fail)
        XCTAssertEqual(TestInputs.modelCheck(sizeInBytes: pointer, environment: ["SM_REQUIRE_MODELS": "1"]), .fail)
        XCTAssertEqual(TestInputs.modelCheck(sizeInBytes: 0, environment: ["SM_REQUIRE_MODELS": "1"]), .fail, "a missing file is a pointer too")
    }

    func testRequireModelThrowsASkipForAMissingFileOnALocalRun() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-model-\(UUID().uuidString).onnx")
        let environment = ProcessInfo.processInfo.environment
        let required = TestInputs.requireModelsVariables.contains { !(environment[$0] ?? "").isEmpty }
        do {
            try TestInputs.requireModel(at: missing)
            XCTFail("a missing model can't be present")
        } catch is XCTSkip {
            XCTAssertFalse(required)
        } catch is TestInputs.ModelNotPulled {
            XCTAssertTrue(required)
        }
    }
}
