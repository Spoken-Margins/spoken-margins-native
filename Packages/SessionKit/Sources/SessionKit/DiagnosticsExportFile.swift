import Foundation

/// The diagnostics export as a file for the share sheet (#903). Copying it as text put about
/// 400 KB on the clipboard, which most apps truncate or refuse; a file goes to Mail, Messages,
/// Files or a chat as one attachment.
public enum DiagnosticsExportFile {
    /// "Spoken Margins diagnostics 0.1 (30) 41a591e 2026-10-08 0937.json": the build and the local
    /// time, so a few exports from one test session sort and can be told apart. Only letters,
    /// digits and `.()-` survive from the build, so the name is safe in any file system.
    public static func fileName(build: String, exportedAt: Date, timeZone: TimeZone = .current) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".()-"))
        let buildWords = build
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: exportedAt)
        let stamp = String(format: "%04d-%02d-%02d %02d%02d",
                           parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        return (["Spoken Margins diagnostics"] + buildWords + [stamp]).joined(separator: " ") + ".json"
    }

    /// Writes `text` into `directory`, replacing any earlier export there, and returns the file.
    /// Earlier exports are removed so repeated taps don't pile up copies in the temporary folder.
    public static func write(
        _ text: String,
        build: String,
        exportedAt: Date,
        to directory: URL,
        timeZone: TimeZone = .current
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for earlier in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where earlier.pathExtension == "json" {
            try? fileManager.removeItem(at: earlier)
        }
        let file = directory.appendingPathComponent(fileName(build: build, exportedAt: exportedAt, timeZone: timeZone))
        try Data(text.utf8).write(to: file, options: .atomic)
        return file
    }
}
