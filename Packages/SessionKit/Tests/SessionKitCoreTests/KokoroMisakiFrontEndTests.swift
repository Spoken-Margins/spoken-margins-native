import Foundation
import XCTest
@testable import SessionKitSpeechFrontEnd
import SessionKitTestInputs

/// Kokoro reads text with misaki's dictionaries and misaki's number reading, not Kitten's (#2705).
///
/// The dictionary here is a slice of the real misaki 0.9.4 `us_gold.json` and `us_silver.json` (the entries for the
/// words these inputs use, `MisakiFixture`), merged by the same `MisakiLexicon.tsv` the phone runs after the download.
/// Words in neither go to the real bundled Kitten front end, as they do on the phone.
final class KokoroMisakiFrontEndTests: XCTestCase {
    private func kitten() throws -> KittenFrontEnd {
        let assets = try TestInputs.directory(.voiceAssets)
        return try KittenFrontEnd(lexiconURL: assets.appending(path: "lexicon.tsv"),
                                  g2pWeightsURL: assets.appending(path: "g2p_weights.bin"),
                                  g2pManifestURL: assets.appending(path: "g2p_weights.json"))
    }

    private func lexicon() throws -> MisakiLexicon {
        let gold = try JSONSerialization.data(withJSONObject: MisakiFixture.gold)
        let silver = try JSONSerialization.data(withJSONObject: MisakiFixture.silver)
        let url = FileManager.default.temporaryDirectory.appending(path: "misaki-fixture-\(UUID().uuidString).tsv")
        try MisakiLexicon.tsv(goldJSON: gold, silverJSON: silver).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try MisakiLexicon(contentsOf: url)
    }

    /// Kokoro's vocabulary symbols (the port's runtime/kokoro-vocab.json keys).
    private static let symbols: String = ";:,.!?—…\"()“”ʣʥʦʨᵝꭧAIOQSTWYᵊabcdefhijklmnopqrstuvwxyzɑɐɒæβɔɕçɖðʤəɚɛɜɟɡɥɨɪʝɯɰŋɳɲɴøɸθœɹɾɻʁɽʂʃʈʧʊʋʌɣɤχʎʒʔˈˌːʰʲ↓→↗↘ᵻ"

    private func vocabJSON() throws -> Data {
        var vocab: [String: Int] = [:]
        for (index, character) in Self.symbols.enumerated() { vocab[String(character)] = index + 1 }
        return try JSONSerialization.data(withJSONObject: ["vocab": vocab])
    }

    private func misakiFrontEnd() throws -> KokoroFrontEnd {
        try KokoroFrontEnd(vocabJSON: vocabJSON(), lexicon: lexicon(), fallback: kitten())
    }

    /// What Kokoro got before: Kitten's front end, respelled.
    private func kittenFrontEnd() throws -> KokoroFrontEnd {
        let kitten = try kitten()
        return try KokoroFrontEnd(vocabJSON: vocabJSON()) { kitten.phonemize($0) }
    }

    // MARK: The table

    /// Neighbouring inputs: numbers, years, money, times, abbreviations, function words, stems, rare words and
    /// Unicode. Each row is what Kokoro now gets (checked by eye against misaki's own readings).
    static let table: [(text: String, phonemes: String)] = [
        // Numbers: plain words, no commas, misaki's 'hundred' and 'thousand'.
        ("The 1,250 people paid 300 dollars.", "ðə wˈʌn θˈWzᵊnd tˈu hˈʌndɹəd fˈɪfti pˈipᵊl pˈAd θɹˈi hˈʌndɹəd dˈɑləɹz."),
        ("She read chapter 21 on page 7.", "ʃi ɹˈid ʧˈæptəɹ twˈɛnti wˈʌn ˌɔn pˈAʤ sˈɛvən."),
        ("In 1990 and 2005 and 2024 they met.", "ɪn nˌIntˈin nˈIndi ænd tˈu θˈWzᵊnd fˈIv ænd tˈu θˈWzᵊnd twˈɛnti fˈɔɹ ðA mˈɛt."),
        ("It was the 1990s.", "ɪt wʌz ðə nˌIntˈin nˈIndiz."),
        ("It cost $12.50, then $1.2 billion.", "ɪt kˈɔst twˈɛlv dˈɑləɹz fˈɪfti, ðˈɛn wˈʌn pˈYnt tˈu bˈɪljən dˈɑləɹz."),
        ("The 3rd and 21st of June.", "ðə θˈɜɹd ænd twˈɛnti fˈɜɹst ʌv ʤˈun."),
        ("We left at 9:05 a.m. and came back at 11:45.", "wi lˈɛft æt nˈIn ˈO fˈIv ɐ ˈɛm ænd kˈAm bˈæk æt əlˈɛvᵊn fˈɔɹɾi fˈIv."),
        ("Up 61.3% to 1,000,000 units.", "ˌʌp sˈɪksti wˈʌn pˈYnt θɹˈi pəɹsˈɛnt tə wˈʌn mˈɪljᵊn jˈunəts."),
        ("It fell to -5 degrees.", "ɪt fˈɛl tə mˈInəs fˈIv dɪɡɹˈiz."),
        ("eighty-four people", "ˈAɾi fˈɔɹ pˈipᵊl"),
        // Abbreviations.
        ("Dr. Smith met Mr. Jones.", "dˈɑktəɹ smˈɪθ mˈɛt mˈɪstəɹ ʤˈOnz."),
        ("The U.S. and the U.K. signed it.", "ðə jˈu ˈɛs ænd ðə jˈu kˈA sˈInd ɪt."),
        ("NASA and PBS and km.", "nˈæsə ænd pˌibˌiˈɛs ænd kˌAˈɛm."),
        // Function words settled by the next word, and 'I'.
        ("She went to a hat shop to eat.", "ʃi wˈɛnt tʊ ɐ hˈæt ʃˈɑp tʊ ˈit."),
        ("The end of the apple, in an hour.", "ði ˈɛnd ʌv ði ˈæpᵊl, ɪn ɐn ˈWəɹ."),
        // Stems (silver-only words and plurals) and rare words (Kitten's front end).
        ("I negotiated with cats and bosses.", "ˌI nəɡˈOʃɪˌATəd wɪð kˈæts ænd bˈɔsᵻz."),
        ("Zorblax visited Reykjavik.", "zˈɔɹbəlks vˈɪzɪɾᵻd ɹˈAkjəvˌɪk."),
        ("The balearic coronavirus.", "ðə bˌæliˈɛɹɪk kəɹˈOnəvˌIɹəs."),
        // Unicode: accents fold, quotes and dashes stay, an unreadable script is dropped.
        ("Reykjavík café naïve résumé.", "ɹˈAkjəvˌɪk kæfˈA nɑˈiv ɹəzˈum."),
        ("He said \"hello\" — then left…", "hi sˈɛd “həlˈO”— ðˈɛn lˈɛft…"),
        ("日本語 and text.", "ænd tˈɛkst."),
    ]

    func testTheTableOfNeighbouringInputs() throws {
        let frontEnd = try misakiFrontEnd()
        for row in Self.table {
            XCTAssertEqual(frontEnd.phonemes(for: row.text), row.phonemes, row.text)
        }
    }

    // MARK: Each change on its own, so a row failing says which

    /// Misaki reads numbers as plain words. Kitten's commas and hand-spelled 'hundred' are Kitten's own fixes and
    /// must not reach Kokoro, which was never trained on them.
    func testNumbersAreReadWithoutKittensWorkarounds() throws {
        let text = "The 1,250 people paid 300 dollars."
        let kokoro = try misakiFrontEnd().phonemes(for: text)
        let before = try kittenFrontEnd().phonemes(for: text)
        XCTAssertFalse(kokoro.contains(","), "no comma after a scale word")
        XCTAssertTrue(before.contains(","), "the old path carried Kitten's commas")
        XCTAssertTrue(kokoro.contains("hˈʌndɹəd"), "misaki's 'hundred'")
        XCTAssertTrue(before.contains("hˈʌndɹɪd"), "Kitten's hand-written 'hundred'")
        XCTAssertNotEqual(kokoro, before)
    }

    func testKittenKeepsItsOwnNumberReading() {
        XCTAssertEqual(SpeechNormalizer.normalize("1,250"), "one thousand, two hundred, fifty")
        XCTAssertEqual(SpeechNormalizer.normalize("1,250", numbers: .misaki), "one thousand two hundred fifty")
    }

    /// A word only silver has still comes from the dictionary, not Kitten.
    func testSilverOnlyWordIsLookedUp() throws {
        let kokoro = try misakiFrontEnd().phonemes(for: "balearic")
        let before = try kittenFrontEnd().phonemes(for: "balearic")
        XCTAssertEqual(kokoro, "bˌæliˈɛɹɪk")
        XCTAssertNotEqual(kokoro, before)
    }

    /// A word in neither dictionary goes to Kitten's front end, respelled.
    func testWordInNeitherDictionaryFallsBackToKitten() throws {
        XCTAssertNil(MisakiFixture.gold["zorblax"])
        XCTAssertNil(MisakiFixture.silver["zorblax"])
        let kokoro = try misakiFrontEnd().phonemes(for: "Zorblax")
        let before = try kittenFrontEnd().phonemes(for: "Zorblax")
        XCTAssertEqual(kokoro, before)
        XCTAssertFalse(kokoro.isEmpty)
    }

    /// 'the' and 'to' follow the next word's first sound; 'a' and 'an' take misaki's schwa.
    func testFunctionWordsFollowTheNextSound() throws {
        let frontEnd = try misakiFrontEnd()
        XCTAssertEqual(frontEnd.phonemes(for: "the cat"), "ðə kˈæt")
        XCTAssertEqual(frontEnd.phonemes(for: "the end"), "ði ˈɛnd")
        XCTAssertEqual(frontEnd.phonemes(for: "to eat"), "tʊ ˈit")
        XCTAssertEqual(frontEnd.phonemes(for: "to hat"), "tə hˈæt")
    }

    func testEveryOutputSymbolIsInKokorosVocabulary() throws {
        let frontEnd = try misakiFrontEnd()
        let allowed = Set(Self.symbols + " ")
        for row in Self.table {
            for character in frontEnd.phonemes(for: row.text) {
                XCTAssertTrue(allowed.contains(character), "\(character) from \(row.text)")
            }
        }
    }
}
