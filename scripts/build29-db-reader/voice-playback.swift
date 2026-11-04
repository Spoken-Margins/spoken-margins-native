// Compiled into the shipped-build packet reader beside packet-reader.swift (scripts/check-build29-database.sh), and
// on its own by scripts/tests/test_voice_playback_check.py. AVFoundation only, so it builds against any shipped tag.
//
// Builds 32 and 34 have no format check of their own before they play an imported Margin: they hand the extracted
// file to the system (#3218). So "that build plays it" means the system opens it the three ways those builds do:
// AVPlayer (listening to an imported Margin), AVAudioPlayer (a Margin moment, MarginMomentConductor) and a float32
// AVAudioFile read (Build 34's loudness leveling). This runs on the Mac's decoders, not an iPhone's.

import AVFoundation
import Foundation

/// Why a shipped build could not play the voice file at `url`, or nil when it plays. `expectedMs` is the length the
/// packet's manifest gives it; the decoded length must be within half a second.
func voicePlaybackProblem(at url: URL, expectedMs: Int?) async -> String? {
    let expected = expectedMs.map { Double($0) / 1_000 }
    func off(_ seconds: Double) -> Bool { expected.map { abs(seconds - $0) > 0.5 } ?? false }

    let asset = AVURLAsset(url: url)
    do {
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        guard playable else { return "AVPlayer: not playable" }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return "AVPlayer: no audio track" }
        if off(duration.seconds) { return "AVPlayer: \(duration.seconds) s, the manifest says \(expected ?? 0) s" }
    } catch {
        return "AVPlayer: \(error.localizedDescription)"
    }

    // Opening is the check, not prepareToPlay(): that needs a sound output, which a hosted Mac runner may not have.
    do {
        let player = try AVAudioPlayer(contentsOf: url)
        if off(player.duration) { return "AVAudioPlayer: \(player.duration) s, the manifest says \(expected ?? 0) s" }
    } catch {
        return "AVAudioPlayer: \(error.localizedDescription)"
    }

    // Every frame is decoded, so a file whose header opens but whose audio does not is caught here.
    do {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard (1...2).contains(format.channelCount), format.sampleRate > 0 else {
            return "AVAudioFile: \(format.channelCount) channels at \(format.sampleRate) Hz"
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { return "AVAudioFile: no buffer" }
        var frames: AVAudioFramePosition = 0
        var peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: 16_384)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { break }
            for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
            frames += AVAudioFramePosition(buffer.frameLength)
        }
        let seconds = Double(frames) / format.sampleRate
        if frames == 0 { return "AVAudioFile: decoded no audio" }
        if off(seconds) { return "AVAudioFile: decoded \(seconds) s, the manifest says \(expected ?? 0) s" }
        if peak < 0.001 { return "AVAudioFile: decoded only silence" }
    } catch {
        return "AVAudioFile: \(error.localizedDescription)"
    }
    return nil
}
