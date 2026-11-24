import Foundation

/// What the app says after the share sheet closes on a Margin's export (#5051). The sheet reports whether it completed
/// and which activity took the file; only "Save to Files" leaves a file on the phone with nothing else to show for it,
/// so it is the only one that is confirmed. AirDrop, Mail, Copy and the like have their own feedback. A cancel or a
/// failure says nothing here (a failure keeps the error handling it already has).
public enum ExportSavedConfirmation {
    /// The activity type iOS gives the "Save to Files" action (On My iPhone, iCloud Drive and the other providers).
    public static let saveToFilesActivity = "com.apple.CloudDocsUI.AddToiCloudDrive"

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
        return activityType == saveToFilesActivity ? "Saved to Files" : nil
    }
}
