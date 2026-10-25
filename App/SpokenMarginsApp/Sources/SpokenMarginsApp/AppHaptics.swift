import SessionKit
#if canImport(UIKit)
import UIKit
#endif

/// The app's haptics (#1978): one place that turns a `HapticKind` into a tap.
///
/// UIKit's feedback generators follow the system setting (Settings › Sounds & Haptics › System Haptics) and the
/// phone's silent switch does not mute them, so nothing here reads either. iOS holds haptics back while the
/// microphone is recording, and this does not change that (`allowHapticsAndSystemSoundsDuringRecording` would
/// reconfigure the audio session, which the ready cue avoids, #1594): "started" is felt when the tap is accepted,
/// and "saved" once the recorder has stopped. Each call is one tap; nothing repeats.
@MainActor
enum AppHaptics {
    /// Replaced by tests; the device's taps otherwise.
    static var sink: HapticFeedbackSink = SystemHaptics()

    static func play(_ kind: HapticKind) {
        sink.play(kind)
    }
}

@MainActor
final class SystemHaptics: HapticFeedbackSink {
    func play(_ kind: HapticKind) {
        #if canImport(UIKit) && !os(macOS)
        switch kind {
        case .started:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .saved:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .ended:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        #endif
    }
}
