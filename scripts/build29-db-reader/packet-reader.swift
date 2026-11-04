// Compiled against a shipped build's SessionKit and SessionKitSharing (Build 29, 32 or 34, from its
// testflight/0.1-build-N tag) by scripts/check-build29-database.sh (#1900). Imports every packet the current
// code's exporter tests wrote into an empty in-memory Library, the way that build's importer does, and checks it
// decoded every Margin the packet carries. Arguments: the folder of packets, then the build's name ("Build 34").
// Each packet has a `<packet>.expected.json` beside it: {"margins": [ids] or null} (ShippedReaderRoundTrip.swift),
// plus `"voicesMustPlay": true` when the packet carries real audio: then every voice it extracted must also play
// the way that build plays it (voice-playback.swift, #3218).

import Foundation
import SessionKit
import SessionKitSharing

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let build = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Build 29"
let packets: [URL]
do {
    packets = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "spokenmargins" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
} catch {
    FileHandle.standardError.write(Data("FAIL no packets folder at \(folder.path): \(error)\n".utf8))
    exit(1)
}

var failures: [String] = []
var played = 0
for packet in packets {
    let name = packet.lastPathComponent
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("shipped-packets-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    do {
        let sidecar = try Data(contentsOf: packet.appendingPathExtension("expected.json"))
        let sidecarFields = try JSONSerialization.jsonObject(with: sidecar) as? [String: Any]
        let expected = sidecarFields?["margins"] as? [String]
        let voicesMustPlay = sidecarFields?["voicesMustPlay"] as? Bool ?? false
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let contents = try SpokenMarginsPackageArchive.read(from: packet, extractingAssetsTo: scratch)
        let disposition = try SpokenMarginsPackageImporter.importPackage(contents, repository: InMemorySessionRepository())
        guard case .imported = disposition else {
            failures.append("\(name): not imported (\(disposition))")
            continue
        }
        let read = contents.commentaryLayers.flatMap { $0.interjections.map(\.packageScopedId) }.sorted()
        if let expected, expected != read {
            failures.append("\(name): sent Margins \(expected), \(build) read \(read)")
        }
        if voicesMustPlay {
            played += 1
            let voices = contents.manifest.assets.filter { $0.mimeType.hasPrefix("audio/") }
            if voices.isEmpty { failures.append("\(name): marked voicesMustPlay but carries no voice") }
            for voice in voices {
                guard let extracted = contents.extractedAssetURLs[voice.id] else {
                    failures.append("\(name): \(voice.path) was not extracted")
                    continue
                }
                if let problem = await voicePlaybackProblem(at: extracted, expectedMs: voice.durationMs) {
                    failures.append("\(name): \(voice.path) does not play (\(problem))")
                }
            }
        }
    } catch {
        failures.append("\(name): \(error)")
    }
}

for failure in failures {
    FileHandle.standardError.write(Data("FAIL \(build) could not import \(failure)\n".utf8))
}
guard failures.isEmpty else { exit(1) }
guard !packets.isEmpty else {
    FileHandle.standardError.write(Data("FAIL no packets to read in \(folder.path)\n".utf8))
    exit(1)
}
// The real-encoder test marks its packets (SharedMarginAudioCompressionTests, #3218); none arriving means the
// playback check silently stopped running, not that every voice plays.
guard played > 0 else {
    FileHandle.standardError.write(Data("FAIL no packet asked \(build) to play its voices (voicesMustPlay)\n".utf8))
    exit(1)
}
print("ok   \(build) imported all \(packets.count) packets the current exporter tests wrote, every Margin intact, \(played) with voices played")
