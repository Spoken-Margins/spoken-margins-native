import Foundation
import SessionKit
import SessionKitSupertonic

// The on-device voices the speech player can be built over (#2700): Supertonic (James, Lily) and the downloaded
// Neural Engine voices (Phonon #2704, Kokoro #2705). `makeSpeechPlaybackClient` asks `OnDeviceVoiceEngines.make` for
// the renderer, the saved-audio identity and the "may it render now?" check, so a new voice needs no change to the
// app model. Kitten stays the hot-phone voice for all of them: when `renderingAllowed` says no, the player's
// pressure renderer (Kitten) reads, and its hold and seam rules (#1680) decide when the chosen voice comes back.

/// What a downloaded voice's own slice supplies. Until a slice registers one, its voice is not offered anywhere:
/// not in Settings › Voices, not in the App Voice picker, and never built into the player.
struct DownloadedVoiceRegistration: Sendable {
    /// Builds the voice's renderer to read with `speaker`, the descriptor's, so the voice it reads is the voice its
    /// saved audio is filed under. `installedFolder` finds the voice's folder on the phone now (nil after a Remove),
    /// so the renderer follows the files as Supertonic's does. Every result it returns must carry
    /// `DownloadedVoiceDescriptor.engine`, or its chunks are filed as stand-ins.
    let makeRenderer: @Sendable (_ speaker: String, _ installedFolder: @escaping @Sendable () -> URL?) -> any SupertonicRendering
    /// The one-time preparation after download (Core ML compile), or nil when the runtime needs none.
    let preparer: (any VoiceModelPreparing)?
}

/// One downloaded voice: its catalog id, its stored choice, and how its saved audio is identified.
///
/// A voice's identity is spelled out once, in its SessionKit signature (`PhononRenderSignature`,
/// `KokoroRenderSignature`), which already names the engine, the model files, the speaker's own file, the synthesis
/// settings, and the text and cutting versions its renderer uses. The descriptor only passes it the catalog entry and
/// `speaker`, and the renderer is built with the same `speaker` (#2762 audit: a fixed "en" speaker here, beside a
/// renderer reading Alfie, would have let a change of default voice reuse the old voice's chunks).
struct DownloadedVoiceDescriptor: Sendable {
    let voiceId: String
    let choice: ReadingVoiceChoice
    /// The catalog runtime name its preparer is registered under.
    let runtime: String
    /// The engine name its renderer stamps on every result and its saved audio is filed under. Never "supertonic".
    let engine: String
    /// The voice inside the model that the renderer reads with and the identity names.
    let speaker: String
    /// The voice's own saved-audio identity for `entry` read by `speaker`; nil when the entry doesn't list that voice.
    let identity: @Sendable (_ entry: VoiceModelEntry, _ speaker: String) -> TTSRenderSignature?
    let registration: DownloadedVoiceRegistration?

    var isAvailable: Bool { registration != nil }

    /// The identity of this voice's saved audio, from its catalog entry (#64). Throws rather than file audio under an
    /// identity that doesn't name this voice's engine or speaker.
    func signature(entry: VoiceModelEntry) throws -> TTSRenderSignature {
        guard let signature = identity(entry, speaker) else {
            throw OnDeviceVoiceEngines.Failure.noIdentity(voiceId: voiceId, speaker: speaker)
        }
        guard signature.engine == engine else {
            throw OnDeviceVoiceEngines.Failure.engineMismatch(voiceId: voiceId, identity: signature.engine, renderer: engine)
        }
        return signature
    }
}

/// Every downloaded voice this build knows, and what follows from which have registered.
enum DownloadedVoiceRegistry {
    /// The per-voice files (`PhononVoiceEngine.swift`, `KokoroVoiceEngine.swift`) each hold their own descriptor;
    /// a voice's slice registers by setting its `registration` there, and edits nothing here.
    static let all: [DownloadedVoiceDescriptor] = [PhononVoiceEngine.descriptor, KokoroVoiceEngine.descriptor]

    static func descriptor(for choice: ReadingVoiceChoice) -> DownloadedVoiceDescriptor? {
        all.first { $0.choice == choice && $0.isAvailable }
    }

    /// The downloaded voices with a player, for `VoiceDownloadsModel.playableVoiceIds`.
    static var playableVoiceIds: Set<String> {
        Set(all.filter(\.isAvailable).map(\.voiceId))
    }

    /// `base` with each registered voice's preparer added under its runtime.
    static func preparers(adding base: VoiceModelPreparers) -> VoiceModelPreparers {
        all.reduce(base) { preparers, descriptor in
            guard let preparer = descriptor.registration?.preparer else { return preparers }
            return preparers.registering(preparer, forRuntime: descriptor.runtime)
        }
    }
}

/// The catalog entries the app ships with (the bundled snapshot, which is the catalog until a signed one is fetched,
/// `VoiceDownloadsModel.catalogURL`). Decoded once, on first use, by whichever thread asks first. `warm()` starts
/// that decode off the main thread when a downloaded voice's engine is built, so the render checks `play()` makes on
/// the main thread find it ready (#2744 review); a play that beats the warm-up waits on it, once.
enum BundledVoiceCatalog {
    private static let entries: [String: VoiceModelEntry] = {
        guard let url = Bundle.main.url(forResource: "catalog-snapshot", withExtension: "json", subdirectory: "VoiceCatalog"),
              let data = try? Data(contentsOf: url),
              let catalog = try? VoiceModelCatalog.decode(data) else { return [:] }
        return Dictionary(catalog.voices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }()

    static func entry(voiceId: String) -> VoiceModelEntry? { entries[voiceId] }

    static func warm() {
        Task.detached(priority: .utility) { _ = entries.count }
    }
}

/// Where a voice's saved-audio identity comes from. A value, not a closure, so building the engine on the main thread
/// reads nothing: `make()` hashes Supertonic's files or decodes the catalog, and runs only in the player's detached
/// signature task.
enum VoiceSignatureSource: Sendable {
    case supertonic(SupertonicVoiceID)
    case downloaded(DownloadedVoiceDescriptor, entry: @Sendable () -> VoiceModelEntry?)
    /// A stored downloaded-voice choice this build has no player for: no saved audio is claimed for it.
    case unregistered(voiceId: String)

    func make() throws -> TTSRenderSignature {
        switch self {
        case .supertonic(let voice):
            return try SupertonicRenderIdentity.current(voice: voice)
        case .downloaded(let descriptor, let entry):
            guard let entry = entry() else { throw OnDeviceVoiceEngines.Failure.notInCatalog(descriptor.voiceId) }
            return try descriptor.signature(entry: entry)
        case .unregistered(let voiceId):
            throw OnDeviceVoiceEngines.Failure.notRegistered(voiceId)
        }
    }
}

/// What the speech player is built over for one reading-voice choice.
struct OnDeviceVoiceEngine {
    let renderer: any SupertonicRendering
    /// The saved-audio identity; `make()` runs off the main thread (the player's detached signature task).
    let signature: VoiceSignatureSource
    /// "May the chosen voice render now?", asked before each passage. False hands the passage to Kitten.
    let renderingAllowed: @Sendable () -> Bool
    /// What diagnostics show as the session's voice, or nil for Supertonic, whose line the model keeps itself.
    let sessionDescription: String?
}

enum OnDeviceVoiceEngines {
    enum Failure: Error, Equatable {
        /// The downloaded voice isn't in the catalog this build carries, so its saved audio has no identity.
        case notInCatalog(String)
        /// The stored choice is a downloaded voice whose slice hasn't registered a renderer in this build.
        case notRegistered(String)
        /// The catalog entry doesn't list the voice's speaker, so its audio has no identity.
        case noIdentity(voiceId: String, speaker: String)
        /// The identity names another engine than the renderer stamps, so its chunks would never match.
        case engineMismatch(voiceId: String, identity: String, renderer: String)
    }

    /// The engine for `selection`. James, Lily and Kitten get exactly what the player had before #2700: Supertonic's
    /// renderer, identity and model check (Kitten's player never lets it render). A downloaded voice gets its
    /// registered renderer, its catalog identity, and a check that it is installed, allowed on this chip and that the
    /// phone's heat, memory and power allow it now.
    @MainActor
    static func make(for selection: AppTTSVoiceSelection, model: Gate1AppModel, supportDirectory: URL) -> OnDeviceVoiceEngine {
        if let voiceId = selection.choice.downloadedVoiceId {
            guard let descriptor = DownloadedVoiceRegistry.descriptor(for: selection.choice),
                  let registration = descriptor.registration else { return unregistered(voiceId: voiceId, model: model) }
            return downloaded(
                descriptor, registration: registration, supportDirectory: supportDirectory,
                renderer: SharedDownloadedRenderers.shared.renderer(for: descriptor, registration: registration, supportDirectory: supportDirectory)
            )
        }
        SharedDownloadedRenderers.shared.releaseRetained() // a downloaded voice's model doesn't stay loaded beside Supertonic's
        let voice = selection.supertonicVoice ?? .m2
        return OnDeviceVoiceEngine(
            renderer: SupertonicDownloadedModelRenderer(model: model),
            signature: .supertonic(voice),
            renderingAllowed: model.supertonicModel.renderingAllowed(when: SupertonicModelNotDownloaded.governorAllowsRendering),
            sessionDescription: nil
        )
    }

    /// A stored downloaded-voice choice this build has no player for (saved by a newer build, say). Kitten reads every
    /// passage; Supertonic never renders in its place and no saved audio is claimed for it.
    @MainActor
    static func unregistered(voiceId: String, model: Gate1AppModel) -> OnDeviceVoiceEngine {
        SharedDownloadedRenderers.shared.releaseRetained()
        return OnDeviceVoiceEngine(
            renderer: SupertonicDownloadedModelRenderer(model: model),
            signature: .unregistered(voiceId: voiceId),
            renderingAllowed: { false },
            sessionDescription: "Kitten (\(voiceId) has no player in this build)"
        )
    }

    /// Separate from `make` so tests can build a downloaded voice's engine over a temporary folder and a fake governor.
    static func downloaded(
        _ descriptor: DownloadedVoiceDescriptor,
        registration: DownloadedVoiceRegistration,
        supportDirectory: URL,
        entry: @escaping @Sendable () -> VoiceModelEntry? = { nil },
        deviceChipGeneration: @escaping @Sendable () -> Int? = { VoiceDeviceProbe.chipGeneration() },
        physicalMemoryMegabytes: @escaping @Sendable () -> Int = { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) },
        governorAllows: @escaping @Sendable () -> Bool = SupertonicModelNotDownloaded.governorAllowsRendering,
        renderer sharedRenderer: (any SupertonicRendering)? = nil
    ) -> OnDeviceVoiceEngine {
        let voiceId = descriptor.voiceId
        BundledVoiceCatalog.warm()
        let catalogEntry: @Sendable () -> VoiceModelEntry? = { entry() ?? BundledVoiceCatalog.entry(voiceId: voiceId) }
        let installedFolder: @Sendable () -> URL? = {
            VoiceCatalogCoordinator.installedFolder(voiceId: voiceId, supportDirectory: supportDirectory)
        }
        return OnDeviceVoiceEngine(
            renderer: sharedRenderer ?? registration.makeRenderer(descriptor.speaker, installedFolder),
            signature: .downloaded(descriptor, entry: catalogEntry),
            renderingAllowed: {
                guard let entry = catalogEntry(),
                      VoiceDeviceFit.canRender(
                          entry, deviceGeneration: deviceChipGeneration(), physicalMemoryMegabytes: physicalMemoryMegabytes()
                      ),
                      installedFolder() != nil else { return false }
                return governorAllows()
            },
            sessionDescription: descriptor.engine
        )
    }
}
