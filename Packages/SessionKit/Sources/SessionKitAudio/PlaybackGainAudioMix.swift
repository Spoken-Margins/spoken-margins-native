#if canImport(AVFoundation) && canImport(MediaToolbox) && !os(watchOS)
import AVFoundation
import MediaToolbox
import SessionKit

/// Applies app-owned gain after decoding so mixed speech can rise above unity
/// without changing or ducking audio from another app.
public final class PlaybackGainAudioMix: @unchecked Sendable {
    private final class Context: @unchecked Sendable {
        private let lock = NSLock()
        private var storedGain: Float
        private var format: AudioStreamBasicDescription?

        init(gain: Float) {
            storedGain = Self.clamped(gain)
        }

        func update(gain: Float) {
            lock.withLock { storedGain = Self.clamped(gain) }
        }

        func prepare(_ processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
            lock.withLock { format = processingFormat.pointee }
        }

        func unprepare() {
            lock.withLock { format = nil }
        }

        func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: CMItemCount) {
            let state = lock.withLock { (storedGain, format) }
            let gain = state.0
            guard gain > 1.000_1,
                  let format = state.1,
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  frameCount > 0 else { return }

            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<sampleCount {
                    samples[index] = PlaybackGainAudioMix.applyingGain(samples[index], gain: gain)
                }
            }
        }

        static func clamped(_ gain: Float) -> Float {
            max(1, min(2, gain))
        }
    }

    private let context: Context
    public let audioMix: AVAudioMix

    public init(assetTrack: AVAssetTrack, gain: Float) throws {
        let context = Context(gain: gain)
        let retainedContext = Unmanaged.passRetained(context)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedContext.toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<Context>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .release()
            },
            prepare: { tap, _, processingFormat in
                PlaybackGainAudioMix.storedContext(for: tap).prepare(processingFormat)
            },
            unprepare: { tap in
                PlaybackGainAudioMix.storedContext(for: tap).unprepare()
            },
            process: { tap, requestedFrames, _, bufferList, framesOut, flagsOut in
                var sourceFlags = MTAudioProcessingTapFlags()
                var sourceTimeRange = CMTimeRange.invalid
                var sourceFrames: CMItemCount = 0
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    requestedFrames,
                    bufferList,
                    &sourceFlags,
                    &sourceTimeRange,
                    &sourceFrames
                )
                guard status == noErr else {
                    framesOut.pointee = 0
                    flagsOut.pointee = sourceFlags
                    return
                }
                framesOut.pointee = sourceFrames
                flagsOut.pointee = sourceFlags
                PlaybackGainAudioMix.storedContext(for: tap).process(bufferList, frameCount: sourceFrames)
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PostEffects),
            &tap
        )
        guard status == noErr, let tap else {
            retainedContext.release()
            throw SessionKitError.persistenceFailed("playback_gain_tap_create_failed:\(status)")
        }
        let parameters = AVMutableAudioMixInputParameters(track: assetTrack)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        self.context = context
        self.audioMix = mix
    }

    public func update(gain: Float) {
        context.update(gain: gain)
    }

    public static func clampedGain(_ gain: Float) -> Float {
        Context.clamped(gain)
    }

    static func applyingGain(_ sample: Float, gain: Float) -> Float {
        max(-1, min(1, sample * Context.clamped(gain)))
    }

    private static func storedContext(for tap: MTAudioProcessingTap) -> Context {
        Unmanaged<Context>
            .fromOpaque(MTAudioProcessingTapGetStorage(tap))
            .takeUnretainedValue()
    }
}
#endif
