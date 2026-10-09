// The SessionKit model types the copied files use
// (Packages/SessionKit/Sources/SessionKit/Models.swift). `Item` is cut down to the two fields the
// copied `listenableProjection` reads. The CLI copies
// source files instead of linking SessionKit, whose package pulls in
// onnxruntime; keep this identical to the original.
public struct PDFNormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct PDFBibliography: Codable, Equatable, Sendable {
    public var doi: String?
    public var arxivId: String?
    public var authors: [String]
    public var year: Int?
    public var title: String?

    public init(doi: String? = nil, arxivId: String? = nil, authors: [String] = [], year: Int? = nil, title: String? = nil) {
        self.doi = doi
        self.arxivId = arxivId
        self.authors = authors
        self.year = year
        self.title = title
    }
}

public struct Item: Codable, Equatable, Sendable {
    public var mediaType: String
    public var text: String?
}
