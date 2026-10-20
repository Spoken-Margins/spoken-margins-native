import AVFoundation
import Foundation
import SessionKit
import SessionKitSupertonic

/// `tour-render`: renders the guided tour clip with the bundled Kitten voice (#2051).
///
///     swift run -c release --package-path Packages/SessionKit tour-render \
///         --kitten App/SpokenMarginsApp/Resources/Kitten --text Site/onboarding/v1/guided-tour.txt --out <file.m4a>
///
/// The tour used to be read by an iOS system voice, whose audio Apple doesn't let us redistribute. Kitten is
/// Apache-2.0 and ships in the app, so its output can be published. The text is split the way the player splits
/// an article, each chunk is rendered as the app would render it, and the chunks are joined with a short pause
/// into one AAC file. `scripts/render-guided-tour.sh` wraps this and prints the manifest's checksum.

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

guard let kittenPath = argument("--kitten"), let textPath = argument("--text"), let outPath = argument("--out") else {
    FileHandle.standardError.write(Data("usage: tour-render --kitten <voice folder> --text <script.txt> --out <file.m4a> [--pause 0.35]\n".utf8))
    exit(2)
}
let pause = argument("--pause").flatMap(Double.init) ?? 0.35

let text = try String(contentsOfFile: textPath, encoding: .utf8)
let chunks = NarrationChunkPlanner.articlePlan(text).chunks.map(\.text)
let scratch = FileManager.default.temporaryDirectory.appending(path: "tour-render-\(UUID().uuidString)", directoryHint: .isDirectory)
defer { try? FileManager.default.removeItem(at: scratch) }
let kitten = try KittenNarrationRenderer(
    assets: KittenAssetLocation(rootURL: URL(fileURLWithPath: kittenPath, isDirectory: true)),
    outputDirectory: scratch, governor: OnDeviceVoiceGovernor())

var samples: [Float] = []
var sampleRate = 24_000.0
for (index, chunk) in chunks.enumerated() {
    let result = try await kitten.render(text: chunk, pacing: .whenAppBackgrounded)
    let file = try AVAudioFile(forReading: result.audioURL)
    sampleRate = file.processingFormat.sampleRate
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { exit(1) }
    try file.read(into: buffer)
    if index > 0 { samples += Array(repeating: 0, count: Int(pause * sampleRate)) }
    samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
    print(String(format: "chunk %d: %.2f s", index + 1, result.duration))
}
await kitten.unload()

let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
let joined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
joined.frameLength = AVAudioFrameCount(samples.count)
samples.withUnsafeBufferPointer { joined.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: outURL)
do {
    let output = try AVAudioFile(forWriting: outURL, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
    ])
    try output.write(from: joined)
}
print(String(format: "wrote %@: %d chunks, %.2f s", outPath, chunks.count, Double(samples.count) / sampleRate))
