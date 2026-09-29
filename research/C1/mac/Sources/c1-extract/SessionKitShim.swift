// The one SessionKit model type the copied StructuredDocument.swift uses
// (Packages/SessionKit/Sources/SessionKit/Models.swift). The CLI copies
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
