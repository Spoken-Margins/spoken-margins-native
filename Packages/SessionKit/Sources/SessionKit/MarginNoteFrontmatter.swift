import Foundation

/// The YAML properties block at the top of a Margin note (#491).
///
/// Every string value is written as a YAML double-quoted scalar with its quotes, backslashes,
/// line breaks and other control characters escaped, so a title such as `Why: "now"` or one
/// with a newline can't end the value early or add keys. `created` stays a bare ISO 8601
/// timestamp so Obsidian shows it as a date. Links pass through ``ShareableLinkPolicy`` again,
/// so a private feed link never reaches a note even if an export was built without it.
public struct MarginNoteFrontmatter: Equatable {
    public enum Target: String { case source, aiReply = "ai_reply" }

    public var title: String
    public var source: String?
    public var author: String?
    public var created: String
    public var itemID: String
    public var marginID: String
    public var marginKind: InterjectionCaptureKind
    public var target: Target
    public var tags: [String] = ["spoken-margins"]

    public init(export: SessionExport, margin: ExportInterjection, created: String) {
        title = export.item.title
        // The item's page, not its media file: the property is for opening the source.
        source = ShareableLinkPolicy.shareableLink(export.item.externalReference)
        author = export.item.author
        self.created = created
        itemID = export.item.id
        marginID = margin.id
        // Exports from before written Margins carry no kind; those were all recordings.
        marginKind = margin.captureKind ?? .audio
        target = margin.targetType == InterjectionTargetType.item.rawValue ? .source : .aiReply
    }

    /// `---`, one `key: value` line per property, `---`, then a blank line before the body.
    public var lines: [String] {
        var properties: [(String, String)] = [("title", Self.quoted(title))]
        if let source { properties.append(("source", Self.quoted(source))) }
        if let author { properties.append(("author", Self.quoted(author))) }
        properties += [
            ("created", created),
            ("item_id", Self.quoted(itemID)),
            ("margin_id", Self.quoted(marginID)),
            ("margin_kind", marginKind == .written ? "written" : "spoken"),
            ("target", target.rawValue),
            ("tags", "[" + tags.joined(separator: ", ") + "]"),
        ]
        return ["---"] + properties.map { "\($0.0): \($0.1)" } + ["---", ""]
    }

    /// A YAML double-quoted scalar. Escapes `\`, `"`, every C0 control, DEL, and the
    /// characters YAML 1.1 readers treat as line breaks (U+0085, U+2028, U+2029) or strip (U+FEFF).
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x85
                || scalar.value == 0x2028 || scalar.value == 0x2029 || scalar.value == 0xFEFF:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
