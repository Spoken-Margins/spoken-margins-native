import Foundation
import XCTest
@testable import SessionKitSpeechFrontEnd

/// The Swift front end for the bundled Kitten voice must say exactly what the Python reference
/// (`research/C2/frontend`) says: same normalized text, same phonemes, same Kitten ids. The vectors
/// are the reference's own output; the lexicon and weights are the files the app bundles.
final class KittenFrontEndTests: XCTestCase {
    private static let repositoryRoot: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }          // file, SessionKitCoreTests, Tests, SessionKit, Packages
        return root
    }()

    private static let resources = repositoryRoot.appending(path: "App/SpokenMarginsApp/Resources/Kitten")
    private static let reference = repositoryRoot.appending(path: "research/C2/frontend")

    private func frontEnd() throws -> KittenFrontEnd {
        try KittenFrontEnd(
            lexiconURL: Self.resources.appending(path: "lexicon.tsv"),
            g2pWeightsURL: Self.resources.appending(path: "g2p_weights.bin"),
            g2pManifestURL: Self.resources.appending(path: "g2p_weights.json")
        )
    }

    private func json(_ name: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.reference.appending(path: name)))
        return try XCTUnwrap(object as? [String: Any])
    }

    func testEverySentenceVectorReproducesNormalizedTextPhonemesAndIds() throws {
        let frontEnd = try frontEnd()
        let sentences = try XCTUnwrap(json("test_vectors.json")["sentences"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(sentences.count, 16)
        for vector in sentences {
            let text = try XCTUnwrap(vector["text"] as? String)
            XCTAssertEqual(SpeechNormalizer.normalize(text), vector["normalized"] as? String, "normalize: \(text)")
            XCTAssertEqual(frontEnd.phonemize(text), vector["phonemes"] as? String, "phonemes: \(text)")
            XCTAssertEqual(frontEnd.inputIDs(for: text).map(Int.init), vector["kitten_ids"] as? [Int], "ids: \(text)")
        }
    }

    func testWordVectorsAndFunctionWords() throws {
        let frontEnd = try frontEnd()
        let vectors = try json("test_vectors.json")
        let words = try XCTUnwrap(vectors["words"] as? [String: String])
        XCTAssertFalse(words.isEmpty)
        for (word, phonemes) in words { XCTAssertEqual(frontEnd.word(word), phonemes, word) }
        let function = try XCTUnwrap(vectors["function_words"] as? [String: String])
        XCTAssertEqual(function, FrontEndTables.functionWords)
    }

    /// Words by the path that pronounces them (dictionary, compound, neural net, spelled), and
    /// generated normalizer inputs, all from the reference's output.
    func testSeededWordsAndNormalizerInputsMatchTheReference() throws {
        let frontEnd = try frontEnd()
        let extra = try json("test_extra_vectors.json")
        let words = try XCTUnwrap(extra["words"] as? [String: String])
        XCTAssertGreaterThan(words.count, 400)
        for (word, phonemes) in words { XCTAssertEqual(frontEnd.word(word), phonemes, word) }
        let inputs = try XCTUnwrap(extra["normalized"] as? [String: String])
        XCTAssertGreaterThan(inputs.count, 200)
        for (text, normalized) in inputs { XCTAssertEqual(SpeechNormalizer.normalize(text), normalized, text) }
    }

    func testLexiconFindsFirstMiddleLastAndMissingWords() throws {
        let lexicon = try PronunciationLexicon(contentsOf: Self.resources.appending(path: "lexicon.tsv"))
        let lines = try String(contentsOf: Self.resources.appending(path: "lexicon.tsv"), encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }
        XCTAssertGreaterThan(lines.count, 100_000)
        for index in [0, 1, lines.count / 2, lines.count - 2, lines.count - 1] {
            XCTAssertEqual(lexicon.pronunciation(of: lines[index][0]), lines[index][1], lines[index][0])
        }
        XCTAssertNil(lexicon.pronunciation(of: ""))
        XCTAssertNil(lexicon.pronunciation(of: "zzzzzzzzzzzz"))
        XCTAssertNil(lexicon.pronunciation(of: "\u{0}"))
        XCTAssertNil(lexicon.pronunciation(of: "~~~"))
    }

    /// Identifiers read digit by digit past 18 digits, where a quantity can't be said usefully.
    func testHugeNumbersAreReadDigitByDigit() {
        XCTAssertEqual(SpeechNormalizer.normalize("ID 123456789012345678901."), "ID one two three four five six seven eight nine zero one two three four five six seven eight nine zero one.")
        XCTAssertEqual(SpeechNormalizer.normalize("the 100th"), "the one hundredth")
    }

    func testInputIDsFrameThePhonemesWithPadAndEllipsis() throws {
        let ids = try frontEnd().inputIDs(for: "Hello.")
        XCTAssertEqual(ids.first, 0)
        XCTAssertEqual(Array(ids.suffix(2)), [10, 0])
        XCTAssertGreaterThan(ids.count, 4)
    }
}
