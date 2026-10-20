import Foundation
#if canImport(CBZip2)
import CBZip2
#endif

// Unpacking the upstream archives some voices are published in (#2086). Supertonic's INT8 graphs exist
// upstream only inside one sherpa-onnx tar.bz2, so the installer downloads that archive, checks its hash,
// and streams it through here to take out the members the catalog names. Nothing is extracted by its own
// name: the reader hands each member's bytes to the installer, which writes them to the catalog's path.

/// Turns a downloaded archive into the bytes of the tar inside it.
public protocol VoiceModelArchiveDecompressor: Sendable {
    /// The archive formats (`VoiceModelArchive.format`) this decompressor can open.
    var formats: Set<String> { get }
    /// Streams the tar bytes of the archive at `url` to `onChunk`, in order. Whatever `onChunk` throws
    /// ends the stream and is rethrown.
    func tarBytes(of url: URL, format: String, onChunk: (Data) throws -> Void) throws
}

public enum VoiceModelArchiveError: Error, Equatable, Sendable {
    /// The archive's compressed bytes are damaged or not in the stated format.
    case corrupt(String)
    /// The tar ended part-way through a header or a member.
    case truncated
}

/// Decompresses `tar.bz2` with the system's libbz2. Available where the SDK ships libbz2 (macOS, iOS).
public struct BZip2ArchiveDecompressor: VoiceModelArchiveDecompressor {
    public init() {}

    public static var isAvailable: Bool {
        #if canImport(CBZip2)
        true
        #else
        false
        #endif
    }

    public var formats: Set<String> { Self.isAvailable ? ["tar.bz2"] : [] }

    public func tarBytes(of url: URL, format: String, onChunk: (Data) throws -> Void) throws {
        guard format == "tar.bz2", Self.isAvailable else { throw VoiceModelArchiveError.corrupt("\(format) can't be opened here") }
        #if canImport(CBZip2)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let inputCapacity = 1 << 20
        let outputCapacity = 1 << 20
        let input = UnsafeMutablePointer<CChar>.allocate(capacity: inputCapacity)
        let output = UnsafeMutablePointer<CChar>.allocate(capacity: outputCapacity)
        defer {
            input.deallocate()
            output.deallocate()
        }
        var stream = bz_stream()
        guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { throw VoiceModelArchiveError.corrupt("libbz2 would not start") }
        var open = true
        defer { if open { BZ2_bzDecompressEnd(&stream) } }
        var inputEnded = false
        var streams = 0
        while true {
            if stream.avail_in == 0, !inputEnded {
                let block = try handle.read(upToCount: inputCapacity) ?? Data()
                if block.isEmpty {
                    inputEnded = true
                } else {
                    block.copyBytes(to: UnsafeMutableRawBufferPointer(start: input, count: inputCapacity).bindMemory(to: UInt8.self), count: block.count)
                    stream.next_in = input
                    stream.avail_in = UInt32(block.count)
                }
            }
            stream.next_out = output
            stream.avail_out = UInt32(outputCapacity)
            let status = BZ2_bzDecompress(&stream)
            let produced = outputCapacity - Int(stream.avail_out)
            if produced > 0 {
                try onChunk(Data(bytes: output, count: produced))
            }
            switch status {
            case BZ_OK:
                if inputEnded, stream.avail_in == 0, produced == 0 {
                    throw VoiceModelArchiveError.corrupt("the archive ends part-way through its compressed data")
                }
            case BZ_STREAM_END:
                streams += 1
                // A parallel bzip2 writes several streams back to back; carry on into the next one, if any.
                let pending = stream.next_in
                let pendingCount = stream.avail_in
                if pendingCount == 0 {
                    if inputEnded { return }
                    let block = try handle.read(upToCount: inputCapacity) ?? Data()
                    if block.isEmpty { return }
                    block.copyBytes(to: UnsafeMutableRawBufferPointer(start: input, count: inputCapacity).bindMemory(to: UInt8.self), count: block.count)
                    BZ2_bzDecompressEnd(&stream)
                    stream = bz_stream()
                    guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { open = false; throw VoiceModelArchiveError.corrupt("libbz2 would not restart") }
                    stream.next_in = input
                    stream.avail_in = UInt32(block.count)
                } else {
                    BZ2_bzDecompressEnd(&stream)
                    stream = bz_stream()
                    guard BZ2_bzDecompressInit(&stream, 0, 0) == BZ_OK else { open = false; throw VoiceModelArchiveError.corrupt("libbz2 would not restart") }
                    stream.next_in = pending
                    stream.avail_in = pendingCount
                }
            case BZ_DATA_ERROR_MAGIC where streams > 0:
                // Padding after the last stream, which bzip2 itself ignores.
                return
            default:
                throw VoiceModelArchiveError.corrupt("libbz2 error \(status)")
            }
        }
        #endif
    }
}

/// Reads a tar stream (ustar, with pax `path` records and GNU long names) one chunk at a time, holding
/// no member in memory. It reports each regular file's path and size, passes on the bytes of the ones
/// the caller wants, and skips the rest. Links and devices are skipped, never followed.
public final class TarStreamReader {
    public struct Member: Equatable, Sendable {
        public var path: String
        public var size: Int64
    }

    private enum State {
        case header
        case member(Member, remaining: Int64, wanted: Bool)
        case skip(remaining: Int64)
        case metadata(kind: UInt8, remaining: Int64)
        case padding(remaining: Int64)
        case end
    }

    /// Returns whether to receive the member's bytes.
    private let onMember: (Member) throws -> Bool
    private let onData: (Data) throws -> Void
    private let onMemberEnd: (Member) throws -> Void
    private var state: State = .header
    private var header: [UInt8] = []
    private var metadata: [UInt8] = []
    private var pendingPath: String?
    private static let maximumMetadataBytes: Int64 = 1 << 20

    public init(
        onMember: @escaping (Member) throws -> Bool,
        onData: @escaping (Data) throws -> Void,
        onMemberEnd: @escaping (Member) throws -> Void
    ) {
        self.onMember = onMember
        self.onData = onData
        self.onMemberEnd = onMemberEnd
    }

    public var reachedEnd: Bool {
        if case .end = state { return true }
        return false
    }

    public func feed(_ chunk: Data) throws {
        var index = chunk.startIndex
        while index < chunk.endIndex {
            switch state {
            case .end:
                return
            case .header:
                let take = min(512 - header.count, chunk.endIndex - index)
                header.append(contentsOf: chunk[index..<(index + take)])
                index += take
                if header.count == 512 {
                    let block = header
                    header.removeAll(keepingCapacity: true)
                    try readHeader(block)
                }
            case .member(let member, let remaining, let wanted):
                let take = Int(min(remaining, Int64(chunk.endIndex - index)))
                if wanted { try onData(chunk.subdata(in: index..<(index + take))) }
                index += take
                let left = remaining - Int64(take)
                if left == 0 {
                    try onMemberEnd(member)
                    state = .padding(remaining: Self.padding(after: member.size))
                } else {
                    state = .member(member, remaining: left, wanted: wanted)
                }
            case .skip(let remaining):
                let take = Int(min(remaining, Int64(chunk.endIndex - index)))
                index += take
                state = remaining - Int64(take) == 0 ? .header : .skip(remaining: remaining - Int64(take))
            case .padding(let remaining):
                let take = Int(min(remaining, Int64(chunk.endIndex - index)))
                index += take
                state = remaining - Int64(take) == 0 ? .header : .padding(remaining: remaining - Int64(take))
            case .metadata(let kind, let remaining):
                let take = Int(min(remaining, Int64(chunk.endIndex - index)))
                metadata.append(contentsOf: chunk[index..<(index + take)])
                index += take
                let left = remaining - Int64(take)
                if left == 0 {
                    finishMetadata(kind: kind)
                    let size = Int64(metadata.count)
                    metadata.removeAll(keepingCapacity: true)
                    state = .padding(remaining: Self.padding(after: size))
                } else {
                    state = .metadata(kind: kind, remaining: left)
                }
            }
            // A zero-length padding or skip is already finished.
            if case .padding(0) = state { state = .header }
            if case .skip(0) = state { state = .header }
        }
    }

    /// Call after the last chunk. Throws when the stream stopped inside a header or a member.
    public func finish() throws {
        switch state {
        case .end:
            return
        case .header where header.isEmpty:
            return
        default:
            throw VoiceModelArchiveError.truncated
        }
    }

    private func readHeader(_ block: [UInt8]) throws {
        if block.allSatisfy({ $0 == 0 }) {
            state = .end
            return
        }
        guard let size = Self.size(block[124..<136]), size >= 0 else { throw VoiceModelArchiveError.corrupt("a tar header has an unreadable size") }
        let type = block[156]
        switch type {
        case UInt8(ascii: "x"), UInt8(ascii: "L"):
            guard size <= Self.maximumMetadataBytes else { throw VoiceModelArchiveError.corrupt("a tar metadata record is too large") }
            state = size == 0 ? .header : .metadata(kind: type, remaining: size)
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
            let member = Member(path: pendingPath ?? Self.headerPath(block), size: size)
            pendingPath = nil
            let wanted = try onMember(member)
            if size == 0 {
                try onMemberEnd(member)
                state = .header
            } else {
                state = .member(member, remaining: size, wanted: wanted)
            }
        default:
            // Folders, links, devices, global pax records: nothing to write, so skip their data.
            if type != UInt8(ascii: "g") { pendingPath = nil }
            let total = size + Self.padding(after: size)
            state = total == 0 ? .header : .skip(remaining: total)
        }
    }

    private func finishMetadata(kind: UInt8) {
        if kind == UInt8(ascii: "L") {
            let name = metadata.prefix { $0 != 0 }
            pendingPath = Self.normalized(String(decoding: name, as: UTF8.self))
            return
        }
        // pax records: "<length> <key>=<value>\n", repeated.
        var index = 0
        while index < metadata.count {
            guard let space = metadata[index...].firstIndex(of: UInt8(ascii: " ")),
                  let length = Int(String(decoding: metadata[index..<space], as: UTF8.self)), length > 0,
                  index + length <= metadata.count else { return }
            var record = metadata[(space + 1)..<(index + length)]
            if record.last == UInt8(ascii: "\n") { record = record.dropLast() }
            if let equals = record.firstIndex(of: UInt8(ascii: "=")),
               String(decoding: record[record.startIndex..<equals], as: UTF8.self) == "path" {
                pendingPath = Self.normalized(String(decoding: record[(equals + 1)...], as: UTF8.self))
            }
            index += length
        }
    }

    private static func headerPath(_ block: [UInt8]) -> String {
        let name = cString(block[0..<100])
        let isUSTAR = Array(block[257..<262]) == Array("ustar".utf8)
        let prefix = isUSTAR ? cString(block[345..<500]) : ""
        return normalized(prefix.isEmpty ? name : prefix + "/" + name)
    }

    private static func normalized(_ path: String) -> String {
        var path = path
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path
    }

    private static func cString(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Octal digits, or GNU base-256 when the first byte's high bit is set.
    private static func size(_ field: ArraySlice<UInt8>) -> Int64? {
        guard let first = field.first else { return nil }
        if first & 0x80 != 0 {
            var value: Int64 = Int64(first & 0x7f)
            for byte in field.dropFirst() {
                guard value <= (Int64.max >> 8) else { return nil }
                value = (value << 8) | Int64(byte)
            }
            return value
        }
        var value: Int64 = 0
        var sawDigit = false
        for byte in field {
            if byte == 0 || byte == UInt8(ascii: " ") {
                if sawDigit { break } else { continue }
            }
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7"), value <= (Int64.max >> 3) else { return nil }
            value = value * 8 + Int64(byte - UInt8(ascii: "0"))
            sawDigit = true
        }
        return value
    }

    private static func padding(after size: Int64) -> Int64 {
        (512 - size % 512) % 512
    }
}
