import Foundation
#if canImport(Combine)
import Combine
#endif

/// Where each audio client says that sound began for a target (#842).
///
/// The start cue (the soft chime and the waiting pops) learned that speech had begun only by polling: once before
/// the chime played, once at the end of its first note, then at the next 500 ms tick. Speech that began during the
/// second note played under it for up to about 0.12 s. Each client now posts its target here the moment its first
/// sound starts, and the cue can stop at once.
///
/// This is a hub rather than a closure on the routed client because the app rebuilds that client when voice
/// settings change, while the cue lives for the app's life. It only reports; it changes no playback state, and
/// `firstAudioMs` still comes from the engine's `.playing` snapshot.
public final class FirstAudioSignals: @unchecked Sendable {
    public static let shared = FirstAudioSignals()

    public init() {}

    #if canImport(Combine)
    /// The target id of each first sound. Sending is allowed from any thread; receivers pick their own queue.
    public let heard = PassthroughSubject<String, Never>()
    #endif

    /// Reports that sound began for `targetId`. Safe from any thread. A no-op where Combine is absent.
    public func post(_ targetId: String) {
        #if canImport(Combine)
        heard.send(targetId)
        #endif
    }
}

/// Lets a client report only the first sound of each `play` call (#842). `arm` at each play; `take` is true once
/// after each arm for the same target, so a rebuffer or a second chunk inside one play posts nothing more.
/// Not thread-safe: the owner keeps it under its own queue or lock.
public struct FirstAudioLatch: Sendable, Equatable {
    private var armedTargetId: String?

    public init() {}

    public mutating func arm(targetId: String) {
        armedTargetId = targetId
    }

    /// True once after `arm(targetId:)` for this target; false for another target, or when already taken.
    public mutating func take(targetId: String) -> Bool {
        guard armedTargetId == targetId else { return false }
        armedTargetId = nil
        return true
    }
}

/// The `postFirstAudio` default every client takes. Written as a closure because Swift 6 mode refuses a method
/// reference here.
public typealias FirstAudioPoster = @Sendable (String) -> Void
