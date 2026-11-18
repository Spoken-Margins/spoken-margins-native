import Foundation

/// What reading a picked file gave: its text and, for a PDF, its structure. Reading the file stays
/// in the app (PDFKit, disk); ``SourceFileItemBuilder`` turns this into an Item (#959).
public struct ImportedSourceText: Sendable {
    public let text: String
    public let documentStructure: PDFDocumentStructure?
    /// A PDF's extraction v2 (C1 M3) and the title v1 would have given it.
    public var structuredDocument: StructuredDocument?
    public var title: String?
    /// A Word document's paragraphs (#4594). When set, the item is built from them as they are: their headings are the
    /// chapters, and nothing is read as Markdown, so a line that starts with `#` or `-`, or says "Timestamps", is text.
    public var paragraphs: [DocumentParagraph]?
    /// JPEG pictures of the PDF's tables and figures by float id (#3895), cut while the PDF was open.
    public var clips: [String: Data]

    public init(
        text: String,
        documentStructure: PDFDocumentStructure?,
        structuredDocument: StructuredDocument? = nil,
        title: String? = nil,
        paragraphs: [DocumentParagraph]? = nil,
        clips: [String: Data] = [:]
    ) {
        self.text = text
        self.documentStructure = documentStructure
        self.structuredDocument = structuredDocument
        self.title = title
        self.paragraphs = paragraphs
        self.clips = clips
    }
}

/// One paragraph of a document read as paragraphs (a Word file). `headingLevel` is nil for body text and otherwise
/// ranks like Markdown's `#` count: 1 for the document's title, 2 and up for its headings.
public struct DocumentParagraph: Equatable, Sendable {
    public var text: String
    public var headingLevel: Int?

    public init(text: String, headingLevel: Int? = nil) {
        self.text = text
        self.headingLevel = headingLevel
    }
}

/// The Item, Listening Map and structured document one imported file becomes, ready to save.
public struct PreparedObsidianImport: Sendable {
    public let item: Item
    public let listeningMap: ListeningMap?
    public var structuredDocument: StructuredDocument?
    /// The PDF's clip pictures by float id, saved beside the item (#3895).
    public var clips: [String: Data]

    public init(item: Item, listeningMap: ListeningMap?, structuredDocument: StructuredDocument? = nil, clips: [String: Data] = [:]) {
        self.item = item
        self.listeningMap = listeningMap
        self.structuredDocument = structuredDocument
        self.clips = clips
    }
}

/// What Item and Listening Map a picked Markdown, text or PDF file becomes (#959). Moved out of
/// Gate1AppModel so the rules run on Linux. The result is saved to the listener's Library, so a
/// changed field is changed owner data: the tests pin every stored field.
public enum SourceFileItemBuilder {
    /// A PDF with an extraction v2 document takes its chapters from the document; any other file is
    /// parsed as Markdown, with section chapters for text and canonical headings for a PDF's plain
    /// text. `createdAt` is the caller's clock, read once per file. A file with no text throws.
    public static func prepare(
        _ imported: ImportedSourceText,
        fileURL: URL,
        itemId: String,
        createdAt: Date
    ) throws -> PreparedObsidianImport {
        if let document = imported.structuredDocument {
            let title = imported.title ?? fileURL.deletingPathExtension().lastPathComponent
            let map = StructuredDocumentImport.listeningMap(for: document, title: title, itemId: itemId)
            let item = Item(
                id: itemId,
                title: title,
                mediaType: "pdf",
                text: document.text,
                externalReference: fileURL.lastPathComponent,
                status: map == nil ? "needs_listening_map" : "ready",
                externalReferenceType: "file",
                createdAt: createdAt,
                documentStructure: imported.documentStructure
            )
            return PreparedObsidianImport(item: item, listeningMap: map, structuredDocument: document, clips: imported.clips)
        }
        if let paragraphs = imported.paragraphs {
            return try prepare(paragraphs: paragraphs, title: imported.title, fileURL: fileURL, itemId: itemId, createdAt: createdAt)
        }
        let parsed = try ObsidianMarkdownParser.parse(fileName: fileURL.lastPathComponent, contents: imported.text)
        // The author's headings are the chapters, in a Markdown or a plain text file alike (#1435, #1468).
        let mapPolicy: DeterministicListeningMapPolicy = fileURL.pathExtension.lowercased() == "pdf"
            ? .canonicalHeadings
            : .authoredSections
        let deterministicMap = parsed.deterministicListeningMap(
            itemId: itemId,
            policy: mapPolicy
        )
        let item = Item(
            id: itemId,
            title: parsed.title,
            mediaType: fileURL.pathExtension.lowercased() == "pdf" ? "pdf" : "text",
            text: parsed.text,
            externalReference: parsed.source ?? fileURL.lastPathComponent,
            status: deterministicMap == nil ? "needs_listening_map" : "ready",
            externalReferenceType: "file",
            createdAt: createdAt,
            documentStructure: imported.documentStructure
        )
        return PreparedObsidianImport(item: item, listeningMap: deterministicMap)
    }

    /// A document read as paragraphs: one paragraph after another with a blank line between, each cleaned the way an
    /// imported line is, and its headings the chapters. The title is the one given (a Word file's properties), else the
    /// file name. Empty paragraphs are dropped; a document with no text throws, as an empty Markdown file does.
    static func prepare(
        paragraphs: [DocumentParagraph], title: String?, fileURL: URL, itemId: String, createdAt: Date
    ) throws -> PreparedObsidianImport {
        var lines: [String] = []
        var headings: [ParsedMarkdownHeading] = []
        var length = 0
        for paragraph in paragraphs {
            // A line break inside a paragraph stays a line break; each line is cleaned on its own.
            let cleaned = paragraph.text.components(separatedBy: "\n")
                .map { SpeechTextNormalizer.normalizeImportedText($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            guard !cleaned.isEmpty else { continue }
            if !lines.isEmpty { length += 2 }
            if let level = paragraph.headingLevel {
                let headingTitle = cleaned.replacingOccurrences(of: "\n", with: " ")
                headings.append(ParsedMarkdownHeading(level: level, title: headingTitle, startChar: length))
            }
            lines.append(cleaned)
            length += cleaned.count
        }
        let text = lines.joined(separator: "\n\n")
        guard !text.isEmpty else { throw SessionKitError.persistenceFailed("obsidian_import_empty_text") }
        let resolvedTitle = title ?? ObsidianMarkdownParser.fileNameTitle(fileURL.lastPathComponent)
        let parsed = ParsedObsidianMarkdown(title: resolvedTitle, text: text, source: nil, metadata: [:], headings: headings)
        let map = parsed.deterministicListeningMap(itemId: itemId, policy: .authoredSections)
        let item = Item(
            id: itemId,
            title: resolvedTitle,
            mediaType: "text",
            text: text,
            externalReference: fileURL.lastPathComponent,
            status: map == nil ? "needs_listening_map" : "ready",
            externalReferenceType: "file",
            createdAt: createdAt,
            documentStructure: nil
        )
        return PreparedObsidianImport(item: item, listeningMap: map)
    }
}
