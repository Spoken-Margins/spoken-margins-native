import Foundation
#if canImport(Compression)
import Compression
#endif

// Taking members out of a `.zip` a voice is published in (#2704). Gradium ships Phonon's Core ML bundle only as
// `phonon-31m-en-coreml.zip`, a release asset of `gradium-ai/xn-ptts`, so the installer downloads it once, checks its
// hash, and reads it through here. Like the tar reader, nothing is extracted by its own name: each wanted member's
// bytes go to the installer, which writes them to the catalog's path and checks them against the catalog's hash.
//
// The reader works from the central directory at the end of the file, which is the zip's own index, and reads each
// member's data where its local header says. Members are stored or deflated, the only two methods any common zip tool
// writes. Encrypted members, zip64 archives (over 4 GB, or 65,535 members) and other methods are refused rather
// than half read: no voice is near those limits, and an archive that needs them isn't the one the catalog reviewed.

public enum ZipArchiveReader {
    /// `zip` where Apple's Compression framework is there to inflate deflated members (macOS, iOS).
    public static var isAvailable: Bool {
        #if canImport(Compression)
        true
        #else
        false
        #endif
    }

    public static var formats: Set<String> { isAvailable ? ["zip"] : [] }

    /// One central-directory record.
    struct Entry: Equatable {
        var path: String
        var method: UInt16
        var flags: UInt16
        var compressedSize: Int64
        var size: Int64
        var localHeaderOffset: Int64
    }

    /// Calls `onMember` for every regular file in the archive, in central-directory order; when it returns true,
    /// streams the member's uncompressed bytes to `onData` and then calls `onMemberEnd`. Folders are skipped.
    /// Whatever a callback throws ends the read and is rethrown.
    public static func read(
        _ url: URL,
        onMember: (TarStreamReader.Member) throws -> Bool,
        onData: (Data) throws -> Void,
        onMemberEnd: (TarStreamReader.Member) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = Int64(try handle.seekToEnd())
        for entry in try centralDirectory(handle, length: length) {
            if entry.path.hasSuffix("/") { continue }
            let member = TarStreamReader.Member(path: entry.path, size: entry.size)
            guard try onMember(member) else { continue }
            guard entry.flags & 0x1 == 0 else { throw VoiceModelArchiveError.corrupt("\(entry.path) is encrypted") }
            let start = try dataOffset(of: entry, in: handle, length: length)
            guard start + entry.compressedSize <= length else { throw VoiceModelArchiveError.truncated }
            var produced: Int64 = 0
            let counting: (Data) throws -> Void = { chunk in
                produced += Int64(chunk.count)
                guard produced <= entry.size else { throw VoiceModelArchiveError.corrupt("\(entry.path) inflates past its stated size") }
                try onData(chunk)
            }
            try handle.seek(toOffset: UInt64(start))
            switch entry.method {
            case 0:
                guard entry.compressedSize == entry.size else { throw VoiceModelArchiveError.corrupt("\(entry.path) is stored with two sizes") }
                try copy(entry.compressedSize, from: handle, to: counting)
            case 8:
                try inflate(entry.compressedSize, from: handle, to: counting)
            default:
                throw VoiceModelArchiveError.corrupt("\(entry.path) uses compression method \(entry.method)")
            }
            guard produced == entry.size else { throw VoiceModelArchiveError.truncated }
            try onMemberEnd(member)
        }
    }

    // MARK: The index

    static let endRecordSignature: UInt32 = 0x0605_4b50
    static let centralRecordSignature: UInt32 = 0x0201_4b50
    static let localHeaderSignature: UInt32 = 0x0403_4b50
    /// The end record is 22 bytes plus a comment of at most 65,535.
    static let endRecordSearch: Int64 = 22 + 65_535

    static func centralDirectory(_ handle: FileHandle, length: Int64) throws -> [Entry] {
        guard length >= 22 else { throw VoiceModelArchiveError.corrupt("too short to be a zip") }
        let tailStart = max(0, length - endRecordSearch)
        try handle.seek(toOffset: UInt64(tailStart))
        let tail = [UInt8](try handle.readToEnd() ?? Data())
        var found: Int?
        var index = tail.count - 22
        while index >= 0 {
            if le32(tail, index) == endRecordSignature, index + 22 + Int(le16(tail, index + 20)) == tail.count {
                found = index
                break
            }
            index -= 1
        }
        guard let end = found else { throw VoiceModelArchiveError.corrupt("no zip end record") }
        let count = Int(le16(tail, end + 10))
        let directorySize = Int64(le32(tail, end + 12))
        let directoryOffset = Int64(le32(tail, end + 16))
        guard count != 0xffff, directorySize != 0xffff_ffff, directoryOffset != 0xffff_ffff else {
            throw VoiceModelArchiveError.corrupt("zip64 archives aren't read")
        }
        guard directoryOffset + directorySize <= tailStart + Int64(end) else { throw VoiceModelArchiveError.truncated }
        try handle.seek(toOffset: UInt64(directoryOffset))
        let directory = [UInt8](try handle.read(upToCount: Int(directorySize)) ?? Data())
        guard directory.count == Int(directorySize) else { throw VoiceModelArchiveError.truncated }

        var entries: [Entry] = []
        var cursor = 0
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, le32(directory, cursor) == centralRecordSignature else {
                throw VoiceModelArchiveError.corrupt("a zip directory record is damaged")
            }
            let nameLength = Int(le16(directory, cursor + 28))
            let extraLength = Int(le16(directory, cursor + 30))
            let commentLength = Int(le16(directory, cursor + 32))
            guard cursor + 46 + nameLength + extraLength + commentLength <= directory.count else { throw VoiceModelArchiveError.truncated }
            let compressed = le32(directory, cursor + 20)
            let size = le32(directory, cursor + 24)
            let offset = le32(directory, cursor + 42)
            guard compressed != 0xffff_ffff, size != 0xffff_ffff, offset != 0xffff_ffff else {
                throw VoiceModelArchiveError.corrupt("zip64 members aren't read")
            }
            let name = String(decoding: directory[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(
                path: normalized(name),
                method: le16(directory, cursor + 10),
                flags: le16(directory, cursor + 8),
                compressedSize: Int64(compressed),
                size: Int64(size),
                localHeaderOffset: Int64(offset)
            ))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Where the member's data starts: after its local header, whose name and extra field can differ in length
    /// from the central record's.
    static func dataOffset(of entry: Entry, in handle: FileHandle, length: Int64) throws -> Int64 {
        guard entry.localHeaderOffset + 30 <= length else { throw VoiceModelArchiveError.truncated }
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        guard header.count == 30, le32(header, 0) == localHeaderSignature else {
            throw VoiceModelArchiveError.corrupt("\(entry.path) has no local header")
        }
        return entry.localHeaderOffset + 30 + Int64(le16(header, 26)) + Int64(le16(header, 28))
    }

    private static func normalized(_ path: String) -> String {
        var path = path
        while path.hasPrefix("./") { path.removeFirst(2) }
        return path
    }

    private static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    // MARK: The data

    static let chunkSize = 1 << 20

    private static func copy(_ count: Int64, from handle: FileHandle, to sink: (Data) throws -> Void) throws {
        var left = count
        while left > 0 {
            let block = try handle.read(upToCount: Int(min(left, Int64(chunkSize)))) ?? Data()
            guard !block.isEmpty else { throw VoiceModelArchiveError.truncated }
            left -= Int64(block.count)
            try sink(block)
        }
    }

    private static func inflate(_ count: Int64, from handle: FileHandle, to sink: (Data) throws -> Void) throws {
        #if canImport(Compression)
        // COMPRESSION_ZLIB is raw deflate (RFC 1951), which is what a zip member holds.
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw VoiceModelArchiveError.corrupt("the inflater would not start")
        }
        defer { compression_stream_destroy(streamPointer) }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { output.deallocate() }
        var left = count
        var finished = false
        while !finished {
            let block = left > 0 ? (try handle.read(upToCount: Int(min(left, Int64(chunkSize)))) ?? Data()) : Data()
            if left > 0, block.isEmpty { throw VoiceModelArchiveError.truncated }
            left -= Int64(block.count)
            let flags = left == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            try block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                streamPointer.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(output)
                streamPointer.pointee.src_size = block.count
                repeat {
                    streamPointer.pointee.dst_ptr = output
                    streamPointer.pointee.dst_size = chunkSize
                    let status = compression_stream_process(streamPointer, flags)
                    let produced = chunkSize - streamPointer.pointee.dst_size
                    if produced > 0 { try sink(Data(bytes: output, count: produced)) }
                    switch status {
                    case COMPRESSION_STATUS_OK:
                        if left == 0, streamPointer.pointee.src_size == 0, produced == 0 {
                            throw VoiceModelArchiveError.truncated
                        }
                    case COMPRESSION_STATUS_END:
                        finished = true
                    default:
                        throw VoiceModelArchiveError.corrupt("a deflated member is damaged")
                    }
                } while !finished && (streamPointer.pointee.src_size > 0 || streamPointer.pointee.dst_size == 0)
            }
        }
        #else
        throw VoiceModelArchiveError.corrupt("zip can't be opened here")
        #endif
    }
}
