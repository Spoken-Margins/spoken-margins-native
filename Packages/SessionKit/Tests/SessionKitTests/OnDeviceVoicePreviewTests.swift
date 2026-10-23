import Foundation
import XCTest
@testable import SessionKitSupertonic

/// #2219: "Try App Voice" with James or Lily chosen asked Supertonic for the sample even when its model wasn't
/// downloaded (#1820), and the listener heard nothing but "On-device voice preview failed". The sample now comes from
/// the voice that would read to them: Supertonic when it's there, Kitten when it isn't, the iOS voice when neither is.
final class OnDeviceVoicePreviewTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _log: [String] = []
        var log: [String] { lock.withLock { _log } }
        func append(_ entry: String) { lock.withLock { _log.append(entry) } }
    }

    private static func result(_ engine: String) -> SupertonicNarrationResult {
        SupertonicNarrationResult(audioURL: URL(fileURLWithPath: "/tmp/\(engine).wav"), duration: 1, sampleRate: 24_000,
                                  renderDuration: 0.1, sessionLoadCount: 1, engine: engine)
    }

    private func preview(modelPresent: Bool, supertonicError: Error? = nil, kittenOpens: Bool = true, calls: Calls) -> OnDeviceVoicePreview {
        OnDeviceVoicePreview(
            isModelPresent: { modelPresent },
            supertonic: { _, voice, _ in
                calls.append("supertonic:\(voice.rawValue)")
                if let supertonicError { throw supertonicError }
                return Self.result(SupertonicNarrationResult.supertonicEngine)
            },
            kitten: {
                guard kittenOpens else { return nil }
                return { _ in
                    calls.append("kitten")
                    return Self.result(KittenNarrationRenderer.engine)
                }
            }
        )
    }

    func testWithoutTheDownloadKittenSpeaksTheSampleAndSupertonicIsNeverAsked() async throws {
        let calls = Calls()
        let outcome = try await preview(modelPresent: false, calls: calls).render(text: "Hi", voice: .m2, speed: 1)
        guard case let .rendered(sample, supertonicMissing) = outcome else { return XCTFail("expected a rendered sample") }
        XCTAssertEqual(sample.engine, KittenNarrationRenderer.engine)
        XCTAssertTrue(supertonicMissing)
        XCTAssertEqual(calls.log, ["kitten"])
    }

    func testWithTheDownloadSupertonicSpeaksTheSampleInTheChosenVoice() async throws {
        let calls = Calls()
        let outcome = try await preview(modelPresent: true, calls: calls).render(text: "Hi", voice: .f1, speed: 1)
        guard case let .rendered(sample, supertonicMissing) = outcome else { return XCTFail("expected a rendered sample") }
        XCTAssertEqual(sample.engine, SupertonicNarrationResult.supertonicEngine)
        XCTAssertFalse(supertonicMissing)
        XCTAssertEqual(calls.log, ["supertonic:F1"])
    }

    func testAModelRemovedBetweenTheCheckAndTheRenderFallsBackToKitten() async throws {
        let calls = Calls()
        let outcome = try await preview(modelPresent: true, supertonicError: SupertonicNarrationError.missingAsset("Supertonic"),
                                        calls: calls).render(text: "Hi", voice: .m2, speed: 1)
        guard case let .rendered(sample, supertonicMissing) = outcome else { return XCTFail("expected a rendered sample") }
        XCTAssertEqual(sample.engine, KittenNarrationRenderer.engine)
        XCTAssertTrue(supertonicMissing)
        XCTAssertEqual(calls.log, ["supertonic:M2", "kitten"])
    }

    func testOtherSupertonicFailuresAreStillReportedNotHiddenBehindKitten() async {
        let calls = Calls()
        do {
            _ = try await preview(modelPresent: true, supertonicError: SupertonicNarrationError.emptyAudio, calls: calls)
                .render(text: "Hi", voice: .m2, speed: 1)
            XCTFail("expected the Supertonic failure")
        } catch {
            XCTAssertEqual(error as? SupertonicNarrationError, .emptyAudio)
        }
        XCTAssertEqual(calls.log, ["supertonic:M2"])
    }

    func testWithNeitherSupertonicNorKittenTheIOSVoicePreviews() async throws {
        let calls = Calls()
        let outcome = try await preview(modelPresent: false, kittenOpens: false, calls: calls).render(text: "Hi", voice: .m2, speed: 1)
        guard case .systemVoice = outcome else { return XCTFail("expected the iOS voice") }
        XCTAssertEqual(calls.log, [])
    }
}
