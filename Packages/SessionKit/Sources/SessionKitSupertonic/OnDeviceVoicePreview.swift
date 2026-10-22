import Foundation

/// The "Try App Voice" sample for James or Lily (#2219). Supertonic's model is a download (#1820), so with none on the
/// phone the sample is spoken by the bundled Kitten voice, the voice that would read to the listener now, as the
/// player does. With Kitten's files unopenable too, the caller plays the iOS voice. Nothing here starts a download.
public struct OnDeviceVoicePreview: Sendable {
    public enum Outcome: Sendable {
        /// The sample, and the engine that made it (`SupertonicNarrationResult.engine`).
        case rendered(SupertonicNarrationResult, supertonicMissing: Bool)
        /// Neither Supertonic nor Kitten can speak it: the caller previews the iOS voice.
        case systemVoice
    }

    public typealias SupertonicRender = @Sendable (_ text: String, _ voice: SupertonicVoiceID, _ speed: Float) async throws -> SupertonicNarrationResult
    public typealias KittenRender = @Sendable (_ text: String) async throws -> SupertonicNarrationResult

    private let isModelPresent: @Sendable () -> Bool
    private let supertonic: SupertonicRender
    private let kitten: @Sendable () async -> KittenRender?

    /// `kitten` is nil when Kitten's files can't be opened.
    public init(
        isModelPresent: @escaping @Sendable () -> Bool,
        supertonic: @escaping SupertonicRender,
        kitten: @escaping @Sendable () async -> KittenRender?
    ) {
        self.isModelPresent = isModelPresent
        self.supertonic = supertonic
        self.kitten = kitten
    }

    /// Supertonic when its model is on the phone; Kitten when it isn't, including when the files leave between the
    /// check and the render (a Remove). Any other Supertonic failure is the caller's to report, as before.
    public func render(text: String, voice: SupertonicVoiceID, speed: Float) async throws -> Outcome {
        if isModelPresent() {
            do {
                return .rendered(try await supertonic(text, voice, speed), supertonicMissing: false)
            } catch SupertonicNarrationError.missingAsset {
                // Removed meanwhile: fall through to Kitten.
            }
        }
        guard let kitten = await kitten() else { return .systemVoice }
        return .rendered(try await kitten(text), supertonicMissing: true)
    }
}
