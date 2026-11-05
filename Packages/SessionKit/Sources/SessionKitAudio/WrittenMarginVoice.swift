import Foundation
import NaturalLanguage
import SessionKit

/// Which voice reads a friend's written note, decided once, before anything is rendered (#3365).
///
/// `AVSpeechSynthesizer.write` cannot tell us what was spoken: `willSpeakRange` fires for text the voice never speaks (the
/// default English voice reports a whole Japanese sentence as one range and gives it 0.19 s of audio; measured on the
/// owner's Mac, 2026-11-04). So the gate is capability, not output: every script in the note must be covered by the one
/// voice language chosen for it, and that voice must be installed now. A script missing from the table is not covered, so
/// a new script fails safe (no reading, the ordinary failure line) instead of being read as a fragment. Every voice is
/// taken to cover Latin letters: a zh-CN and a hi-IN voice were measured saying the English words of a mixed note.
/// Known limit: a capable voice that drops something anyway cannot be detected here.
public enum WrittenMarginVoice {
    public enum Script: Hashable, Sendable { case latin, han, hiragana, katakana, hangul, devanagari, thai, arabic, hebrew, cyrillic, greek, other }

    /// The script of a letter, or nil for a mark or symbol that does not decide the voice.
    public static func script(of scalar: Unicode.Scalar) -> Script? {
        guard scalar.properties.isAlphabetic else { return nil }
        switch scalar.value {
        case 0...0x24F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xFF21...0xFF5A: return .latin
        case 0x370...0x3FF, 0x1F00...0x1FFF: return .greek
        case 0x400...0x52F, 0x1C80...0x1C8F: return .cyrillic
        case 0x590...0x5FF: return .hebrew
        case 0x600...0x6FF, 0x750...0x77F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x900...0x97F: return .devanagari
        case 0xE00...0xE7F: return .thai
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return .hangul
        case 0x3040...0x309F: return .hiragana
        case 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return .katakana
        case 0x3005, 0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return .han
        default: return .other
        }
    }

    /// The voice languages and the non-Latin scripts each can read. Latin is covered by all of them.
    static let coverage: [(language: String, scripts: Set<Script>)] = [
        ("ja", [.han, .hiragana, .katakana]), ("zh-Hans", [.han]), ("zh-Hant", [.han]), ("ko", [.hangul, .han]),
        ("hi", [.devanagari]), ("th", [.thai]), ("ar", [.arabic]), ("he", [.hebrew]),
        ("ru", [.cyrillic]), ("uk", [.cyrillic]), ("el", [.greek]),
    ]

    /// The non-Latin scripts a note is written in.
    public static func nonLatinScripts(in text: String) -> Set<Script> {
        var found = Set<Script>()
        for scalar in text.unicodeScalars {
            if let script = script(of: scalar), script != .latin { found.insert(script) }
        }
        return found
    }

    /// Below this a language guess for a Latin-script note is not trusted, and the default voice reads it.
    static let confidenceFloor = 0.6

    /// The voice for the whole `text` (already `WrittenMarginSpeech.speakable`), or nil when none can read all of it.
    /// `voiceFor` is the installed voice for a language code; `isAvailable` is asked of every identifier last, at the time
    /// of the render, so a voice the listener has since removed means no reading.
    public static func voice(
        forNote text: String, voiceFor: (String) -> String?, defaultVoice: () -> String?, isAvailable: (String) -> Bool = { _ in true }
    ) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1_000)))
        let guess = recognizer.languageHypotheses(withMaximum: 1).first
        let needed = nonLatinScripts(in: text)
        func usable(_ identifier: String?) -> String? { identifier.flatMap { isAvailable($0) ? $0 : nil } }

        if needed.isEmpty {
            let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
            if letters >= 20, let guess, guess.value >= confidenceFloor, guess.key != .undetermined, let voice = usable(voiceFor(guess.key.rawValue)) { return voice }
            return usable(defaultVoice())
        }
        var candidates = coverage.filter { needed.isSubset(of: $0.scripts) }.map(\.language)
        let foreign = NLLanguageRecognizer() // the language of the non-Latin part alone, which the English around it would drown out
        foreign.processString(String(String.UnicodeScalarView(text.unicodeScalars.filter { script(of: $0).map { $0 != .latin } ?? false || $0.properties.isWhitespace }.prefix(1_000))))
        if let guess = foreign.dominantLanguage, let at = candidates.firstIndex(where: { $0.hasPrefix(guess.rawValue.prefix(2)) }) {
            candidates.insert(candidates.remove(at: at), at: 0) // the recognizer breaks the tie between Japanese, Chinese and Korean Han
        }
        for language in candidates { if let voice = usable(voiceFor(language)) { return voice } }
        return nil
    }
}
