#if os(macOS)
import Darwin
import Foundation
import XCTest
import SessionKit
import SessionKitAudio

final class PodcastEditionDigestTests: XCTestCase {
    private static let largeFileDigest = "1c5386005b9cc63833a7cac9ee928040d05d4128b81715d893f2e2fb2a3391b7"

    func testRepeatedDigestsAndExactEditionResolutionsKeepMemoryBounded() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let episode = directory.appending(path: "edition.bin")
        // Write a real 64 MiB file without allocating a whole episode in the test itself.
        try writeFixture(to: episode, byteCount: 64 * 1_048_576)

        // Warm FileHandle, CryptoKit and the Mach query before measuring their steady-state growth.
        let warmup = directory.appending(path: "warmup.bin")
        try Data([0xa5]).write(to: warmup)
        try autoreleasepool {
            _ = try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: warmup)
            _ = try physicalFootprint()
        }

        // Don't drain a pool between the direct calls and the resolutions: a placement pass can stack
        // both workloads without suspending. Bound each phase and the complete six-call sequence.
        let before = try physicalFootprint()
        for _ in 0..<3 {
            XCTAssertEqual(try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: episode), Self.largeFileDigest)
        }
        try assertBoundedGrowth(since: before, workload: "three synchronous edition digests")

        let queries = [
            PodcastPortableAnchorQuery(packageScopedId: "placed", senderMediaTimeMs: 120_000, evidence: []),
            PodcastPortableAnchorQuery(packageScopedId: "unplaced", senderMediaTimeMs: nil, evidence: [])
        ]
        let beforeResolution = try physicalFootprint()
        // The equal-digest path returns before any suspension; repeated layer resolutions used to stack
        // the same file's buffers just like the direct calls above. Don't insert a yield or sleep here.
        for _ in 0..<3 {
            let resolutions = try await PodcastAcousticAnchorResolver.resolve(
                queries: queries,
                recipientAudioURL: episode,
                senderExactEditionSHA256: Self.largeFileDigest,
                senderDurationMs: 7_200_000,
                strongSourceIdentity: true
            )
            XCTAssertEqual(resolutions["placed"]?.evidenceClass, .exactEdition)
            XCTAssertEqual(resolutions["placed"]?.localMediaTimeMs, 120_000)
            XCTAssertEqual(resolutions["unplaced"]?.evidenceClass, .unresolved)
            XCTAssertNil(resolutions["unplaced"]?.localMediaTimeMs)
        }
        try assertBoundedGrowth(since: beforeResolution, workload: "three exact-edition resolutions")
        try assertBoundedGrowth(since: before, workload: "three digests followed by three exact-edition resolutions")
    }

    func testDigestIncludesPartialFinalChunkAndHandlesEmptyFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "partial.bin")
        try writeFixture(to: source, byteCount: 1_048_576 + 37)
        XCTAssertEqual(
            try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: source),
            "684bfb86c2c94bf16544c97032fe6d86847d76c404bdbed4f6d4d9f910c6fd66"
        )
        let empty = directory.appending(path: "empty.bin")
        try Data().write(to: empty)
        XCTAssertEqual(
            try PodcastAnchorEvidenceGenerator.exactEditionSHA256(of: empty),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertThrowsError(try PodcastAnchorEvidenceGenerator.exactEditionSHA256(
            of: directory.appending(path: "missing.bin")
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "podcast-edition-digest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeFixture(to url: URL, byteCount: Int) throws {
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = Data(repeating: 0xa5, count: 1_048_576)
        var remaining = byteCount
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            try handle.write(contentsOf: chunk.prefix(count))
            remaining -= count
        }
    }

    private func physicalFootprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(domain: NSMachErrorDomain, code: Int(result))
        }
        return UInt64(info.phys_footprint)
    }

    private func assertBoundedGrowth(since before: UInt64, workload: String) throws {
        let after = try physicalFootprint()
        let growth = after > before ? after - before : 0
        print("Edition digest footprint: \(workload), growth \(growth) bytes")
        XCTAssertLessThanOrEqual(growth, 16 * 1_048_576, workload)
    }
}
#endif
