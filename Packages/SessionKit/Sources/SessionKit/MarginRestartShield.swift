import Foundation

/// Whether a tap on Add a Margin may start a new recording right after a Margin was saved (#148).
///
/// Save & resume sits where Add a Margin sits on the listening screen. When the first tap on Save seems to do
/// nothing, a second tap follows, and it lands on Add a Margin once the screen has switched. Saving finalizes the
/// recording on the main thread and the listening screen then takes a while to draw, so a timer that starts when
/// the save ends can run out *during* that draw; the queued second tap then arrives to an open door. This shield
/// is therefore anchored to the screen really appearing, not to the model finishing: no new recording starts while
/// a save is in progress or until the listening screen has been on screen for `window`.
///
/// If the screen never reports that it appeared, a tap counts again after `longestWait`, so Add a Margin can't
/// stay dead.
public struct MarginRestartShield: Equatable, Sendable {
    /// How long the listening screen must have been on screen before a tap starts a new recording. One constant,
    /// so it can be tuned on the phone.
    public static let window: TimeInterval = 1.0
    /// The most the shield waits for the listening screen to appear after a save.
    public static let longestWait: TimeInterval = 4.0

    private enum Phase: Equatable, Sendable {
        case open
        case saving(screenAppearedAt: Date?)
        case awaitingScreen(since: Date)
        case settling(until: Date)
    }

    private var phase: Phase = .open

    public init() {}

    /// Save & resume was tapped and the save is under way.
    public mutating func saveRequested() {
        phase = .saving(screenAppearedAt: nil)
    }

    /// The save call returned. `stillRecording` is true when it did not stop the recording (nothing to keep), in
    /// which case the screen does not change and the shield opens again.
    public mutating func saveFinished(at date: Date, stillRecording: Bool) {
        guard !stillRecording else {
            phase = .open
            return
        }
        // The screen can be reported before the save call returns to its caller; the window then starts there.
        if case .saving(let appeared?) = phase {
            phase = .settling(until: appeared.addingTimeInterval(Self.window))
        } else {
            phase = .awaitingScreen(since: date)
        }
    }

    /// The listening screen is on screen again. Only the first appearance after a save starts the window.
    public mutating func screenAppeared(at date: Date) {
        switch phase {
        case .awaitingScreen:
            phase = .settling(until: date.addingTimeInterval(Self.window))
        case .saving(nil):
            phase = .saving(screenAppearedAt: date)
        case .open, .saving, .settling:
            break
        }
    }

    public func acceptsBegin(at date: Date) -> Bool {
        switch phase {
        case .open:
            true
        case .saving:
            false
        case .awaitingScreen(let since):
            date.timeIntervalSince(since) >= Self.longestWait
        case .settling(let until):
            date >= until
        }
    }
}
