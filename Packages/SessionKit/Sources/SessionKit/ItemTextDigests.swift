import Foundation

/// The two SHA-256 digests a shared packet matches an article by: over the text folded to letters and digits, and over
/// the exact characters. Hashing a long text takes noticeable time, so the store keeps them beside the item and the
/// matcher asks for them instead of for the text (#2506).
public struct ItemTextDigests: Codable, Equatable, Sendable {
    public var normalizedContentSHA256: String
    public var exactEditionSHA256: String

    public init(normalizedContentSHA256: String, exactEditionSHA256: String) {
        self.normalizedContentSHA256 = normalizedContentSHA256
        self.exactEditionSHA256 = exactEditionSHA256
    }
}
