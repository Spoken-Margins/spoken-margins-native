#if canImport(AVFoundation)
import SessionKitAudio
import XCTest

/// APA-06 (#1042): the output guard builds its iOS-voice renderer as `SystemVoiceChunkRenderer()`, so the
/// default decides whether the synthesizer shares the app's audio session, which went silent on the owner's
/// phone while reporting "playing" (#288). The app-hosted session probe can't tell the two settings apart on
/// the simulator, so the default is pinned here. The setting is private; the test reads it by reflection
/// rather than widen the renderer's API for a test.
final class SystemVoiceChunkRendererDefaultTests: XCTestCase {
    func testTheDefaultRendererKeepsTheSynthesizerOffTheAppsSession() throws {
        XCTAssertEqual(try usesApplicationAudioSession(SystemVoiceChunkRenderer()), false,
                       "the renderer the output guard builds must not share the app's audio session (#288)")
        XCTAssertEqual(try usesApplicationAudioSession(SystemVoiceChunkRenderer(usesApplicationAudioSession: true)), true,
                       "control: the reflection reads the setting the renderer was given")
    }

    private func usesApplicationAudioSession(_ renderer: SystemVoiceChunkRenderer) throws -> Bool {
        let value = Mirror(reflecting: renderer).children.first { $0.label == "usesApplicationAudioSession" }?.value
        return try XCTUnwrap(value as? Bool, "SystemVoiceChunkRenderer no longer stores usesApplicationAudioSession")
    }
}
#endif
