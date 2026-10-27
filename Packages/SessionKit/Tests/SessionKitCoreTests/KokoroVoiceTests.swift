import Foundation
import SessionKit
import SessionKitSpeechFrontEnd
import SessionKitTestInputs
import XCTest

/// Kokoro-82M's host-testable parts (#2705): the catalog entry, the cutting into ≤ 7 s pieces, the seams,
/// the saved-audio identity, the front end's respelling and the preparer.
final class KokoroVoiceTests: XCTestCase {
    // MARK: Catalog entry

    private func kokoroEntry() throws -> VoiceModelEntry {
        let snapshot = try TestInputs.data(.voiceCatalogSnapshot, "catalog-snapshot.json")
        let catalog = try VoiceModelCatalog.decode(snapshot)
        return try XCTUnwrap(catalog.voices.first { $0.id == KokoroVoice.catalogId })
    }

    func testTheBundledSnapshotListsExactlyTheSevenSecondNeuralEngineSet() throws {
        let entry = try kokoroEntry()
        XCTAssertEqual(KokoroVoice.problems(withFiles: entry.files.map(\.path)), [])
        XCTAssertEqual(entry.runtime.name, VoiceModelCatalogVerifier.coreMLRuntime)
        XCTAssertEqual(entry.minimumChip, "A14")
        XCTAssertFalse(entry.bundled)
        // About 400 MB: the size Settings shows and the off-Wi-Fi ask is about.
        XCTAssertGreaterThan(entry.downloadByteCount, 390_000_000)
        XCTAssertLessThan(entry.downloadByteCount, 410_000_000)
        let lexiconPaths = [KokoroVoice.lexiconGoldPath, KokoroVoice.lexiconSilverPath]
        for file in entry.files where !file.path.hasPrefix("licenses/") && !lexiconPaths.contains(file.path) {
            XCTAssertEqual(file.sources, ["https://huggingface.co/mattmireles/kokoro-coreml/resolve/\(KokoroVoice.artifactRevision)/\(file.path)"], file.path)
        }
        // misaki's two dictionaries are required pieces, pinned to hexgrad/misaki commit e820629b by hash.
        for path in lexiconPaths {
            let file = try XCTUnwrap(entry.files.first { $0.path == path }, path)
            XCTAssertEqual(file.sources, ["https://raw.githubusercontent.com/hexgrad/misaki/e820629b96334db28227df37f280e4836d46fadb/misaki/data/\((path as NSString).lastPathComponent)"], path)
        }
        let notice = try XCTUnwrap(entry.files.first { $0.path == "licenses/NOTICE.txt" })
        XCTAssertTrue(notice.content?.contains("CC BY 4.0") == true, "the Kokoro card's CC BY training-data credit travels with the files")
        XCTAssertTrue(entry.files.contains { $0.path == "licenses/APACHE-2.0.txt" })
    }

    func testTheEntryRuleRejectsHybridLongBucketsAndMissingPieces() {
        var paths: [String] = []
        for package in KokoroVoice.modelPackages {
            for file in KokoroVoice.packageFiles {
                paths.append("coreml/\(package)/\(file)")
            }
        }
        for voice in KokoroVoice.voices {
            paths.append(KokoroVoice.voicePath(voice))
        }
        paths.append(KokoroVoice.vocabPath)
        paths.append(KokoroVoice.hnsfWeightsPath)
        paths.append(KokoroVoice.lexiconGoldPath)
        paths.append(KokoroVoice.lexiconSilverPath)
        XCTAssertEqual(KokoroVoice.problems(withFiles: paths), [])
        XCTAssertEqual(KokoroVoice.problems(withFiles: paths.filter { $0 != KokoroVoice.lexiconSilverPath }), ["missing lexicon/us_silver.json"])
        XCTAssertEqual(KokoroVoice.problems(withFiles: paths + ["coreml/hybrid/plan.json"]),
                       ["lists the hybrid GPU generator: coreml/hybrid/plan.json"])
        XCTAssertEqual(KokoroVoice.problems(withFiles: paths + ["coreml/kokoro_decoder_pre_15s.mlpackage/Manifest.json"]),
                       ["lists a file outside the 7-second set: coreml/kokoro_decoder_pre_15s.mlpackage/Manifest.json"])
        XCTAssertEqual(KokoroVoice.problems(withFiles: paths + ["g2p/g2p_vocab.json"]),
                       ["lists G2P assets the app does not use: g2p/g2p_vocab.json"])
        XCTAssertEqual(KokoroVoice.problems(withFiles: paths.filter { $0 != "voices/af_heart.bin" }), ["missing voices/af_heart.bin"])
        XCTAssertTrue(KokoroVoice.voices.contains(KokoroVoice.defaultVoice))
    }

    // MARK: Cutting

    func testSentencesAreGroupedUnderTheBudgetAndRejoinToTheText() {
        let planner = KokoroBucketPlanner()
        let text = "The fox ran. It was late, and the moon was up!  Dr. Smith said so. \"Really?\" she asked. J. R. R. Tolkien wrote it."
        let pieces = planner.pieces(for: text)
        XCTAssertEqual(pieces.map(\.text).joined(separator: " "), text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.text.count, planner.characterBudget, piece.text)
            XCTAssertEqual(piece.seamAfter, .sentence)
        }
        // "Dr." and the initials never end a sentence.
        XCTAssertFalse(pieces.contains { $0.text.hasSuffix("Dr.") || $0.text.hasSuffix("J.") })
    }

    func testANeighbourhoodOfAwkwardInputsAlwaysFitsTheBudget() {
        let planner = KokoroBucketPlanner()
        let long = String(repeating: "word ", count: 80)
        let inputs = [
            "", "   ", "Hi.", "No punctuation at all just words running on and on and on without stopping for breath ever again and again",
            "A very long sentence, with clauses; colons: and dashes — that keeps going, and going, until it is far longer than any single bucket could hold, which it must split.",
            long, "https://example.com/" + String(repeating: "a", count: 200), "Ünïcödé café naïve façade. Résumé.",
            "Wait… what?! Yes.", "Line one.\nLine two.\n\nLine three."
        ]
        for input in inputs {
            let pieces = planner.pieces(for: input)
            for piece in pieces {
                XCTAssertLessThanOrEqual(piece.text.count, planner.characterBudget, input)
                XCTAssertFalse(piece.text.isEmpty, input)
            }
            XCTAssertEqual(pieces.last?.seamAfter ?? .sentence, .sentence, input)
            let collapsed = input.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            XCTAssertEqual(pieces.map(\.text).joined(separator: " ").replacingOccurrences(of: " ", with: ""),
                           collapsed.replacingOccurrences(of: " ", with: ""), input)
        }
    }

    func testALongSentenceIsCutAtClausesBeforeWords() {
        let planner = KokoroBucketPlanner(budgetSeconds: 2)  // 28 characters
        let pieces = planner.pieces(for: "First part of it, second part of it, and a third part.")
        XCTAssertEqual(pieces.map(\.text), ["First part of it,", "second part of it,", "and a third part."])
        XCTAssertEqual(pieces.map(\.seamAfter), [.clause, .clause, .sentence])
    }

    func testFasterSpeechFitsMoreTextInOnePiece() {
        XCTAssertGreaterThan(KokoroBucketPlanner(speed: 2).characterBudget, KokoroBucketPlanner(speed: 1).characterBudget)
    }

    func testAnOverflowedPieceHalvesAtTheNearestClause() throws {
        let planner = KokoroBucketPlanner()
        let halves = try XCTUnwrap(planner.halve(.init(text: "one two three, four five six seven", seamAfter: .sentence)))
        XCTAssertEqual(halves.map(\.text), ["one two three,", "four five six seven"])
        XCTAssertEqual(halves.map(\.seamAfter), [.clause, .sentence])
        XCTAssertNil(planner.halve(.init(text: "single", seamAfter: .sentence)))
        XCTAssertTrue(KokoroBucketPlanner.mayHaveOverflowed(audioSeconds: 7.0, bucketSeconds: 7))
        XCTAssertFalse(KokoroBucketPlanner.mayHaveOverflowed(audioSeconds: 6.2, bucketSeconds: 7))
        XCTAssertFalse(KokoroBucketPlanner.mayHaveOverflowed(audioSeconds: 3.0, bucketSeconds: 3))
    }

    // MARK: Seams

    private func tone(_ count: Int, quietBefore: Int = 0, quietAfter: Int = 0) -> [Float] {
        let before: [Float] = [Float](repeating: 0, count: quietBefore)
        let body: [Float] = (0..<count).map { (index: Int) -> Float in
            let phase: Double = Double(index) * 0.1
            let wave: Float = Float(sin(phase))
            return wave * 0.4 + 0.5
        }
        let after: [Float] = [Float](repeating: 0.0005, count: quietAfter)
        return before + body + after
    }

    /// The longest run of quiet samples inside `samples`.
    private func longestQuietRun(_ samples: [Float]) -> Int {
        var longest = 0, run = 0
        for sample in samples {
            run = abs(sample) < KokoroSeamJoiner.quietLevel ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }

    func testSeamsReplaceTheModelsOwnQuietWithAFixedPause() {
        let rate = 24_000
        let a = tone(2_400, quietBefore: 500, quietAfter: 4_000)
        let b = tone(2_400, quietBefore: 6_000, quietAfter: 300)
        let sentence = KokoroSeamJoiner.join(segments: [a, b], seams: [.sentence, .sentence], sampleRate: rate)
        // Edges stay; the seam is exactly the sentence pause, however much quiet each piece carried.
        let pauseSamples: Int = Int(0.22 * Double(rate))
        let expectedCount: Int = 500 + 2_400 + pauseSamples + 2_400 + 300
        XCTAssertEqual(sentence.count, expectedCount)
        let inner: [Float] = Array(sentence[600..<(sentence.count - 400)])
        XCTAssertEqual(longestQuietRun(inner), pauseSamples)
        let clause = KokoroSeamJoiner.join(segments: [a, b], seams: [.clause, .sentence], sampleRate: rate)
        XCTAssertEqual(longestQuietRun(Array(clause[600..<(clause.count - 400)])), Int(0.10 * Double(rate)))
    }

    func testAWordSeamHasNoGapAndNoJump() {
        let a = tone(2_400, quietAfter: 3_000)
        let b = tone(2_400, quietBefore: 3_000)
        let joined = KokoroSeamJoiner.join(segments: [a, b], seams: [.word, .sentence])
        let overlap = Int(24_000 * KokoroSeamJoiner.crossfadeSeconds)
        XCTAssertEqual(joined.count, 2_400 * 2 - overlap)
        XCTAssertEqual(longestQuietRun(joined), 0)
        for i in 1..<joined.count { XCTAssertLessThan(abs(joined[i] - joined[i - 1]), 0.2, "a click at \(i)") }
    }

    func testEmptyPiecesAreSkipped() {
        XCTAssertEqual(KokoroSeamJoiner.join(segments: [], seams: []), [])
        XCTAssertEqual(KokoroSeamJoiner.join(segments: [[], tone(10)], seams: [.word, .sentence]).count, 10)
    }

    // MARK: Identity (#64)

    func testEachVoiceHasItsOwnIdentityAndTheCatalogGivesItWithoutFiles() throws {
        let entry = try kokoroEntry()
        let heart = try XCTUnwrap(KokoroRenderSignature.make(voice: "af_heart", entry: entry))
        let george = try XCTUnwrap(KokoroRenderSignature.make(voice: "bm_george", entry: entry))
        XCTAssertEqual(heart.engine, "kokoro")
        XCTAssertNotEqual(heart.digest, george.digest)
        XCTAssertNotEqual(heart.voiceStyleHash, george.voiceStyleHash)
        XCTAssertEqual(heart.assetManifestHash, george.assetManifestHash)
        XCTAssertEqual(heart, KokoroRenderSignature.make(voice: "af_heart", entry: entry))
        XCTAssertNotEqual(heart.digest, KokoroRenderSignature.make(voice: "af_heart", entry: entry, speed: 1.2)?.digest)
        XCTAssertNil(KokoroRenderSignature.make(voice: "zz_nobody", entry: entry))
        XCTAssertTrue(heart.chunkingVersion.contains(KokoroBucketPlanner.version))
    }

    // MARK: Front end

    func testEspeakSpellingsBecomeMisakis() {
        XCTAssertEqual(KokoroFrontEnd.misaki(fromEspeak: "həlˈoʊ"), "həlˈO")
        XCTAssertEqual(KokoroFrontEnd.misaki(fromEspeak: "tˈaɪm nˈaʊ bˈɔɪ dˈeɪ"), "tˈIm nˈW bˈY dˈA")
        XCTAssertEqual(KokoroFrontEnd.misaki(fromEspeak: "dʒˈʌdʒ tʃˈɜːtʃ"), "ʤˈʌʤ ʧˈɜɹʧ")
        XCTAssertEqual(KokoroFrontEnd.misaki(fromEspeak: "wˈɔːɾɚ"), "wˈɔTəɹ")
        XCTAssertEqual(KokoroFrontEnd.misaki(fromEspeak: "sˈiː"), "sˈi")
    }

    func testInputIsFramedPaddedAndPicksTheStyleRow() throws {
        let vocab = Data(#"{"vocab": {" ": 16, "h": 50, "ə": 83, "l": 54, "O": 31, "ˈ": 156, ".": 4}}"#.utf8)
        let frontEnd = try KokoroFrontEnd(vocabJSON: vocab) { _ in "həlˈoʊ." }
        let input = try XCTUnwrap(frontEnd.input(for: "Hello.", paddedLength: 16))
        XCTAssertEqual(Array(input.inputIds.prefix(8)), [0, 50, 83, 54, 156, 31, 4, 0])
        XCTAssertEqual(input.inputIds.count, 16)
        XCTAssertEqual(input.attentionMask, [Int32](repeating: 1, count: 8) + [Int32](repeating: 0, count: 8))
        XCTAssertEqual(input.tokenCount, 8)
        XCTAssertEqual(input.styleRow, "həlˈO.".utf16.count - 1)
        // Too long for the duration shape, or nothing to say: no input.
        XCTAssertNil(frontEnd.input(for: "Hello.", paddedLength: 7))
        let silent = try KokoroFrontEnd(vocabJSON: vocab) { _ in "   " }
        XCTAssertNil(silent.input(for: "…"))
    }

    func testTheRealKittenLexiconGivesKokoroTokensItKnows() throws {
        let assets = try TestInputs.directory(.voiceAssets)
        let kitten = try KittenFrontEnd(lexiconURL: assets.appending(path: "lexicon.tsv"),
                                        g2pWeightsURL: assets.appending(path: "g2p_weights.bin"),
                                        g2pManifestURL: assets.appending(path: "g2p_weights.json"))
        // Kokoro's vocabulary symbols (the port's runtime/kokoro-vocab.json keys).
        var symbols = Set(";:,.!?—…\"()“”ʣʥʦʨᵝꭧAIOQSTWYᵊabcdefhijklmnopqrstuvwxyzɑɐɒæβɔɕçɖðʤəɚɛɜɟɡɥɨɪʝɯɰŋɳɲɴøɸθœɹɾɻʁɽʂʃʈʧʊʋʌɣɤχʎʒʔˈˌːʰʲ↓→↗↘ᵻ")
        symbols.insert(" ")  // apart: a space before U+0303 would join it into one character
        symbols.insert("\u{0303}")
        let sentence = "The quick brown fox jumps over the lazy dog, while the church judge watches the water."
        let phonemes = KokoroFrontEnd.misaki(fromEspeak: kitten.phonemize(sentence))
        let unknown = phonemes.filter { !symbols.contains($0) }
        XCTAssertEqual(String(unknown), "", "phonemes Kokoro has no token for: \(phonemes)")
        XCTAssertFalse(phonemes.contains("ː"), "American Kokoro spells no length marks")
    }

    // MARK: Preparing (#2700)

    func testThePreparerCompilesEveryPackageIntoTheVoicesFolderAndStartsClean() async throws {
        let entry = try kokoroEntry()
        let folder = FileManager.default.temporaryDirectory.appending(path: "kokoro-prepare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let stale = folder.appending(path: "compiled/kokoro_decoder_pre_3s.mlmodelc/half-written")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "kokoro-compile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let compiledNames = LockedNames()
        let preparer = KokoroModelPreparer { package in
            compiledNames.append(package.lastPathComponent)
            let out = scratch.appending(path: UUID().uuidString + ".mlmodelc")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try Data(package.lastPathComponent.utf8).write(to: out.appending(path: "source"))
            return out
        }
        XCTAssertTrue(preparer.needsPreparation)
        try await preparer.prepare(stagedFolder: folder, entry: entry)
        XCTAssertEqual(compiledNames.names.sorted(), KokoroVoice.modelPackages.sorted())
        let compiled = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "compiled").path).sorted()
        let expectedCompiled: [String] = KokoroVoice.modelPackages
            .map { (name: String) -> String in name.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc") }
            .sorted()
        XCTAssertEqual(compiled, expectedCompiled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a failed attempt's leftovers are cleared first")
    }
}

private final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var names: [String] { lock.withLock { stored } }
    func append(_ name: String) { lock.withLock { stored.append(name) } }
}
