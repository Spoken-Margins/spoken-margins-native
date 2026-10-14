import Foundation

/// The SentencePiece unigram tokenizer Pocket TTS reads its text through, read straight from the
/// `tokenizer.model` file so the app needs no SentencePiece library (#459).
///
/// It covers what this model's file uses and refuses a file that asks for more, so a different
/// export can't be tokenized wrongly in silence: no normalization table, no whitespace stripping,
/// the leading dummy space, spaces written as `▁`, and byte fallback for anything the 4,000
/// pieces don't cover. Python's `sentencepiece` gives the same ids (see `PocketTokenizerTests`).
struct PocketSentencePiece: Sendable {
    enum LoadError: Error, Equatable {
        case malformed(String)
        case unsupported(String)
    }

    private enum PieceKind: Int {
        case normal = 1
        case unknown = 2
        case control = 3
        case userDefined = 4
        case unused = 5
        case byte = 6
    }

    private struct Piece {
        var text: String
        var score: Float
        var kind: PieceKind
    }

    private final class TrieNode: @unchecked Sendable {
        var children: [UInt32: TrieNode] = [:]
        var pieceID: Int?
    }

    private static let spaceMark: Unicode.Scalar = "\u{2581}"
    /// SentencePiece scores a character no piece covers this far below the lowest piece.
    private static let unknownPenalty: Float = 10

    private let pieces: [Piece]
    private let root: TrieNode
    private let unknownID: Int
    private let unknownScore: Float
    private let byteIDs: [Int]
    private let addDummyPrefix: Bool
    private let maxPieceLength: Int

    init(contentsOf url: URL) throws {
        try self.init(modelData: try Data(contentsOf: url))
    }

    init(modelData: Data) throws {
        var pieces: [Piece] = []
        var addDummyPrefix = true
        var removeExtraWhitespaces = true
        var escapeWhitespaces = true
        var charsmapBytes = 0

        var reader = ProtoReader(modelData)
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, .lengthDelimited):
                pieces.append(try Self.parsePiece(try reader.lengthDelimited()))
            case (3, .lengthDelimited):
                var spec = ProtoReader(try reader.lengthDelimited())
                while let (specField, specWire) = try spec.nextField() {
                    switch (specField, specWire) {
                    case (2, .lengthDelimited): charsmapBytes = try spec.lengthDelimited().count
                    case (3, .varint): addDummyPrefix = try spec.varint() != 0
                    case (4, .varint): removeExtraWhitespaces = try spec.varint() != 0
                    case (5, .varint): escapeWhitespaces = try spec.varint() != 0
                    default: try spec.skip(specWire)
                    }
                }
            default:
                try reader.skip(wire)
            }
        }

        guard !pieces.isEmpty else { throw LoadError.malformed("no pieces") }
        guard charsmapBytes == 0 else { throw LoadError.unsupported("normalization table") }
        guard !removeExtraWhitespaces else { throw LoadError.unsupported("whitespace removal") }
        guard escapeWhitespaces else { throw LoadError.unsupported("unescaped whitespace") }
        guard let unknownID = pieces.firstIndex(where: { $0.kind == .unknown }) else {
            throw LoadError.malformed("no unknown piece")
        }

        var byteIDs = [Int](repeating: unknownID, count: 256)
        var foundBytes = 0
        let root = TrieNode()
        var maxPieceLength = 1
        var minScore = Float.greatestFiniteMagnitude
        for (id, piece) in pieces.enumerated() {
            switch piece.kind {
            case .byte:
                // "<0x0A>" spells the byte 0x0A.
                guard piece.text.count == 6, piece.text.hasPrefix("<0x"), piece.text.hasSuffix(">"),
                      let value = UInt8(piece.text.dropFirst(3).dropLast(), radix: 16) else {
                    throw LoadError.malformed("byte piece \(piece.text)")
                }
                byteIDs[Int(value)] = id
                foundBytes += 1
            case .normal, .userDefined:
                if piece.kind == .normal { minScore = min(minScore, piece.score) }
                var node = root
                var length = 0
                for scalar in piece.text.unicodeScalars {
                    if let next = node.children[scalar.value] {
                        node = next
                    } else {
                        let next = TrieNode()
                        node.children[scalar.value] = next
                        node = next
                    }
                    length += 1
                }
                node.pieceID = id
                maxPieceLength = max(maxPieceLength, length)
            case .unknown, .control, .unused:
                break
            }
        }
        guard foundBytes == 0 || foundBytes == 256 else { throw LoadError.malformed("partial byte pieces") }

        self.pieces = pieces
        self.root = root
        self.unknownID = unknownID
        self.unknownScore = minScore - Self.unknownPenalty
        self.byteIDs = foundBytes == 256 ? byteIDs : []
        self.addDummyPrefix = addDummyPrefix
        self.maxPieceLength = maxPieceLength
    }

    /// The ids SentencePiece's `Encode` returns for `text`, with no BOS or EOS.
    func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count + 1)
        if addDummyPrefix { scalars.append(Self.spaceMark) }
        for scalar in text.unicodeScalars {
            scalars.append(scalar == " " ? Self.spaceMark : scalar)
        }

        // Viterbi over the lattice, in the order and with the float arithmetic SentencePiece uses,
        // so a tie between two segmentations breaks the way it does there: toward the piece that
        // starts earlier.
        let count = scalars.count
        var bestScore = [Float](repeating: -Float.greatestFiniteMagnitude, count: count + 1)
        var previous = [Int](repeating: -1, count: count + 1)
        var pieceAt = [Int](repeating: -1, count: count + 1)
        bestScore[0] = 0

        for start in 0..<count {
            guard bestScore[start] > -Float.greatestFiniteMagnitude else { continue }
            var hasSingle = false
            var node = root
            var length = 0
            while start + length < count, length < maxPieceLength,
                  let next = node.children[scalars[start + length].value] {
                node = next
                length += 1
                guard let id = node.pieceID else { continue }
                if length == 1 { hasSingle = true }
                let end = start + length
                let candidate = bestScore[start] + pieces[id].score
                if candidate > bestScore[end] {
                    bestScore[end] = candidate
                    previous[end] = start
                    pieceAt[end] = id
                }
            }
            if !hasSingle {
                let end = start + 1
                let candidate = bestScore[start] + unknownScore
                if candidate > bestScore[end] {
                    bestScore[end] = candidate
                    previous[end] = start
                    pieceAt[end] = unknownID
                }
            }
        }

        var reversed: [(start: Int, end: Int, id: Int)] = []
        var end = count
        while end > 0 {
            let start = previous[end]
            reversed.append((start, end, pieceAt[end]))
            end = start
        }

        var ids: [Int] = []
        for node in reversed.reversed() {
            if node.id == unknownID, !byteIDs.isEmpty {
                var surface = String.UnicodeScalarView()
                for scalar in scalars[node.start..<node.end] {
                    surface.append(scalar == Self.spaceMark ? " " : scalar)
                }
                for byte in String(surface).utf8 { ids.append(byteIDs[Int(byte)]) }
            } else {
                ids.append(node.id)
            }
        }
        return ids
    }

    /// The text for `ids`, as SentencePiece's `Decode`: the leading dummy space is dropped.
    func decode(_ ids: [Int]) -> String {
        var bytes: [UInt8] = []
        for id in ids where pieces.indices.contains(id) {
            let piece = pieces[id]
            switch piece.kind {
            case .byte:
                if let value = UInt8(piece.text.dropFirst(3).dropLast(), radix: 16) { bytes.append(value) }
            case .control, .unused:
                break
            case .unknown:
                bytes.append(contentsOf: Array(" \u{2047} ".utf8))
            case .normal, .userDefined:
                bytes.append(contentsOf: Array(piece.text.utf8))
            }
        }
        var text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{2581}", with: " ")
        if addDummyPrefix, text.hasPrefix(" ") { text.removeFirst() }
        return text
    }

    private static func parsePiece(_ data: Data) throws -> Piece {
        var text = ""
        var score: Float = 0
        var kind = PieceKind.normal
        var reader = ProtoReader(data)
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, .lengthDelimited):
                text = String(decoding: try reader.lengthDelimited(), as: UTF8.self)
            case (2, .fixed32):
                score = Float(bitPattern: try reader.fixed32())
            case (3, .varint):
                guard let parsed = PieceKind(rawValue: Int(try reader.varint())) else {
                    throw LoadError.malformed("piece type")
                }
                kind = parsed
            default:
                try reader.skip(wire)
            }
        }
        return Piece(text: text, score: score, kind: kind)
    }
}

/// Just enough of the protobuf wire format to read a SentencePiece model.
struct ProtoReader {
    enum Wire: Int {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case fixed32 = 5
    }

    private let data: Data
    private var position: Data.Index

    init(_ data: Data) {
        self.data = data
        self.position = data.startIndex
    }

    mutating func nextField() throws -> (Int, Wire)? {
        guard position < data.endIndex else { return nil }
        let tag = try varint()
        guard let wire = Wire(rawValue: Int(tag & 7)) else {
            throw PocketSentencePiece.LoadError.malformed("wire type \(tag & 7)")
        }
        return (Int(tag >> 3), wire)
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < data.endIndex {
            let byte = data[position]
            position = data.index(after: position)
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { break }
        }
        throw PocketSentencePiece.LoadError.malformed("varint")
    }

    mutating func fixed32() throws -> UInt32 {
        guard let end = data.index(position, offsetBy: 4, limitedBy: data.endIndex) else {
            throw PocketSentencePiece.LoadError.malformed("fixed32")
        }
        var value: UInt32 = 0
        for (offset, byte) in data[position..<end].enumerated() { value |= UInt32(byte) << (8 * UInt32(offset)) }
        position = end
        return value
    }

    mutating func lengthDelimited() throws -> Data {
        let length = Int(clamping: try varint())
        guard length >= 0, let end = data.index(position, offsetBy: length, limitedBy: data.endIndex) else {
            throw PocketSentencePiece.LoadError.malformed("length")
        }
        defer { position = end }
        return data[position..<end]
    }

    mutating func skip(_ wire: Wire) throws {
        switch wire {
        case .varint: _ = try varint()
        case .fixed32: _ = try fixed32()
        case .fixed64:
            guard let end = data.index(position, offsetBy: 8, limitedBy: data.endIndex) else {
                throw PocketSentencePiece.LoadError.malformed("fixed64")
            }
            position = end
        case .lengthDelimited: _ = try lengthDelimited()
        }
    }
}
