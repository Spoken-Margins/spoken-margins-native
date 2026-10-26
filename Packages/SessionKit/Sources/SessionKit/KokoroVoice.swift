#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// Kokoro-82M on Core ML (#2705), the parts that need no Core ML and no model files: which files the voice is,
// how text is cut so every piece fits the 7-second buckets, how the pieces are joined, and the identity saved
// audio is filed under. The app's `KokoroNarrationRenderer` runs the model; everything here is host-tested.

/// The downloadable Kokoro voice as the catalog lists it.
public enum KokoroVoice {
    /// Catalog id (Default taken on #2705).
    public static let catalogId = "kokoro-82m"
    /// The port's commit (`mattmireles/kokoro-coreml`) whose Swift pipeline the app links, and the Hugging Face
    /// revision the model files are pinned to. The two belong together: the files were built for that commit.
    public static let sdkCommit = "e8bf3d4e80d7dd30ed58e343c1527fad09cc9d1f"
    public static let artifactRevision = "0c1d78b47d19f39be6bc0cf0d07316822ae879d4"
    /// The only buckets downloaded: at most 7 seconds of audio per inference keeps an A14 near the port's
    /// measured 282 MB peak (831 MB at 30 s), and both run all-Neural-Engine, so nothing touches the GPU,
    /// which iOS refuses in the background.
    public static let bucketSeconds = [3, 7]
    /// Frames the F0/N stage takes per bucket (the port's `tFramesForBucket`).
    public static let f0FramesForBucket = [3: 120, 7: 280]
    /// The one padded duration shape shipped: 128 tokens including the two boundary tokens.
    public static let durationTokenLength = 128
    public static let sampleRate = 24_000
    /// The compiled Core ML copies, inside the voice's folder so Remove deletes them (#2700).
    public static let compiledFolderName = "compiled"
    /// Where the `.mlpackage` folders sit inside the voice's folder.
    public static let modelsFolderName = "coreml"

    /// Default voice until the owner's listen picks one (#2705 owner check): `af_heart`, the voice the port
    /// and upstream Kokoro default to and grade highest among the American voices.
    public static let defaultVoice = "af_heart"

    /// The 28 English voices the port ships (American and British, female and male).
    public static let voices: [String] = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore", "af_nicole", "af_nova",
        "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis"
    ]

    /// The model packages the ≤ 7 s, Neural-Engine-only set needs: the split duration pair, the split F0/N
    /// pair per bucket, the decoder front per bucket, and the folded generator in both variants (plain for
    /// A17 and newer, polynomial-sine for older Neural Engines; the pipeline picks per device).
    public static let modelPackages: [String] = {
        var names = ["kokoro_duration_ane_front_t128", "kokoro_duration_back_t128"]
        for bucket in bucketSeconds {
            let frames = f0FramesForBucket[bucket] ?? 0
            names += ["kokoro_f0ntrain_front_t\(frames)", "kokoro_f0ntrain_ane_back_t\(frames)",
                      "kokoro_decoder_pre_\(bucket)s", "kokoro_generator_fold_\(bucket)s",
                      "kokoro_generator_fold_poly_\(bucket)s"]
        }
        return names.map { $0 + ".mlpackage" }
    }()

    /// The files each `.mlpackage` holds.
    public static let packageFiles = ["Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin", "Manifest.json"]
    public static let vocabPath = "runtime/kokoro-vocab.json"
    public static let hnsfWeightsPath = "runtime/hnsf_weights.json"

    public static func voicePath(_ voice: String) -> String { "voices/\(voice).bin" }

    /// What a catalog entry for this voice must list and must not: every file of every package above, every
    /// voice, the two runtime assets; no hybrid (GPU) generator, no bucket over 7 s, no G2P assets (the app
    /// reads text with its own front end). Empty when the entry is right.
    public static func problems(withFiles paths: [String]) -> [String] {
        var problems: [String] = []
        let listed = Set(paths)
        var expected: Set<String> = [vocabPath, hnsfWeightsPath]
        for package in modelPackages {
            for file in packageFiles { expected.insert("\(modelsFolderName)/\(package)/\(file)") }
        }
        for voice in voices { expected.insert(voicePath(voice)) }
        for missing in expected.subtracting(listed).sorted() { problems.append("missing \(missing)") }
        for path in listed.subtracting(expected).sorted() {
            guard !path.hasPrefix("licenses/") else { continue }
            if path.contains("/hybrid/") || path.hasPrefix("\(modelsFolderName)/hybrid") {
                problems.append("lists the hybrid GPU generator: \(path)")
            } else if path.hasPrefix("g2p/") {
                problems.append("lists G2P assets the app does not use: \(path)")
            } else {
                problems.append("lists a file outside the 7-second set: \(path)")
            }
        }
        return problems
    }
}

// MARK: - Cutting text into bucket-sized pieces

/// Cuts text into pieces short enough for one 7-second inference, at sentence seams first.
///
/// The model predicts its own durations and the pipeline then picks the smallest bucket that holds them; a piece
/// that predicts more than 7 s is cut off at the end of the largest bucket. So the budget is set under 7 s from a
/// character rate (the port's chunker uses 14 characters a second), and the renderer re-cuts a piece whose
/// audio still fills the bucket (`KokoroBucketPlanner.mayHaveOverflowed`).
public struct KokoroBucketPlanner: Equatable, Sendable {
    public enum Seam: String, Equatable, Sendable {
        /// Between sentences, or after the last piece.
        case sentence
        /// Inside a long sentence, at a comma, semicolon, colon or dash.
        case clause
        /// Inside a long clause, between words.
        case word
    }

    public struct Piece: Equatable, Sendable {
        public var text: String
        /// What follows this piece; `.sentence` for the last one.
        public var seamAfter: Seam

        public init(text: String, seamAfter: Seam) {
            self.text = text
            self.seamAfter = seamAfter
        }
    }

    /// Changes whenever the cutting changes, so saved audio cut the old way is not reused (#64).
    public static let version = "kokoro-buckets.v1"
    public static let charactersPerSecond = 14.0
    /// Seconds of speech a piece aims for at speed 1. Under 7 s, so a slow sentence still fits the bucket.
    public static let defaultBudgetSeconds = 5.5

    public var budgetSeconds: Double
    public var speed: Double

    public init(budgetSeconds: Double = KokoroBucketPlanner.defaultBudgetSeconds, speed: Double = 1) {
        self.budgetSeconds = max(0.5, budgetSeconds)
        self.speed = max(0.25, speed)
    }

    /// Characters a piece may hold.
    public var characterBudget: Int { max(8, Int(budgetSeconds * Self.charactersPerSecond * speed)) }

    public func estimatedSeconds(_ text: String) -> Double {
        Double(text.count) / (Self.charactersPerSecond * speed)
    }

    /// The pieces, in order. Whole sentences are grouped while they fit; a sentence over budget is cut at clause
    /// marks, then between words. Joining the pieces' text with single spaces gives back the text with its
    /// whitespace collapsed.
    public func pieces(for text: String) -> [Piece] {
        let collapsed = Self.collapseWhitespace(text)
        guard !collapsed.isEmpty else { return [] }
        var pieces: [Piece] = []
        var group = ""
        func flushGroup() {
            if !group.isEmpty { pieces.append(Piece(text: group, seamAfter: .sentence)) }
            group = ""
        }
        for sentence in Self.sentences(in: collapsed) {
            if sentence.count > characterBudget {
                flushGroup()
                pieces += split(sentence, seam: .clause)
                continue
            }
            let joined = group.isEmpty ? sentence : group + " " + sentence
            if joined.count <= characterBudget {
                group = joined
            } else {
                flushGroup()
                group = sentence
            }
        }
        flushGroup()
        return pieces
    }

    /// Cuts an over-budget span at clause marks (or, at `.word`, between words); the last piece keeps `.sentence`.
    func split(_ span: String, seam: Seam) -> [Piece] {
        let parts = seam == .clause ? Self.clauses(in: span) : span.split(separator: " ").map(String.init)
        var pieces: [Piece] = []
        var current = ""
        for part in parts {
            if part.count > characterBudget {
                if !current.isEmpty { pieces.append(Piece(text: current, seamAfter: seam)); current = "" }
                if seam == .clause {
                    pieces += split(part, seam: .word).map { Piece(text: $0.text, seamAfter: $0.seamAfter == .sentence ? .clause : $0.seamAfter) }
                } else {
                    // A single word longer than the budget (a URL, a run of digits): cut it by characters.
                    var rest = Substring(part)
                    while rest.count > characterBudget {
                        pieces.append(Piece(text: String(rest.prefix(characterBudget)), seamAfter: .word))
                        rest = rest.dropFirst(characterBudget)
                    }
                    current = String(rest)
                }
                continue
            }
            let joined = current.isEmpty ? part : current + " " + part
            if joined.count <= characterBudget {
                current = joined
            } else {
                pieces.append(Piece(text: current, seamAfter: seam))
                current = part
            }
        }
        if !current.isEmpty { pieces.append(Piece(text: current, seamAfter: seam)) }
        if !pieces.isEmpty { pieces[pieces.count - 1].seamAfter = .sentence }
        return pieces
    }

    /// Halves a piece the model overflowed, at the clause or word nearest its middle. Nil when it can't be cut.
    public func halve(_ piece: Piece) -> [Piece]? {
        let words = piece.text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return nil }
        let clauseEnds = words.indices.dropLast().filter { Self.endsClause(words[$0]) }
        let middle = words.count / 2
        let cut = clauseEnds.min { abs($0 + 1 - middle) < abs($1 + 1 - middle) }.map { $0 + 1 } ?? middle
        let seam: Seam = clauseEnds.contains(cut - 1) ? .clause : .word
        return [Piece(text: words[..<cut].joined(separator: " "), seamAfter: seam),
                Piece(text: words[cut...].joined(separator: " "), seamAfter: piece.seamAfter)]
    }

    /// True when a render's audio reached the end of the largest bucket, the sign the pipeline cut it off.
    public static func mayHaveOverflowed(audioSeconds: Double, bucketSeconds: Int) -> Bool {
        bucketSeconds >= (KokoroVoice.bucketSeconds.last ?? 7) && audioSeconds >= Double(bucketSeconds) - 0.05
    }

    // MARK: Text

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "sr.", "jr.", "vs.", "etc.", "e.g.", "i.e.", "no.", "fig.",
        "inc.", "ltd.", "co.", "mt.", "jan.", "feb.", "aug.", "sept.", "oct.", "nov.", "dec."
    ]

    /// Sentences of single-spaced text: a word ending in . ! ? (or that and a closing quote or bracket) ends one,
    /// unless it is a known abbreviation or a single initial ("J.").
    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current: [Substring] = []
        for word in text.split(separator: " ") {
            current.append(word)
            if endsSentence(String(word)) {
                sentences.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { sentences.append(current.joined(separator: " ")) }
        return sentences
    }

    static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]»"))
        guard let last = trimmed.last, ".!?…".contains(last) else { return false }
        if last == "." {
            let lower = trimmed.lowercased()
            if abbreviations.contains(lower) { return false }
            let letters = trimmed.dropLast()
            if letters.count == 1, letters.first?.isLetter == true { return false }
        }
        return true
    }

    static func endsClause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",;:—–".contains(last) || word == "-" || word == "—" || word == "–"
    }

    static func clauses(in sentence: String) -> [String] {
        var clauses: [String] = []
        var current: [Substring] = []
        for word in sentence.split(separator: " ") {
            current.append(word)
            if endsClause(String(word)) {
                clauses.append(current.joined(separator: " "))
                current = []
            }
        }
        if !current.isEmpty { clauses.append(current.joined(separator: " ")) }
        return clauses
    }
}

// MARK: - Joining the pieces

/// Joins rendered pieces so the seams can't be heard: the model's own leading and trailing quiet is trimmed at
/// every inner seam and replaced by a fixed pause that fits the seam (a sentence break, a clause break, nothing
/// between words), with a short equal-power crossfade where there is no pause so the join never clicks.
public enum KokoroSeamJoiner {
    /// Below this level a sample counts as quiet (about −54 dBFS).
    public static let quietLevel: Float = 0.002
    public static let crossfadeSeconds = 0.005

    public static func pauseSeconds(_ seam: KokoroBucketPlanner.Seam) -> Double {
        switch seam {
        case .sentence: 0.22
        case .clause: 0.10
        case .word: 0
        }
    }

    /// `seams[i]` is what follows `segments[i]`; the last one is ignored. Edges of the whole run are left alone.
    public static func join(segments: [[Float]], seams: [KokoroBucketPlanner.Seam], sampleRate: Int = KokoroVoice.sampleRate) -> [Float] {
        let pieces = segments.enumerated().compactMap { index, samples -> (samples: [Float], seam: KokoroBucketPlanner.Seam)? in
            samples.isEmpty ? nil : (samples, index < seams.count ? seams[index] : .sentence)
        }
        guard var output = pieces.first?.samples else { return [] }
        let fade = max(1, Int(Double(sampleRate) * crossfadeSeconds))
        for index in 1..<max(1, pieces.count) where pieces.count > 1 {
            let seam = pieces[index - 1].seam
            output.removeLast(trailingQuietCount(output))
            var next = pieces[index].samples
            next.removeFirst(leadingQuietCount(next))
            if next.isEmpty { continue }
            let pause = Int(Double(sampleRate) * pauseSeconds(seam))
            if pause > 0 {
                output += [Float](repeating: 0, count: pause)
                output += next
            } else {
                let overlap = min(fade, output.count, next.count)
                let start = output.count - overlap
                for i in 0..<overlap {
                    let t = Double(i + 1) / Double(overlap + 1)
                    output[start + i] = output[start + i] * Float(cos(t * .pi / 2)) + next[i] * Float(sin(t * .pi / 2))
                }
                output += next.dropFirst(overlap)
            }
        }
        return output
    }

    static func leadingQuietCount(_ samples: [Float]) -> Int {
        samples.firstIndex { abs($0) >= quietLevel } ?? samples.count
    }

    static func trailingQuietCount(_ samples: [Float]) -> Int {
        guard let last = samples.lastIndex(where: { abs($0) >= quietLevel }) else { return samples.count }
        return samples.count - 1 - last
    }
}

// MARK: - Saved audio's identity (#64)

/// The identity Kokoro's saved audio is filed under: the model revision, a hash over every model file's pinned
/// SHA-256, the chosen voice's file hash, the speed, and the cutting and text pipeline versions. Each voice gets
/// its own identity, so audio rendered in one voice never plays for another, and the hashes come from the catalog,
/// so saved audio keeps its identity before a download and after a Remove.
public enum KokoroRenderSignature {
    public static let engine = "kokoro"
    public static let modelRevision = "kokoro-82m-coreml@\(KokoroVoice.artifactRevision.prefix(8))"
    /// Bump when the text front end changes what it says.
    public static let normalizationVersion = "kokoro-frontend.v1"

    /// `files` is the catalog entry's file list (path, SHA-256). Nil when it doesn't carry `voice`.
    public static func make(voice: String, files: [(path: String, sha256: String)], speed: Float = 1) -> TTSRenderSignature? {
        guard let voiceHash = files.first(where: { $0.path == KokoroVoice.voicePath(voice) })?.sha256 else { return nil }
        let modelFiles = files.filter { !$0.path.hasPrefix("voices/") && !$0.path.hasPrefix("licenses/") }
            .sorted { $0.path < $1.path }
        let assetHash = sha256(modelFiles.map { "\($0.path)\u{0}\($0.sha256)" }.joined(separator: "\n"))
        let parameters = sha256("voice=\(voice)\u{1f}speed=\(speed)\u{1f}buckets=\(KokoroVoice.bucketSeconds.map(String.init).joined(separator: ","))")
        let chunking = "\(KokoroBucketPlanner.version)+\(NarrationChunkPlanner.version)"
        let canonical = [modelRevision, assetHash, voiceHash, parameters, normalizationVersion, chunking, "prepared-audio-manifest.v2"]
            .joined(separator: "\u{1f}")
        return TTSRenderSignature(
            engine: engine,
            modelRevision: modelRevision,
            assetManifestHash: assetHash,
            voiceStyleHash: voiceHash,
            synthesisParametersHash: parameters,
            normalizationVersion: normalizationVersion,
            chunkingVersion: chunking,
            digest: sha256(canonical)
        )
    }

    public static func make(voice: String, entry: VoiceModelEntry, speed: Float = 1) -> TTSRenderSignature? {
        make(voice: voice, files: entry.files.map { ($0.path, $0.sha256) }, speed: speed)
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The rendered file

/// 16-bit mono PCM WAV for a rendered piece of narration, clamped to full scale.
public enum KokoroWaveFile {
    public static func data(samples: [Float], sampleRate: Int = KokoroVoice.sampleRate) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + payload)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(payload)
        for sample in samples {
            let clamped = sample.isFinite ? max(-1, min(1, sample)) : 0
            append(Int16((clamped * Float(Int16.max)).rounded()))
        }
        return data
    }
}

// MARK: - Asking before a large download off Wi-Fi

/// When Settings › Voices asks before a voice downloads (#2705): on a network iOS marks expensive (cellular, a
/// personal hotspot) or constrained (Low Data Mode), for a voice of at least `threshold` bytes. Kokoro is about
/// 400 MB, Supertonic about 150 MB; both ask. On Wi-Fi nothing asks.
public enum VoiceDownloadNetworkRule {
    public static let threshold: Int64 = 50_000_000

    public static func asksFirst(byteCount: Int64, isExpensive: Bool, isConstrained: Bool) -> Bool {
        (isExpensive || isConstrained) && byteCount >= threshold
    }
}
