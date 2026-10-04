import Foundation

/// How long a text item takes to hear, and how long is left, at the listener's speed (#305).
///
/// Text items only know how far through the characters playback is, so the player showed "N%".
/// Speech runs at a steady number of written characters a second, and the speed control scales it
/// linearly for both the on-device Supertonic voice and the iOS voice (`SystemNarrationRateTests`),
/// so characters left ÷ (characters a second × speed) is the time left.
public struct ListeningTimeEstimate: Equatable, Sendable {
    public enum Basis: String, Equatable, Sendable {
        /// Characters a second measured from this item's rendered audio.
        case measured
        /// `ListeningTimeEstimator.defaultCharactersPerSecond`: nothing usable was measured.
        case typical
    }

    /// Listening time for the whole item at the current speed.
    public var totalSeconds: Double
    /// Listening time from the current position to the end at the current speed.
    public var remainingSeconds: Double
    /// Written characters heard per second at 1× that the estimate used.
    public var charactersPerSecondAtNormalSpeed: Double
    public var basis: Basis

    public init(totalSeconds: Double, remainingSeconds: Double, charactersPerSecondAtNormalSpeed: Double, basis: Basis) {
        self.totalSeconds = totalSeconds
        self.remainingSeconds = remainingSeconds
        self.charactersPerSecondAtNormalSpeed = charactersPerSecondAtNormalSpeed
        self.basis = basis
    }

    /// Short text beside the percentage: "about 12 min left", "under 1 min left".
    public var remainingText: String {
        guard remainingSeconds >= 60 else { return "under 1 min left" }
        return "about \(Self.shortDuration(remainingSeconds)) left"
    }

    /// Short text for a Library row: "about 25 min", "about 1 h 5 min".
    public var totalText: String {
        guard totalSeconds >= 60 else { return "under 1 min" }
        return "about \(Self.shortDuration(totalSeconds))"
    }

    /// Words for VoiceOver: "about 12 minutes left", "about 1 hour 5 minutes left".
    public var remainingSpokenText: String {
        guard remainingSeconds >= 60 else { return "less than a minute left" }
        let (hours, minutes) = Self.hoursAndMinutes(remainingSeconds)
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        return "about \(parts.joined(separator: " ")) left"
    }

    static func shortDuration(_ seconds: Double) -> String {
        let (hours, minutes) = hoursAndMinutes(seconds)
        if hours == 0 { return "\(minutes) min" }
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    /// Rounded to the nearest minute, never below one.
    static func hoursAndMinutes(_ seconds: Double) -> (hours: Int, minutes: Int) {
        let totalMinutes = max(1, Int((seconds / 60).rounded()))
        return (totalMinutes / 60, totalMinutes % 60)
    }
}

public enum ListeningTimeEstimator {
    /// Characters a second at 1× when nothing has been measured. Supertonic voice M2 at speed 1
    /// spoke prose at 13.3–15.3 characters a second (`SupertonicOutputCheck`).
    public static let defaultCharactersPerSecond = 14.0
    /// Less rendered audio than this is too little to trust over the typical rate.
    public static let minimumMeasuredSeconds = 20.0

    /// Nil when the item has no text.
    /// - Parameters:
    ///   - totalCharacters: characters in the item's text.
    ///   - charactersHeard: characters before the current position, in the same units.
    ///   - playbackSpeed: the listener's speed multiplier (1 is normal, 2 is double).
    ///   - measuredCharactersPerSecond: characters a second at 1× measured for this item, if any.
    public static func estimate(
        totalCharacters: Int,
        charactersHeard: Int,
        playbackSpeed: Double,
        measuredCharactersPerSecond: Double? = nil
    ) -> ListeningTimeEstimate? {
        guard totalCharacters > 0 else { return nil }
        let measured = measuredCharactersPerSecond.flatMap(plausibleRate)
        let rate = measured ?? defaultCharactersPerSecond
        let speed = playbackSpeed.isFinite && playbackSpeed > 0 ? playbackSpeed : 1
        let heard = min(totalCharacters, max(0, charactersHeard))
        let perSecond = rate * speed
        return ListeningTimeEstimate(
            totalSeconds: Double(totalCharacters) / perSecond,
            remainingSeconds: Double(totalCharacters - heard) / perSecond,
            charactersPerSecondAtNormalSpeed: rate,
            basis: measured == nil ? .typical : .measured
        )
    }

    /// Characters a second at 1× in audio already rendered for the item, or nil when there is
    /// too little plausible audio to judge.
    ///
    /// Chunk ranges count UTF-8 bytes; `utf8BytesPerCharacter` (the item text's `utf8.count`
    /// over its `count`) converts them to the characters the player counts. Chunks that
    /// `SupertonicOutputCheck` would reject as babble or lost words are left out.
    /// - Parameter renderSpeed: the synthesis speed the chunks were rendered at.
    public static func measuredCharactersPerSecond(
        chunks: [PreparedAudioChunk],
        renderSpeed: Double = 1,
        utf8BytesPerCharacter: Double = 1
    ) -> Double? {
        let bytesPerCharacter = utf8BytesPerCharacter.isFinite && utf8BytesPerCharacter >= 1 ? utf8BytesPerCharacter : 1
        let speed = renderSpeed.isFinite && renderSpeed > 0 ? renderSpeed : 1
        var characters = 0.0
        var seconds = 0.0
        for chunk in chunks where chunk.durationMs > 0 {
            let chunkCharacters = Double(max(0, chunk.sourceRange.utf8End - chunk.sourceRange.utf8Start)) / bytesPerCharacter
            let chunkSeconds = Double(chunk.durationMs) / 1000 * speed
            guard plausibleRate(chunkCharacters / chunkSeconds) != nil else { continue }
            characters += chunkCharacters
            seconds += chunkSeconds
        }
        guard seconds >= minimumMeasuredSeconds else { return nil }
        return characters / seconds
    }

    static func plausibleRate(_ rate: Double) -> Double? {
        guard rate.isFinite,
              rate >= SupertonicOutputCheck.slowestCharactersPerSecond,
              rate <= SupertonicOutputCheck.fastestCharactersPerSecond else { return nil }
        return rate
    }
}

extension ListeningTimeEstimate {
    /// The text scrubber's VoiceOver value: "42 percent, about 12 minutes left".
    public func scrubberAccessibilityValue(percent: Int) -> String {
        "\(percent) percent, \(remainingSpokenText)"
    }
}

extension ListeningTimeEstimator {
    /// A Library row's length for a text item at the listener's speed: "about 25 min". Nil for an
    /// item with no text, such as a podcast, which shows no estimate.
    public static func libraryTotalText(textCharacterCount: Int?, playbackSpeed: Double) -> String? {
        guard let textCharacterCount else { return nil }
        return estimate(totalCharacters: textCharacterCount, charactersHeard: 0, playbackSpeed: playbackSpeed)?.totalText
    }
}
