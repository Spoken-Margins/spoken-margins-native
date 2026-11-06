import Foundation

/// Whether the live session's Lock Screen card says a spoken Margin is recording, and offers to finish it (#3499).
///
/// The card's Speak a Margin opens the app, which starts the recording; once it runs, the card shows "Recording a
/// Margin" and a Finish button in place of Mark and the Margin links, so the Margin can be saved from the Lock Screen
/// or Notification Center without opening the app. `nil` for an idle card keeps its state as an earlier build wrote
/// it, which decodes the same.
public enum LiveSessionCardRecording {
    /// The card's `isRecordingMargin`: true only while the session runs and a spoken Margin records on the phone.
    /// An ended session never reads as recording, whatever the screen still holds.
    public static func flag(isRunning: Bool, isRecordingSpoken: Bool) -> Bool? {
        isRunning && isRecordingSpoken ? true : nil
    }
}
