import Foundation

// The speed check that sits around `PocketDeviceGate` (#462, part of #212). The gate is pure policy: given one timed
// render it says offer or don't offer. This file is the rest of the loop, kept out of the app model:
//
// - When it may measure. A hot or memory-starved phone renders slowly for a reason that will pass, so measuring then
//   would hide the voice from a phone that can run it. Low Power Mode alone does not stop a check: the owner's
//   reference speed was measured with it on, and power alone never changes the voice (I14,
//   `SpeechEngineSelection.swift`).
// - What it remembers. The timed render (audio seconds and render seconds), not the verdict, so a later build that
//   changes `PocketDeviceGate.referencePhoneSpeed` re-decides from the stored render without timing again.
// - Which files and which phone it was timed on. The record is tied to `modelKey` (the catalog's revision of the
//   voice's files) and to `deviceKey` (the phone's model identifier), so a new model is timed again, and so is a
//   faster phone's passing record restored from a backup onto a slower one (UserDefaults travels in backups).
// - How long a "too slow" lasts. A phone may have been warm, or a later iOS may be faster, so a too-slow render
//   expires and the voice gets one more try. A passing render stays until the model changes.
//
// The render itself is a closure the caller supplies (Pocket's renderer lives in `SessionKitPocket`, which needs
// onnxruntime and so doesn't build on Linux), which is also what lets the host test every branch with a fake.
//
// Order of use: the model's files must be on the phone to be timed, so the check runs after the download, never
// before it. Nothing in the app calls this yet.

/// The stored timed render and when it was made.
public struct PocketSpeedCheckRecord: Codable, Equatable, Sendable {
    public var modelKey: String
    /// The phone's model identifier when it was timed, for example `iPhone17,1`.
    public var deviceKey: String
    public var audioSeconds: Double
    public var renderSeconds: Double
    public var measuredAt: Date

    public init(modelKey: String, deviceKey: String, audioSeconds: Double, renderSeconds: Double, measuredAt: Date) {
        self.modelKey = modelKey
        self.deviceKey = deviceKey
        self.audioSeconds = audioSeconds
        self.renderSeconds = renderSeconds
        self.measuredAt = measuredAt
    }

    public var measurement: PocketRenderMeasurement {
        PocketRenderMeasurement(audioSeconds: audioSeconds, renderSeconds: renderSeconds)
    }
}

/// What the app knows about this phone and the voice right now.
public enum PocketSpeedCheckStatus: Equatable, Sendable {
    /// No usable timed render for these files: never measured, measured on other files, or a too-slow render that has expired.
    case notChecked
    case passed(speed: Double)
    case tooSlow(speed: Double, threshold: Double)

    /// Whether the voice may be offered: only a passing check says yes. A phone that hasn't been timed isn't handed the voice.
    public var allowsPocket: Bool {
        if case .passed = self { return true }
        return false
    }
}

/// Keeps the one timed render in this app's `UserDefaults`, never the database, so older builds are unaffected and
/// deleting the app deletes it.
public struct PocketSpeedCheckStore: @unchecked Sendable {
    public static let defaultsKey = "pocketSpeedCheck.v1"
    /// How long a "too slow" render counts before the voice is timed again.
    public static let tooSlowLifetime: TimeInterval = 30 * 24 * 60 * 60

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored render, if there is one for `modelKey` on `deviceKey`. A record for other files or another phone,
    /// or one this build can't read, is nil.
    public func record(modelKey: String, deviceKey: String) -> PocketSpeedCheckRecord? {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let record = try? JSONDecoder().decode(PocketSpeedCheckRecord.self, from: data),
              record.modelKey == modelKey, record.deviceKey == deviceKey else { return nil }
        return record
    }

    public func save(_ record: PocketSpeedCheckRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Forgets the render, for when the voice's files are removed.
    public func forget() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// A record dated further ahead than this is from a wrong clock, and ages as expired.
    public static let clockSkewAllowance: TimeInterval = 24 * 60 * 60

    /// The status for `modelKey` on `deviceKey` under `gate`, decided from the stored render now.
    public func status(modelKey: String, deviceKey: String, gate: PocketDeviceGate, now: Date) -> PocketSpeedCheckStatus {
        guard let record = record(modelKey: modelKey, deviceKey: deviceKey) else { return .notChecked }
        switch gate.decide(record.measurement) {
        case .offer:
            return .passed(speed: record.measurement.speed ?? 0)
        case .tooSlow(let speed, let threshold):
            // A record from the future (a wrong clock, since corrected) can't be aged, so past a day's skew it expires.
            let age = now.timeIntervalSince(record.measuredAt)
            guard age >= -Self.clockSkewAllowance, age < Self.tooSlowLifetime else { return .notChecked }
            return .tooSlow(speed: speed, threshold: threshold)
        case .inconclusive:
            return .notChecked
        }
    }
}

/// Times one render of `PocketDeviceGate.checkSentence`, at most one at a time, and remembers it.
public actor PocketSpeedCheck {
    public enum Deferral: Equatable, Sendable {
        /// The phone is hot (`serious` or `critical`): a render now would be slow for a reason that passes.
        case hot
        /// Within the backoff after an iOS memory warning.
        case recoveringFromMemoryWarning
    }

    public enum Outcome: Equatable, Sendable {
        /// A stored status answered, or a render was timed and stored.
        case status(PocketSpeedCheckStatus)
        /// Not measured now; ask again when the reason has cleared. Nothing is stored.
        case deferred(Deferral)
        /// The render was too short or its times were unusable. Nothing is stored; the caller may measure again.
        case inconclusive
        /// The render threw (files missing, runtime failure). Nothing is stored.
        case renderFailed
    }

    private let gate: PocketDeviceGate
    private let store: PocketSpeedCheckStore
    private let modelKey: String
    private let deviceKey: String
    /// Callers that joined a render already running, for tests to wait on.
    private(set) var joinedCallers = 0
    private let now: @Sendable () -> Date
    private var inFlight: Task<Outcome, Never>?

    public init(
        gate: PocketDeviceGate = PocketDeviceGate(),
        store: PocketSpeedCheckStore = PocketSpeedCheckStore(),
        modelKey: String,
        deviceKey: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gate = gate
        self.store = store
        self.modelKey = modelKey
        self.deviceKey = deviceKey
        self.now = now
    }

    /// What is stored, without measuring.
    public func currentStatus() -> PocketSpeedCheckStatus {
        store.status(modelKey: modelKey, deviceKey: deviceKey, gate: gate, now: now())
    }

    /// The stored status when there is one, otherwise one timed render. `render` gets
    /// `PocketDeviceGate.checkSentence` and returns what it produced and how long it took, model load excluded.
    /// Calls that arrive while a render is running wait for that render instead of starting another. The render
    /// belongs to the check, not to the caller: cancelling a caller doesn't stop it, and its result is remembered.
    public func check(
        conditions: SpeechEngineConditions,
        render: @escaping @Sendable (String) async throws -> PocketRenderMeasurement
    ) async -> Outcome {
        let stored = currentStatus()
        if stored != .notChecked { return .status(stored) }
        if let inFlight {
            joinedCallers += 1
            return await inFlight.value
        }
        if let deferral = Self.deferral(for: conditions) { return .deferred(deferral) }

        let task = Task<Outcome, Never> { await self.measureAndFinish(render: render) }
        inFlight = task
        return await task.value
    }

    /// Why a render now would say nothing about the phone, or nil when it would.
    public static func deferral(for conditions: SpeechEngineConditions) -> Deferral? {
        // The same rule that stops the on-device voice rendering (I14), so the two can't drift apart.
        switch SpeechEnginePolicy.onDeviceRenderingBlock(conditions) {
        case .deviceTooWarm: return .hot
        case .memoryWarning: return .recoveringFromMemoryWarning
        default: return nil
        }
    }

    /// Clears `inFlight` inside the actor as the render's last step, so a caller that arrives after a failed or
    /// unusable render starts a fresh one instead of being handed the old answer.
    private func measureAndFinish(render: @Sendable (String) async throws -> PocketRenderMeasurement) async -> Outcome {
        let outcome = await measure(render: render)
        inFlight = nil
        return outcome
    }

    private func measure(render: @Sendable (String) async throws -> PocketRenderMeasurement) async -> Outcome {
        let measurement: PocketRenderMeasurement
        do {
            measurement = try await render(PocketDeviceGate.checkSentence)
        } catch {
            return .renderFailed
        }
        guard gate.decide(measurement) != .inconclusive else { return .inconclusive }
        store.save(PocketSpeedCheckRecord(
            modelKey: modelKey,
            deviceKey: deviceKey,
            audioSeconds: measurement.audioSeconds,
            renderSeconds: measurement.renderSeconds,
            measuredAt: now()
        ))
        return .status(currentStatus())
    }
}
