import AVFoundation
import Foundation
import MediaToolbox

// usage: measure <baseURL> <file> <precise 0|1>
// File is a sweep: instantaneous frequency = 300 + 2*t Hz, so a window's dominant frequency says which second it came from.

final class Capture: @unchecked Sendable {
    let lock = NSLock()
    var armed = false
    var samples: [Float] = []
    var sampleRate = 44100.0
    func take() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
    func arm() { lock.lock(); samples = []; armed = true; lock.unlock() }
    func disarm() { lock.lock(); armed = false; lock.unlock() }
    func append(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        guard armed, samples.count < Int(sampleRate), frames > 0 else { return }
        let abl = UnsafeMutableAudioBufferListPointer(list)
        guard let first = abl.first, let data = first.mData else { return }
        let channels = max(Int(first.mNumberChannels), 1)
        let ptr = data.assumingMemoryBound(to: Float.self)
        if abl.count == 1 && channels > 1 {
            for i in 0..<frames { samples.append(ptr[i * channels]) }
        } else {
            for i in 0..<frames { samples.append(ptr[i]) }
        }
    }
}

func makeTap(_ capture: Capture) -> MTAudioProcessingTap {
    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: Unmanaged.passRetained(capture).toOpaque(),
        init: { _, info, out in out.pointee = info },
        finalize: { tap in Unmanaged<Capture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
        prepare: { tap, _, format in
            Unmanaged<Capture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().sampleRate = format.pointee.mSampleRate
        },
        unprepare: nil,
        process: { tap, frames, _, list, framesOut, flagsOut in
            var flags = MTAudioProcessingTapFlags()
            var range = CMTimeRange.invalid
            var got: CMItemCount = 0
            let status = MTAudioProcessingTapGetSourceAudio(tap, frames, list, &flags, &range, &got)
            guard status == noErr else { framesOut.pointee = 0; return }
            framesOut.pointee = got
            flagsOut.pointee = flags
            Unmanaged<Capture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().append(list, frames: Int(got))
        }
    )
    var tap: MTAudioProcessingTap?
    MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
    return tap!
}

func impliedSeconds(_ s: [Float], rate: Double) -> Double? {
    let n = min(s.count, Int(rate * 0.5))
    guard n > 4000 else { return nil }
    var best = 0.0, bestF = 0.0
    var f = 300.0
    while f < 4200 {
        let w = 2 * Double.pi * f / rate
        let c = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<n { let s0 = Double(s[i]) + c * s1 - s2; s2 = s1; s1 = s0 }
        let p = s1 * s1 + s2 * s2 - c * s1 * s2
        if p > best { best = p; bestF = f }
        f += 0.5
    }
    return (bestF - 300) / 2 - 0.25 // window centre -> its start
}

func fetchStats(_ base: String, _ file: String) -> Int {
    guard let url = URL(string: base + "/stats"), let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else { return -1 }
    return obj[file] ?? 0
}

func spin(_ seconds: Double, until cond: () -> Bool = { false }) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if cond() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    return cond()
}

let args = CommandLine.arguments
let base = args[1], file = args[2], precise = args[3] == "1"
_ = try? Data(contentsOf: URL(string: base + "/reset")!)
let url = URL(string: "\(base)/\(file)")!
let capture = Capture()
let t0 = Date()
let asset = AVURLAsset(url: url, options: precise ? [AVURLAssetPreferPreciseDurationAndTimingKey: true] : nil)
let item = AVPlayerItem(asset: asset)
let player = AVPlayer(playerItem: item)
player.automaticallyWaitsToMinimizeStalling = false
Task {
    if let track = try? await asset.loadTracks(withMediaType: .audio).first {
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = makeTap(capture)
        let mix = AVMutableAudioMix(); mix.inputParameters = [params]
        item.audioMix = mix
    }
}
let ready = spin(90) { item.status == .readyToPlay }
let readyMs = Date().timeIntervalSince(t0) * 1000
let readyBytes = fetchStats(base, file)
var rows: [[String: Any]] = []
if ready {
    player.play()
    _ = spin(1.0)
    for target in [600.0, 1500.0, 300.0, 1200.0, 900.0] {
        capture.disarm()
        _ = try? Data(contentsOf: URL(string: base + "/reset")!)
        let ts = Date()
        var done = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { _ in done = true }
        _ = spin(60) { done }
        let seekMs = Date().timeIntervalSince(ts) * 1000
        _ = spin(0.4)
        capture.arm()
        let heard = spin(10) { capture.take().count >= Int(capture.sampleRate * 0.5) }
        let landed = heard ? impliedSeconds(capture.take(), rate: capture.sampleRate) : nil
        // the sweep restarts nothing; the tap window starts ~0.4 s after the seek completed
        let expected = target + 0.4
        rows.append([
            "target": target, "seekMs": Int(seekMs), "heard": heard,
            "landed": landed.map { round($0 * 10) / 10 } as Any,
            "errorSec": landed.map { round(($0 - expected) * 10) / 10 } as Any,
            "playerTime": round(player.currentTime().seconds * 10) / 10,
            "bytesSinceReset": fetchStats(base, file),
        ])
    }
}
let out: [String: Any] = ["file": file, "precise": precise, "ready": ready, "readyMs": Int(readyMs), "bytesAtReady": readyBytes, "seeks": rows]
let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
exit(0)
