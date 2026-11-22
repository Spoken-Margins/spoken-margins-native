import Foundation

/// What the export keeps about a Margin start from a compact control or headphone that did not record (#3085).
/// The banner's text is generic, so the raw error, the app state and whether protected data was available (a hint
/// that the phone was locked) are kept here to tell a locked phone from any other failure.
public struct CompactBeginFailureRecord: Equatable, Sendable {
    public enum Tristate: String, Equatable, Sendable { case yes, no, unknown }

    public var appState: String
    public var protectedDataAvailable: Tristate
    public var origin: String
    public var error: String
    public var cue: String
    /// The recorder's route, category and session-switch details at the refusal, and what happened just before
    /// (`CompactBeginContext`). Kept in the developer event only, so the one-line diagnostics stay short (#4414).
    public var details: [String: String]

    public init(
        appState: String, protectedDataAvailable: Tristate, origin: String, error: String, cue: String,
        details: [String: String] = [:]
    ) {
        self.appState = appState
        self.protectedDataAvailable = protectedDataAvailable
        self.origin = origin
        self.error = error
        self.cue = cue
        self.details = details
    }

    /// Field names shared by the diagnostics line and the developer event.
    public var fields: [(key: String, value: String)] {
        [("appState", appState), ("protectedData", protectedDataAvailable.rawValue), ("origin", origin),
         ("error", Self.clean(error)), ("cue", Self.clean(cue))]
    }

    public var diagnosticsLine: String { fields.map { "\($0.key)=\($0.value)" }.joined(separator: ";") }

    /// The record's own fields win over a detail of the same name.
    public var eventFields: [String: String] {
        details.merging(Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })) { _, own in own }
    }

    /// One line, no `;` or `=`, and bounded, so a long error cannot break the line's shape.
    static func clean(_ text: String) -> String {
        let flat = String(text.map { $0.isNewline ? " " : $0 })
            .replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "=", with: ":")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }
}
