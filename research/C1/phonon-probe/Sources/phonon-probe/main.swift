// phonon-probe <model folder> <voice> <input.json: [{"id","text"}]> <output dir>
// Renders each text exactly as the app does (Phonon.synthesize, English normalization) and writes a WAV and a line
// of stats per text to <output dir>/stats.jsonl. Nothing here is shipped.
import Foundation
import PhononTTS

struct Row: Decodable { var id: String; var text: String }

func wav(_ samples: [Float], rate: Int) -> Data {
    var pcm = Data(capacity: samples.count * 2)
    for sample in samples {
        var value = Int16(max(-1, min(1, sample)) * 32767).littleEndian
        withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
    }
    func u32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
    func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    var out = Data("RIFF".utf8) + u32(36 + pcm.count) + Data("WAVEfmt ".utf8) + u32(16) + u16(1) + u16(1)
    out += u32(rate) + u32(rate * 2) + u16(2) + u16(16) + Data("data".utf8) + u32(pcm.count) + pcm
    return out
}

let arguments = CommandLine.arguments
guard arguments.count == 5 else { fatalError("usage: phonon-probe <model> <voice> <input.json> <out dir>") }
let out = URL(fileURLWithPath: arguments[4], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
let phonon = try await Phonon.load(models: URL(fileURLWithPath: arguments[1], isDirectory: true), language: .english)
try await phonon.setVoice(arguments[2])
FileManager.default.createFile(atPath: out.appendingPathComponent("stats.jsonl").path, contents: nil)
let handle = try FileHandle(forWritingTo: out.appendingPathComponent("stats.jsonl"))
for row in rows {
    let samples = try await phonon.synthesize(row.text)
    try wav(samples, rate: 24_000).write(to: out.appendingPathComponent("\(row.id).wav"))
    let peak = samples.lazy.map { abs($0) }.max() ?? 0
    let line: [String: Any] = ["id": row.id, "seconds": Double(samples.count) / 24_000, "peak": Double(peak)]
    handle.write(try JSONSerialization.data(withJSONObject: line) + Data("\n".utf8))
}
