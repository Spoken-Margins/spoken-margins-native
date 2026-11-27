import Foundation

/// What the app says after the share sheet closes on a Margin's export (#5051). The sheet reports whether it completed
/// and which activity took the file; only "Save to Files" leaves a file on the phone with nothing else to show for it,
/// so it is the only one that is confirmed. AirDrop, Mail, Copy and the like have their own feedback. A cancel or a
/// failure says nothing here (a failure keeps the error handling it already has).
public enum ExportSavedConfirmation {
    /// The activity types iOS gives the "Save to Files" action (On My iPhone, iCloud Drive and the other providers).
    /// Recent iOS reports `com.apple.DocumentManagerUICore.SaveToFiles`; older releases reported
    /// `com.apple.CloudDocsUI.AddToiCloudDrive`. Matching only the old one left a completed save with no confirmation on
    /// the build 9d1eafa simulator run (#5051). The same pair is what `SpokenNoteTextDelivery` and `SessionShareFiles` know.
    public static let saveToFilesActivities: Set<String> = [
        "com.apple.DocumentManagerUICore.SaveToFiles",
        "com.apple.CloudDocsUI.AddToiCloudDrive",
    ]

    /// - Parameters:
    ///   - completed: the share sheet's own "completed" flag; false for a cancel.
    ///   - activityType: the raw activity type of the action the listener picked.
    ///   - savedTo: where the file ended up, when the system says (the share sheet does not today).
    ///   - failed: the share sheet came back with an error.
    public static func message(completed: Bool, activityType: String?, savedTo: URL? = nil, failed: Bool = false) -> String? {
        guard completed, !failed else { return nil }
        if let savedTo {
            let folder = savedTo.deletingLastPathComponent().lastPathComponent
            let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name != "/", name != "." { return "Saved to \(name)" }
            return "Saved to Files"
        }
        return activityType.map(saveToFilesActivities.contains) == true ? "Saved to Files" : nil
    }
}
