import Foundation
import SessionKit
import SessionKitSupertonic

/// `speech-bench`: real-time factor of each bundled narration engine on the Mac (#849).
///
///     swift run -c release --package-path Packages/SessionKit speech-bench [--threads 2] [--chunks 12] [--out report.json]
///
/// Run from the repository root (it reads the models under `App/SpokenMarginsApp/Resources`). It renders the
/// same real article chunks, the ones the player plans, with Kitten (the fallback voice) and Supertonic, and
/// prints audio seconds per wall second for each, once warm, plus the first chunk's time including the model load.
/// The Mac is several times faster than an iPhone in Low Power Mode: compare engines with each other, and take
/// the phone's number from the in-app render pace line or VoiceBench (`research/C2/phone-bench`).

let sample = """
The committee met on Tuesday to discuss the proposal, which had been circulating among members for several weeks and had attracted a surprising amount of criticism from both sides. Most of the objections concerned cost. A smaller group worried that the timeline was unrealistic, given how many agencies would have to coordinate their efforts across three separate fiscal years. In the end, the chair suggested a compromise that nobody liked but everyone could tolerate; the vote passed narrowly, seven to six, after nearly four hours of debate. Reporters outside the building waited for hours. When the doors finally opened, several members declined to comment, and the few who did were careful to say only that the process had been fair. Analysts later noted that the measure, which would shift roughly 12% of the budget by 2031, faces a harder test in the second chamber. Supporters point to a 2019 pilot in which 91.4% of participants reported shorter waits, while opponents argue that the pilot's sites were not typical. Neither side expects a quick resolution, and both say they are preparing for a long autumn of hearings, amendments and, quite possibly, a court challenge that could delay everything by a year or more.
"""

struct EngineReport: Codable {
    var engine: String
    var chunks: Int
    var audioSeconds: Double
    var wallSeconds: Double
    var firstChunkSeconds: Double
    var firstChunkAudioSeconds: Double
    var warmRealTimeFactor: Double
    var firstChunkRealTimeFactor: Double
}

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

func measure(engine: String, chunks: [String], render: (String) async throws -> SupertonicNarrationResult) async throws -> EngineReport {
    var audio = 0.0, wall = 0.0, first = 0.0, firstAudio = 0.0, warmAudio = 0.0, warmWall = 0.0
    for (index, text) in chunks.enumerated() {
        let started = Date()
        let result = try await render(text)
        let elapsed = Date().timeIntervalSince(started)
        try? FileManager.default.removeItem(at: result.audioURL)
        audio += result.duration
        wall += elapsed
        if index == 0 {
            first = elapsed
            firstAudio = result.duration
        } else {
            warmAudio += result.duration
            warmWall += elapsed
        }
    }
    return EngineReport(
        engine: engine, chunks: chunks.count, audioSeconds: audio, wallSeconds: wall,
        firstChunkSeconds: first, firstChunkAudioSeconds: firstAudio,
        warmRealTimeFactor: warmWall > 0 ? warmAudio / warmWall : 0,
        firstChunkRealTimeFactor: first > 0 ? firstAudio / first : 0)
}

let threads = Int(argument("--threads") ?? "") ?? 2
let chunkCount = Int(argument("--chunks") ?? "") ?? 12
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "App/SpokenMarginsApp/Resources")
let output = FileManager.default.temporaryDirectory.appending(path: "speech-bench-\(UUID().uuidString)", directoryHint: .isDirectory)
defer { try? FileManager.default.removeItem(at: output) }

let plan = NarrationChunkPlanner.articlePlan(sample)
let all = plan.chunks.map(\.text)
let chunks = Array((all + all + all).prefix(chunkCount))
print("chunks: \(chunks.count) of \(all.count) distinct, \(chunks.map(\.count).reduce(0, +)) characters, kitten threads \(threads)")

var reports: [EngineReport] = []
do {
    let kitten = try KittenNarrationRenderer(
        assets: KittenAssetLocation(rootURL: root.appending(path: "Kitten")), outputDirectory: output, threads: threads)
    reports.append(try await measure(engine: "kitten", chunks: chunks) { try await kitten.render(text: $0) })
    // The fast-start head the player plays first after a fallback (a warm session).
    let head = NarrationChunkPlanner.splittingFirstChunk(
        of: plan.chunks.map { NarrationChunkPlanner.SpokenChunk(startOffset: $0.startOffset, sourceLength: $0.sourceLength, text: $0.text, boundary: $0.boundary, articleIndex: $0.index) },
        spokenText: plan.normalizedText, playheadOffset: 0)[0]
    let started = Date()
    let result = try await kitten.render(text: head.text)
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "kitten fast-start head: %d characters, %.1f s of audio in %.2f s (warm)", head.text.count, result.duration, elapsed))
    await kitten.unload()
} catch {
    print("kitten: skipped (\(error.localizedDescription))")
}
do {
    let supertonic = try SupertonicNarrationRenderer(
        assets: SupertonicAssetLocation(rootURL: root.appending(path: "Supertonic")), outputDirectory: output)
    reports.append(try await measure(engine: "supertonic", chunks: chunks) { try await supertonic.render(text: $0) })
    await supertonic.unload()
} catch {
    print("supertonic: skipped (\(error.localizedDescription))")
}
print("iOS voice: not measured here (AVSpeechSynthesizer runs on the phone; 14.3x on the owner's phone in C2 M2, #192)")

print("\nengine      chunks  audio s  wall s  warm RTF  first chunk s (audio s, RTF incl. load)")
for r in reports {
    print(String(format: "%@ %6d %8.1f %7.1f %8.1fx  %6.2f (%.1f s, %.1fx)", r.engine.padding(toLength: 11, withPad: " ", startingAt: 0), r.chunks, r.audioSeconds, r.wallSeconds,
                 r.warmRealTimeFactor, r.firstChunkSeconds, r.firstChunkAudioSeconds, r.firstChunkRealTimeFactor))
}
if let out = argument("--out") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(reports).write(to: URL(fileURLWithPath: out))
}
