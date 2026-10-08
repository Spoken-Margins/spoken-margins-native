import XCTest
@testable import SessionKit

/// With remote AI switched off the runtime profile keeps only what the phone can do itself (#976).
/// No test covered this before it moved out of the app model.
final class RuntimeCapabilityProfileOnDeviceAITests: XCTestCase {
    private let remote = RuntimeCapabilityProfile(
        id: "default",
        displayName: "Default",
        capabilities: [
            "ai": ["generate_listening_map", "summarize_interjections", "cleanup_transcript", "defer_ai_jobs", "continue_discussion", "provider_diagnostics", "other_ai"],
            "audio": ["play", "record"]
        ],
        forbiddenCapabilities: ["zeta_forbidden", "alpha_forbidden"]
    )

    func testWithTheOnDeviceModelThePhoneCanAlsoDraftMapsAndSummarizeMargins() {
        let local = remote.limitedToOnDeviceAI(foundationModelAvailable: true)

        XCTAssertEqual(
            local.capabilities["ai"],
            ["generate_listening_map", "summarize_interjections", "cleanup_transcript", "defer_ai_jobs"],
            "the original list's order is kept and nothing is repeated"
        )
    }

    func testWithoutTheOnDeviceModelOnlyCleanupAndDeferringStay() {
        let local = remote.limitedToOnDeviceAI(foundationModelAvailable: false)

        XCTAssertEqual(local.capabilities["ai"], ["cleanup_transcript", "defer_ai_jobs"])
    }

    func testOtherCapabilityGroupsAreLeftAlone() {
        let local = remote.limitedToOnDeviceAI(foundationModelAvailable: true)

        XCTAssertEqual(local.capabilities["audio"], ["play", "record"])
        XCTAssertEqual(Set(local.capabilities.keys), ["ai", "audio"])
    }

    func testTheProfileIsRenamedAndTwoProviderFeaturesAreForbiddenInSortedOrder() {
        let local = remote.limitedToOnDeviceAI(foundationModelAvailable: true)

        XCTAssertEqual(local.id, "default-local-foundation")
        XCTAssertEqual(local.displayName, "Default · On-device AI")
        XCTAssertEqual(
            local.forbiddenCapabilities,
            ["alpha_forbidden", "continue_discussion", "provider_diagnostics", "zeta_forbidden"]
        )
    }

    func testForbiddenNamesAreNotRepeatedWhenTheProfileAlreadyForbadeThem() {
        let already = RuntimeCapabilityProfile(
            id: "p", displayName: "P", capabilities: [:],
            forbiddenCapabilities: ["continue_discussion", "provider_diagnostics"]
        )

        let local = already.limitedToOnDeviceAI(foundationModelAvailable: false)

        XCTAssertEqual(local.forbiddenCapabilities, ["continue_discussion", "provider_diagnostics"])
        XCTAssertEqual(local.capabilities["ai"], [], "a profile with no AI group gets an empty one")
    }
}
