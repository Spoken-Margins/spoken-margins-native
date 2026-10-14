import Foundation

/// What reading a picked file gave: its text and, for a PDF, its structure. Reading the file stays
/// in the app (PDFKit, disk); ``SourceFileItemBuilder`` turns this into an Item (#959).
public struct ImportedSourceText: Sendable {
    public let text: String
    public let documentStructure: PDFDocumentStructure?
    /// A PDF's extraction v2 (C1 M3) and the title v1 would have given it.
    public var structuredDocument: StructuredDocument?
    public var title: String?

    public init(
        text: String,
        documentStructure: PDFDocumentStructure?,
        structuredDocument: StructuredDocument? = nil,
        title: String? = nil
    ) {
        self.text = text
        self.documentStructure = documentStructure
        self.structuredDocument = structuredDocument
        self.title = title
    }
}

/// The Item, Listening Map and structured document one imported file becomes, ready to save.
public struct PreparedObsidianImport: Sendable {
    public let item: Item
    public let listeningMap: ListeningMap?
    public var structuredDocument: StructuredDocument?

    public init(item: Item, listeningMap: ListeningMap?, structuredDocument: StructuredDocument? = nil) {
        self.item = item
        self.listeningMap = listeningMap
        self.structuredDocument = structuredDocument
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
            return PreparedObsidianImport(item: item, listeningMap: map, structuredDocument: document)
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
}
