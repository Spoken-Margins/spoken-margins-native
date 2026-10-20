import Foundation

// Seam I14 (owner: C2 `voice`): which engine speaks and why, the one rate rule, and how
// structured-document roles (I13) sound. Every narration path follows it; C1 M3 reads the
// role rules. See docs/workstreams/interfaces.md.
//
// Invariants (#183):
// - Power state alone (Low Power Mode, charging) never changes the voice.
// - Any fallback has a reason the listener can see and diagnostics can log, and the chosen
//   voice comes back once that reason clears.
// - Rate is one number: the listener's multiplier. System speech never also applies the
//   Accessibility speaking rate.
// - Chunk boundaries never show as pause and resume.

/// Device heat, as `ProcessInfo.ThermalState` reports it.
public enum SpeechThermalLevel: String, Codable, Equatable, Sendable {
    case nominal, fair, serious, critical
}

/// What the device reports when an engine is chosen.
public struct SpeechEngineConditions: Equatable, Sendable {
    public var thermal: SpeechThermalLevel
    public var isLowPowerModeEnabled: Bool
    /// Nil when the app can't tell (battery monitoring unavailable).
    public var isOnExternalPower: Bool?
    /// Within the backoff after an iOS memory warning.
    public var isRecoveringFromMemoryWarning: Bool

    public init(
        thermal: SpeechThermalLevel = .nominal,
        isLowPowerModeEnabled: Bool = false,
        isOnExternalPower: Bool? = nil,
        isRecoveringFromMemoryWarning: Bool = false
    ) {
        self.thermal = thermal
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isOnExternalPower = isOnExternalPower
        self.isRecoveringFromMemoryWarning = isRecoveringFromMemoryWarning
    }

    /// For diagnostics: records power state next to the decision, so a device report shows
    /// whether charging or Low Power Mode coincided with a fallback. Never includes text.
    public var logDescription: String {
        let power = isOnExternalPower.map { $0 ? "external" : "battery" } ?? "unknown"
        return "thermal=\(thermal.rawValue) lowPower=\(isLowPowerModeEnabled) power=\(power) memoryBackoff=\(isRecoveringFromMemoryWarning)"
    }
}

/// Why narration is using a voice other than the one the listener chose.
public enum SpeechFallbackReason: String, Codable, Equatable, Sendable {
    case deviceTooWarm = "device_too_warm"
    case memoryWarning = "memory_warning"
    /// The on-device voice couldn't render the next passage in time.
    case renderTooSlow = "render_too_slow"
    case playbackFailed = "playback_failed"
    /// The on-device player stopped making sound and starting it again didn't help (#540).
    case playerStalled = "player_stalled"
    /// The app was in the background at a chunk seam and the next chunk wasn't rendered yet (#1673).
    case backgroundGap = "background_gap"
    case listenerStoppedGeneration = "listener_stopped_generation"

    /// Maps the Supertonic client's failure codes. `resourceBlock` is the policy's answer at
    /// the moment of the fallback, which names the resource that refused rendering.
    public init(supertonicCode: String, resourceBlock: SpeechFallbackReason?) {
        switch supertonicCode {
        case "supertonic_resource_pressure": self = resourceBlock ?? .deviceTooWarm
        case "supertonic_render_timeout": self = .renderTooSlow
        case "supertonic_player_stalled": self = .playerStalled
        case "supertonic_background_gap": self = .backgroundGap
        default: self = .playbackFailed
        }
    }

    /// Heat and memory pressure pass; the chosen voice comes back by itself once they clear.
    /// A stalled player was a hiccup, not a condition: the chosen voice gets another try at the next play.
    /// A background gap is the same: the voice was only behind while the app was away.
    /// A slow or failed render would likely fail again, so it waits for the listener's Retry.
    public var returnsAutomatically: Bool {
        self == .deviceTooWarm || self == .memoryWarning || self == .playerStalled || self == .backgroundGap
    }

    /// One line for the player when the app's own backup voice, not the iOS voice, reads in place of the chosen
    /// voice (#849). Only heat and memory send narration there; anything else gets the general line. The backup voice
    /// keeps the item to its end (#1786, `NarrationVoiceHold`), so no line promises the voice back at the next play.
    public var bundledVoiceExplanation: String {
        switch self {
        case .deviceTooWarm:
            "Using the app's backup voice while this iPhone is too warm. It reads the rest of this item, so the voice doesn't keep changing. Your voice comes back with the next item."
        case .memoryWarning:
            "Using the app's backup voice after an iOS memory warning. It reads the rest of this item. Your voice comes back with the next item."
        case .renderTooSlow, .playbackFailed, .playerStalled, .backgroundGap, .listenerStoppedGeneration:
            "Using the app's backup voice for the rest of this item. Your voice comes back with the next item."
        }
    }

    /// One line for the player, saying why and what happens next.
    public var listenerExplanation: String {
        switch self {
        case .deviceTooWarm:
            "Using the iOS voice while this iPhone is too warm. It reads the rest of this item, so the voice doesn't keep changing. Your voice comes back with the next item."
        case .memoryWarning:
            "Using the iOS voice after an iOS memory warning. Your voice comes back the next time you press play, after about a minute."
        case .renderTooSlow:
            "Using the iOS voice because the on-device voice couldn't keep up. Tap Retry to try it again."
        case .playbackFailed:
            "Using the iOS voice because the on-device voice hit a playback problem. Tap Retry to try it again."
        case .playerStalled:
            "Using the iOS voice because the on-device voice stopped playing. Your voice comes back the next time you press play."
        case .backgroundGap:
            "Using the iOS voice because the on-device voice wasn't ready for the next passage while the app was in the background. It reads the rest of this item. Your voice comes back with the next item."
        case .listenerStoppedGeneration:
            "Generation stopped · using the iOS system voice"
        }
    }
}

/// Why on-device narration stopped preparing (#314). The Supertonic client reports a code with
/// every stop: diagnostics keep it whole, and the player turns it into one sentence.
public enum SpeechGenerationStopReason {
    /// Every chunk rendered, but joining them into one saved file failed.
    public static let assemblyFailedCode = "prepared_audio_assembly_failed"
    /// Play found generation already stopped for this item and went straight to the iOS voice.
    public static let generationDisabledCode = "supertonic_generation_disabled"
    static let noReasonExplanation = "Generation stopped · using the iOS system voice"

    /// The code plus the error, so a device report shows what went wrong.
    public static func assemblyFailed(_ error: any Error) -> String {
        "\(assemblyFailedCode): \(String(describing: error))"
    }

    /// One line for the player. The stop's own reason decides: it belongs to the item on
    /// screen, while `fallbackReason` is the model's one app-wide value and may be left from
    /// another item, so it is used only for a stop that came without a reason.
    ///
    /// A stop that handed over to the iOS voice carries a `SpeechFallbackReason` raw value. A raw
    /// Supertonic code means a render failed while the on-device voice stayed in charge, so the
    /// line says why preparing stopped and never that the iOS voice is playing.
    public static func listenerExplanation(stopReason: String?, fallbackReason: SpeechFallbackReason?) -> String {
        guard let stopReason, !stopReason.isEmpty else {
            return fallbackReason?.listenerExplanation ?? noReasonExplanation
        }
        if stopReason.hasPrefix(assemblyFailedCode) {
            return "Couldn't save the finished audio on this iPhone. Tap Retry to try again."
        }
        if stopReason == generationDisabledCode { return noReasonExplanation }
        if let known = SpeechFallbackReason(rawValue: stopReason) { return known.listenerExplanation }
        switch SpeechFallbackReason(supertonicCode: stopReason, resourceBlock: nil) {
        case .renderTooSlow:
            return "The on-device voice stopped preparing because it couldn't keep up. Tap Retry to try again."
        case .deviceTooWarm, .memoryWarning:
            return "The on-device voice stopped preparing while this iPhone was too warm or low on memory. Tap Retry to try again."
        case .playbackFailed, .playerStalled, .backgroundGap, .listenerStoppedGeneration:
            return "The on-device voice stopped preparing after a rendering problem. Tap Retry to try again."
        }
    }
}

public enum SpeechEnginePolicy {
    /// Nil when the on-device voice may render. Low Power Mode and charging are not reasons:
    /// the listener chose the voice, and narration is the task they asked for (#183).
    public static func onDeviceRenderingBlock(_ conditions: SpeechEngineConditions) -> SpeechFallbackReason? {
        if conditions.isRecoveringFromMemoryWarning { return .memoryWarning }
        if conditions.thermal == .serious || conditions.thermal == .critical { return .deviceTooWarm }
        return nil
    }

    /// Whether the chosen voice should replace the fallback at the next play.
    public static func restoresChosenVoice(after reason: SpeechFallbackReason, conditions: SpeechEngineConditions) -> Bool {
        reason.returnsAutomatically && onDeviceRenderingBlock(conditions) == nil
    }
}

/// The listener's speed is one multiplier, and every engine plays at that speed.
///
/// `AVSpeechUtterance.rate` isn't proportional to speed. Measured on macOS 26 with
/// `AVSpeechSynthesizer.write` (Samantha and Eddy, 2026-09-28), rate 0.875 (the old mapping for
/// 1.75×) spoke at 3.1× and 1.0 at 4×. The table below inverts the average of those curves, so
/// system speech lands within about 10% of the chosen speed from 0.5× to 2×.
public enum SpeechRateRule {
    /// `AVSpeechUtteranceDefaultSpeechRate`: normal speed.
    public static let systemDefaultRate: Float = 0.5
    public static let multiplierRange: ClosedRange<Double> = 0.5...2.0

    /// (speed multiplier, AVSpeech rate) pairs, from the measurement above.
    static let systemRateTable: [(multiplier: Double, rate: Float)] = [
        (0.5, 0.07), (0.75, 0.31), (1.0, 0.5), (1.25, 0.545), (1.5, 0.585), (1.75, 0.62), (2.0, 0.665)
    ]

    /// System speech never borrows the Accessibility speaking rate, which would multiply the
    /// listener's speed (#183: 1.5 × 1.75).
    public static let systemSpeechUsesAccessibilitySettings = false

    public static func clampedMultiplier(_ multiplier: Double) -> Double {
        guard multiplier.isFinite else { return 1 }
        return min(multiplierRange.upperBound, max(multiplierRange.lowerBound, multiplier))
    }

    /// The speeds the speed button offers, slowest first: quarter steps from 0.5× to 2×. Each one is
    /// also a row of `systemRateTable`.
    public static let supportedMultipliers: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// A speed read from storage or a control, rounded to the nearest quarter step (ties go up) and
    /// held inside `multiplierRange`.
    ///
    /// Like `clampedMultiplier`, NaN gives 1× (#1962), so a bad value can't put playback at 2×. Infinite
    /// values still land on a bound: +∞ gives 2×, −∞ gives 0.5×. The app has always done that, so the
    /// saved speeds it reads back stay the same; every finite value is unchanged.
    public static func quarterStepMultiplier(_ multiplier: Double) -> Double {
        guard !multiplier.isNaN else { return 1 }
        return max(multiplierRange.lowerBound, min(multiplierRange.upperBound, (multiplier * 4).rounded() / 4))
    }

    /// The speed the speed button moves to from `current`: the next one up, wrapping from the top to
    /// the bottom. A speed within 0.001 of a step counts as that step.
    public static func next(after current: Double) -> Double {
        supportedMultipliers.first(where: { $0 > current + 0.001 }) ?? supportedMultipliers[0]
    }

    /// The `AVSpeechUtterance.rate` that speaks at `multiplier` times normal speed.
    public static func systemSpeechRate(forMultiplier multiplier: Double) -> Float {
        let target = clampedMultiplier(multiplier)
        let table = systemRateTable
        guard let upperIndex = table.firstIndex(where: { $0.multiplier >= target }) else {
            return table[table.count - 1].rate
        }
        guard upperIndex > 0 else { return table[0].rate }
        let lower = table[upperIndex - 1]
        let upper = table[upperIndex]
        let fraction = Float((target - lower.multiplier) / (upper.multiplier - lower.multiplier))
        return lower.rate + (upper.rate - lower.rate) * fraction
    }

    /// The app stores speed as `multiplier × 0.5` ("speechRate", in the units of
    /// `AVSpeechUtteranceDefaultSpeechRate`). This reads that stored value as a multiplier.
    public static func multiplier(forStoredRate storedRate: Float) -> Double {
        guard storedRate > 0 else { return 1 }
        return clampedMultiplier(Double(storedRate / systemDefaultRate))
    }
}

/// How the speech path voices a structured-document segment (I13 `role`). Mirrors the published
/// table in docs/workstreams/interfaces.md (I14, "how each kind of text is spoken").
public enum SpokenRoleTreatment: Equatable, Sendable {
    /// Read as written.
    case read
    /// Read with silence around it. The role's name is never spoken.
    case readWithPauses(before: TimeInterval, after: TimeInterval)
    /// Say the label the text opens with ("Figure 2."), pause, then the rest. Read where the
    /// reading order places it, never inside a sentence.
    case announceLabelThenRead
    /// Say the label and caption, then `notice`; the content itself is skipped.
    /// ("Table 3: Baseline characteristics. Table not read.")
    case announceAndSkip(notice: String)
    /// Say `notice` once for a run of these segments, then skip them ("References skipped.").
    case skipWithNoticeOnce(notice: String)
    /// Leave it out without a word.
    case skip
}

/// How the speech path voices an inline marker inside a segment (I13 `marker.kind`).
public enum SpokenMarkerTreatment: Equatable, Sendable {
    case readAsPrinted
    case silent
}

/// I14 role rules for I13 documents, keyed by the raw role and marker strings in C1's draft
/// schema. Roles are advisory (I13); these rules decide the sound. A role's text never disappears
/// silently except headers, footers, footnotes (skipped in place) and front matter.
/// Web articles keep `SpeechTextNormalizer`'s own handling.
public enum DocumentSpeechRules {
    public static func treatment(forRole role: String) -> SpokenRoleTreatment {
        switch role {
        case "body", "title", "abstract", "authors", "unknown":
            // Authors: the names only, once, after the title (owner decision, #191).
            return .read
        case "heading":
            return .readWithPauses(before: 0.7, after: 0.4)
        case "caption":
            return .announceLabelThenRead
        case "table":
            return .announceAndSkip(notice: "Table not read.")
        case "equation":
            // Display equations; a run of them is announced once. Inline math stays in the body.
            return .skipWithNoticeOnce(notice: "Equation.")
        case "reference":
            return .skipWithNoticeOnce(notice: "References skipped.")
        case "back_matter":
            return .skipWithNoticeOnce(notice: "Back matter skipped.")
        case "footnote", "front_matter", "page_header", "page_footer":
            return .skip
        default:
            return .read
        }
    }

    public static func treatment(forMarker kind: String) -> SpokenMarkerTreatment {
        switch kind {
        case "citation", "footnote":
            // Numeric and parenthetical citations and footnote markers are silent. A narrative
            // citation's name is sentence text, not a marker, so it is still read.
            return .silent
        default:
            return .readAsPrinted
        }
    }
}
