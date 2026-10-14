import Foundation

/// Maps misaki and CMUdict pronunciations onto espeak-ng's en-us IPA conventions, because Kitten was
/// trained on espeak's phoneme strings. A port of `research/C2/frontend/lexmap.py` (plus `arpabet_to_ipa`
/// from `frontend.py`), which stays the reference; `KittenFrontEndTests` checks the result. Nothing
/// from espeak ships: these are spelling rules derived by comparing dictionary entries with its output.
enum Espeakify {
    static let vowels = "aeiouæɑɐɒɔəɚɛɜɪʊʌᵻ"
    private static let vowelClass = "[\(vowels)]"
    private static let vowelNuclei = "aɪ|aʊ|eɪ|oʊ|ɔɪ|" + vowelClass

    private static let rColouredBeforeVowel = Rx("(ɚ|ɜː)(?=[ˈˌ]?\(vowelClass))")
    private static let stressedLongVowel = Rx("([ˈˌ])(i|u|ɑ)(?!ː)")
    private static let stressedLongO = Rx("([ˈˌ])ɔ(?=[lɹɾ]|$)")
    private static let unstressedLongBeforeR = Rx("(?<![ˈˌ])(ɑ|ɔ)(?=ɹ)")
    private static let nucleus = Rx(vowelNuclei)
    private static let singleSyllableLong = Rx("(?<![ˈˌ])(i|u|ɑ|ɔ)(?![ːɪ])(?=\\S*$)")
    private static let afterPrimary = Rx("^(.*?(?:\(vowelNuclei))ː?)([^ˌ]*)ˌ")
    private static let leadingSchwa = Rx("^ə(?=[^\(vowels)ː])")
    private static let unstressedI = Rx("(?<![ˈˌ])i(?=[^\\sː])")
    private static let leadingShortI = Rx("^ɪ")
    private static let prefixWord = Rx("^(be|re|de|pre)[^aeiou]")
    private static let prefixSchwa = Rx("^([^\(vowels)ˈˌ]+)ə(?=[^ˈˌ]*ˈ)")
    private static let flap = Rx("(?<=[\(vowels)ː])t(?=[əɪᵻɚi](?!ː))")
    private static let arpabetPhone = Rx("^([A-Z]+)(\\d?)")

    /// misaki's one-letter diphthongs and affricates, then the espeak spelling rules.
    static func fromMisaki(_ phonemes: String, word: String = "") -> String {
        var s = phonemes
        for (a, b) in [("A", "eɪ"), ("I", "aɪ"), ("W", "aʊ"), ("Y", "ɔɪ"), ("O", "oʊ"), ("ʤ", "dʒ"), ("ʧ", "tʃ"), ("ᵊ", "ə")] {
            s = s.replacingLiteral(a, with: b)
        }
        return espeakify(s, word: word)
    }

    /// CMUdict phones (ARPAbet with stress digits) to IPA, before `espeakify`.
    static func ipa(fromArpabet phones: [String]) -> String {
        var out = ""
        for phone in phones {
            guard let match = arpabetPhone.firstMatch(in: phone) else { continue }
            let base = match.group(1) ?? "", stress = match.group(2) ?? ""
            var symbol = FrontEndTables.arpabet[base] ?? ""
            if base == "AH", stress == "0" || stress.isEmpty { symbol = "ə" }
            if base == "ER", stress == "0" { symbol = "əɹ" }
            out += (stress == "1" ? "ˈ" : stress == "2" ? "ˌ" : "") + symbol
        }
        // Flap t/d between vowels before an unstressed vowel.
        return flap.sub(out, template: "ɾ")
    }

    /// Applies espeak's spelling habits to an IPA string in misaki-like conventions.
    static func espeakify(_ phonemes: String, word: String = "") -> String {
        var s = phonemes
        // r-coloured vowels
        s = s.replacingLiteral("ɜɹ", with: "ɜː").replacingLiteral("əɹ", with: "ɚ")
        s = rColouredBeforeVowel.sub(s, template: "$1ɹ")
        // long vowels: stressed i/u/ɑ, ɔ only before l/ɹ/ɾ/end, and ɑ/ɔ before ɹ
        s = stressedLongVowel.sub(s, template: "$1$2ː")
        s = stressedLongO.sub(s, template: "$1ɔː")
        s = unstressedLongBeforeR.sub(s, template: "$1ː")
        let nuclei = nucleus.matches(in: s).count
        if nuclei == 1 {
            s = singleSyllableLong.sub(s, template: "$1ː")
            if !s.contains("ˈ") { s = s.replacingLiteral("ˌ", with: "ˈ") }
        }
        // secondary stress: espeak drops it right before the primary and after it
        if let primary = s.firstIndex(of: "ˈ") {
            var head = String(s[..<primary])
            var tail = String(s[s.index(after: primary)...])
            if head.filter({ $0 == "ˌ" }).count == 1 {
                let afterSecondary = head.split(separator: "ˌ", maxSplits: 1, omittingEmptySubsequences: false)[1]
                if nucleus.matches(in: String(afterSecondary)).count <= 1 { head = head.replacingLiteral("ˌ", with: "") }
            }
            // after the primary: dropped when it's the very next syllable ('something'), kept later ('anything')
            if let match = afterPrimary.firstMatch(in: tail), nucleus.matches(in: match.group(2) ?? "").isEmpty {
                if let secondary = tail.firstIndex(of: "ˌ") { tail.remove(at: secondary) }
            }
            s = head + "ˈ" + tail
        }
        // reduced vowels
        s = leadingSchwa.sub(s, template: "ɐ")
        s = unstressedI.sub(s, template: "ɪ")
        if word.hasPrefix("ex") || word.hasPrefix("en") || word.hasPrefix("em") {
            s = leadingShortI.sub(s, template: "ɛ")
        }
        if prefixWord.isMatch(word) {
            s = prefixSchwa.sub(s, template: "$1ᵻ")
        }
        return s
    }
}
