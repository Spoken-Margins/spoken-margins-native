import Foundation

/// Holds bounded background time through rendering, publishing and queueing the next chunk.
/// Audio alone cannot keep inference alive once the audible chunk ends (#538).
@MainActor
public enum RenderedSpeechBackgroundProtection {
    public enum Stop: String, Sendable {
        case expired, unavailable

        public var failureCode: String { "supertonic_background_render_\(rawValue)" }
    }

    public static func run(
        begin: NarrationStartupProtection.Begin,
        onStop: @escaping @MainActor (Stop) -> Void,
        operation: @MainActor () async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let hold = Hold(onStop: onStop)
        if let release = begin("Render next narration chunk", { hold.stop(.expired) }) {
            hold.install(release)
        } else {
            hold.stop(.unavailable)
        }
        defer { hold.finish() }
        guard hold.active, !Task.isCancelled else { return }
        await withTaskCancellationHandler {
            await operation()
        } onCancel: {
            // Inference may not cooperate with cancellation. Give the time back without
            // waiting for it to return, and ignore any later expiry of this scope.
            Task { @MainActor in hold.finish() }
        }
    }

    @MainActor
    private final class Hold {
        private(set) var active = true
        private var release: (@MainActor () -> Void)?
        private let onStop: @MainActor (Stop) -> Void

        init(onStop: @escaping @MainActor (Stop) -> Void) { self.onStop = onStop }

        func install(_ release: @escaping @MainActor () -> Void) {
            if active { self.release = release } else { release() }
        }

        func stop(_ reason: Stop) {
            guard active else { return }
            active = false
            // Start the failure/fallback handling before relinquishing execution time.
            onStop(reason)
            finish()
        }

        func finish() {
            active = false
            let end = release
            release = nil
            end?()
        }
    }
}
