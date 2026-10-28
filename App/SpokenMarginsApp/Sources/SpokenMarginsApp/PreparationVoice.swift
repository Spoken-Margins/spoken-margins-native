import Foundation
import SessionKit
import SessionKitSupertonic

/// The voice that Prepare Offline renders a Library item's audio with (#2857): James or Lily (Supertonic), or a
/// downloaded Neural Engine voice (Phonon, Kokoro). Prepare was written against Supertonic and every path asked
/// `AppTTSVoiceSelection.supertonicVoice`, which is nil for the downloaded voices, so choosing Phonon prepared nothing.
///
/// A downloaded voice prepares with the renderer, saved-audio identity and "may it render now?" check that live
/// playback already uses (`OnDeviceVoiceEngines.downloaded`), so its chunks are filed under its own
/// `TTSRenderSignature` and a change of voice never plays another voice's chunks. The renderer is shared with the
/// player while the player holds it (`SharedDownloadedRenderers`), so preparing doesn't load a second copy of an
/// 800 MB model. Only explicit Prepare uses it; the automatic startup and charging jobs stay Supertonic's.
struct PreparationVoice {
    /// What `render(voice:)` is given. A downloaded voice's renderer ignores it.
    let renderVoice: SupertonicVoiceID
    /// Names this voice in per-item retry cooldowns.
    let key: String
    /// Said when Prepare can't start because the voice's files aren't on the phone.
    let notInstalledMessage: String
    /// Whether the voice's files are on the phone (and, for Supertonic, valid).
    let isInstalled: @Sendable () -> Bool
    /// The identity of this voice's saved audio. Hashes model files for Supertonic: run it off the main thread.
    let signature: @Sendable () throws -> TTSRenderSignature
    /// False while heat, memory or power say the voice must not render now. Supertonic's own governor decides inside
    /// its renderer, so for James and Lily this is always true.
    let allowedNow: @Sendable () -> Bool
    /// A renderer that paces itself whatever the app's state, as background preparation must (#377).
    let makeRenderer: @MainActor () throws -> any SupertonicRendering
    /// Distinguishes the assembled file of a downloaded voice from James's or Lily's of the same text. nil keeps the
    /// Supertonic voice's own name for it, which is what every earlier build wrote.
    let assemblyVoiceKey: @Sendable (TTSRenderSignature) -> String?

    /// The voice for `selection`, or nil when it has none: Kitten, the iOS voice, or a downloaded voice this build
    /// has no player for.
    @MainActor
    static func current(for selection: AppTTSVoiceSelection, model: Gate1AppModel) -> PreparationVoice? {
        if let voice = selection.supertonicVoice {
            return PreparationVoice(
                renderVoice: voice,
                key: voice.rawValue,
                notInstalledMessage: "Supertonic isn't downloaded. Get it in Settings › Voices.",
                isInstalled: { SupertonicAssetResolver.location() != nil },
                signature: {
                    guard let assets = SupertonicAssetResolver.location() else { throw SupertonicNarrationError.missingAsset("Supertonic") }
                    return try SupertonicRenderIdentity.make(assets: assets, voice: voice)
                },
                allowedNow: { true },
                makeRenderer: { BackgroundPreparationRenderer(base: try model.makeSupertonicRenderer()) },
                assemblyVoiceKey: { _ in nil }
            )
        }
        guard selection.choice.downloadedVoiceId != nil,
              let descriptor = DownloadedVoiceRegistry.descriptor(for: selection.choice),
              let registration = descriptor.registration,
              let supportDirectory = try? model.applicationSupportDirectory() else { return nil }
        let engine = OnDeviceVoiceEngines.downloaded(
            descriptor, registration: registration, supportDirectory: supportDirectory,
            deviceChipGeneration: model.preparationSeams.deviceChipGeneration,
            renderer: SharedDownloadedRenderers.shared.renderer(for: descriptor, registration: registration, supportDirectory: supportDirectory)
        )
        let voiceId = descriptor.voiceId
        let signatureSource = engine.signature
        let renderer = engine.renderer
        return PreparationVoice(
            renderVoice: .m2,
            key: selection.rawValue,
            notInstalledMessage: "\(selection.displayName) isn't downloaded. Get it in Settings › Voices.",
            isInstalled: { VoiceCatalogCoordinator.installedFolder(voiceId: voiceId, supportDirectory: supportDirectory) != nil },
            signature: { try signatureSource.make() },
            allowedNow: engine.renderingAllowed,
            makeRenderer: { renderer.pacedForBackgroundPreparation() },
            assemblyVoiceKey: { $0.digest }
        )
    }
}

/// One renderer per downloaded voice while anything holds it: the player's and Prepare's share a loaded model
/// instead of each loading its own. Weak, so a voice nobody is using frees its model as it did before; tests that build
/// engines with `OnDeviceVoiceEngines.downloaded` directly never touch it.
final class SharedDownloadedRenderers: @unchecked Sendable {
    static let shared = SharedDownloadedRenderers()

    private struct Entry { weak var renderer: AnyObject? }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Preparation builds its voice for every chunk and keeps no reference between them, so the renderer is also held
    /// here for a while after each use. Otherwise, with no player holding it, every chunk would load the model again
    /// and lose the renderer's pacing rest.
    private var retained: [String: any SupertonicRendering] = [:]
    private var uses: [String: Int] = [:]
    static let retention: Duration = .seconds(90)

    func renderer(
        for descriptor: DownloadedVoiceDescriptor, registration: DownloadedVoiceRegistration, supportDirectory: URL
    ) -> any SupertonicRendering {
        let key = "\(descriptor.voiceId)|\(descriptor.speaker)"
        let (renderer, use) = lock.withLock { () -> (any SupertonicRendering, Int) in
            let found = entries[key]?.renderer as? any SupertonicRendering
            let voiceId = descriptor.voiceId
            let made = found ?? registration.makeRenderer(descriptor.speaker) {
                VoiceCatalogCoordinator.installedFolder(voiceId: voiceId, supportDirectory: supportDirectory)
            }
            if found == nil { entries[key] = Entry(renderer: made as AnyObject) }
            retained[key] = made
            uses[key, default: 0] += 1
            return (made, uses[key] ?? 0)
        }
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.retention)
            self?.release(key: key, ifLastUse: use)
        }
        return renderer
    }

    private func release(key: String, ifLastUse use: Int) {
        lock.withLock {
            guard uses[key] == use else { return }
            retained[key] = nil
        }
    }
}
