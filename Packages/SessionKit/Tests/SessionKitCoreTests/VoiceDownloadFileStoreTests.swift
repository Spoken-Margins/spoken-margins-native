import XCTest
@testable import SessionKit

/// #318 (from #1819): the files the background voice download keeps between launches, and the parsing it does on
/// task descriptions and `Content-Range`. Real temporary files; the background URLSession itself is Apple-only and
/// is not exercised here.
final class VoiceDownloadFileStoreTests: XCTestCase {
    private var root: URL!
    private var store: VoiceDownloadFileStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "voice-download-files-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A folder that does not exist yet: the store makes it when it first needs it, as the app's Caches one does.
        store = VoiceDownloadFileStore(folder: root.appending(path: "VoiceDownloads", directoryHint: .isDirectory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let model = URL(string: "https://huggingface.co/example/voice/resolve/0123456789abcdef0123456789abcdef01234567/onnx/model.onnx")!
    private let voices = URL(string: "https://huggingface.co/example/voice/resolve/0123456789abcdef0123456789abcdef01234567/voices/alba.bin")!

    private func write(_ bytes: Data, named name: String = UUID().uuidString) throws -> URL {
        let file = root.appending(path: name)
        try bytes.write(to: file)
        return file
    }

    // MARK: Range header

    func testRangeStartReadsTheFirstByteOfAPartialBody() {
        let rows: [(String?, Int?)] = [
            ("bytes 100-199/200", 100),
            ("bytes 0-0/1", 0),
            ("BYTES 5-9/10", 5),
            ("Bytes 5-9/*", 5),
            ("bytes 100-", 100),
            ("bytes 100", 100),
            ("bytes */200", nil),
            ("bytes ", nil),
            ("bytes", nil),
            ("items 1-2/3", nil),
            ("", nil),
            (nil, nil),
            ("bytes 99999999999999999999-100000000000000000000/*", nil),
            ("bytes -5/10", nil)
        ]
        for (header, expected) in rows {
            XCTAssertEqual(VoiceDownloadFileStore.rangeStart(header), expected, header ?? "nil")
        }
    }

    // MARK: Task descriptions

    func testATaskDescriptionGivesBackItsOffsetAndURL() {
        let urls = [
            model,
            URL(string: "https://example.com/a%20b.bin?token=1&x=y#frag")!,
            URL(string: "http://127.0.0.1:8080/file")!
        ]
        for url in urls {
            for offset in [0, 1, 141_000_000] {
                let description = VoiceDownloadFileStore.describe(url: url, offset: offset)
                XCTAssertEqual(VoiceDownloadFileStore.offset(fromDescription: description), offset, description)
                XCTAssertEqual(VoiceDownloadFileStore.url(fromDescription: description), url, description)
            }
        }
    }

    func testTaskDescriptionsOfTheSameURLAtDifferentOffsetsDiffer() {
        XCTAssertNotEqual(
            VoiceDownloadFileStore.describe(url: model, offset: 0),
            VoiceDownloadFileStore.describe(url: model, offset: 10)
        )
    }

    func testNoDescriptionGivesNoOffsetOrURL() {
        XCTAssertNil(VoiceDownloadFileStore.offset(fromDescription: nil))
        XCTAssertNil(VoiceDownloadFileStore.url(fromDescription: nil))
        XCTAssertNil(VoiceDownloadFileStore.offset(fromDescription: ""))
        XCTAssertNil(VoiceDownloadFileStore.offset(fromDescription: "later https://example.com/a"))
    }

    // MARK: File names

    func testAFileNameIsStableAndSafeInAPath() {
        for url in [model, voices, URL(string: "https://a.example/?q=a+b/c==")!, URL(string: "https://x.example/")!] {
            let name = VoiceDownloadFileStore.name(for: url)
            XCTAssertEqual(name, VoiceDownloadFileStore.name(for: url))
            XCTAssertFalse(name.isEmpty)
            XCTAssertLessThanOrEqual(name.count, 120)
            for forbidden in ["/", "+", "="] {
                XCTAssertFalse(name.contains(forbidden), "\(name) holds \(forbidden)")
            }
        }
    }

    func testTheTwoFilesOfAVoiceGetDifferentNames() {
        XCTAssertNotEqual(VoiceDownloadFileStore.name(for: model), VoiceDownloadFileStore.name(for: voices))
    }

    // MARK: Names a relaunch depends on

    /// iOS keeps a task's description across a relaunch, and the folder keeps its files: a change to any of these
    /// would orphan a running task, a kept file or saved resume data from the build before, so each is pinned.
    func testTheFormatsAnEarlierBuildLeftBehindStillReadTheSame() throws {
        let url = URL(string: "https://example.com/a.bin")!
        XCTAssertEqual(VoiceDownloadFileStore.describe(url: url, offset: 10), "10 https://example.com/a.bin")
        XCTAssertEqual(VoiceDownloadFileStore.name(for: url), "aHR0cHM6Ly9leGFtcGxlLmNvbS9hLmJpbg")
        XCTAssertEqual(VoiceDownloadFileStore.inCaches().folder.lastPathComponent, "VoiceDownloads")

        store.saveResumeData(Data("r".utf8), for: url)
        store.keep(try XCTUnwrap(store.adopt(try write(Data("w".utf8)))), for: url)
        let names = try FileManager.default.contentsOfDirectory(atPath: store.folder.path).sorted()
        XCTAssertEqual(names, ["done-aHR0cHM6Ly9leGFtcGxlLmNvbS9hLmJpbg", "resume-aHR0cHM6Ly9leGFtcGxlLmNvbS9hLmJpbg"])
    }

    // MARK: Kept files

    func testAKeptFileIsServedForItsURLOnly() throws {
        XCTAssertNil(store.keptFile(for: model), "nothing kept yet, and the folder does not exist yet")
        // As the transport does it: the finished file is adopted into the folder, and kept if nobody is waiting.
        let whole = try XCTUnwrap(store.adopt(try write(Data("whole voice".utf8))))

        store.keep(whole, for: model)

        let kept = try XCTUnwrap(store.keptFile(for: model))
        XCTAssertEqual(try Data(contentsOf: kept), Data("whole voice".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: whole.path), "the file was moved, not copied")
        XCTAssertNil(store.keptFile(for: voices), "another file of the same voice is not served this one")
    }

    func testKeepingAFileAgainReplacesTheEarlierOne() throws {
        store.keep(try XCTUnwrap(store.adopt(try write(Data("first".utf8)))), for: model)
        store.keep(try XCTUnwrap(store.adopt(try write(Data("second".utf8)))), for: model)

        let kept = try XCTUnwrap(store.keptFile(for: model))
        XCTAssertEqual(try Data(contentsOf: kept), Data("second".utf8))
    }

    // MARK: Resume data

    func testResumeDataComesBackOnceForItsURL() {
        XCTAssertNil(store.takeResumeData(for: model), "nothing saved yet, and the folder does not exist yet")

        store.saveResumeData(Data("resume".utf8), for: model)

        XCTAssertNil(store.takeResumeData(for: voices))
        XCTAssertEqual(store.takeResumeData(for: model), Data("resume".utf8))
        XCTAssertNil(store.takeResumeData(for: model), "taken once: a second download starts over")
    }

    func testSavingResumeDataAgainReplacesTheEarlierData() {
        store.saveResumeData(Data("old".utf8), for: model)
        store.saveResumeData(Data("new".utf8), for: model)
        XCTAssertEqual(store.takeResumeData(for: model), Data("new".utf8))
    }

    func testResumeDataAndAKeptFileOfOneURLDoNotClash() throws {
        store.saveResumeData(Data("resume".utf8), for: model)
        store.keep(try XCTUnwrap(store.adopt(try write(Data("whole".utf8)))), for: model)

        XCTAssertEqual(store.takeResumeData(for: model), Data("resume".utf8))
        XCTAssertNotNil(store.keptFile(for: model))
    }

    // MARK: Adopting a finished download

    func testAdoptingMovesTheFileOutOfUrlSessionsReachIntoTheFolder() throws {
        let temporary = try write(Data("downloaded".utf8))

        let adopted = try XCTUnwrap(store.adopt(temporary))

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertEqual(try Data(contentsOf: adopted), Data("downloaded".utf8))
        XCTAssertEqual(adopted.deletingLastPathComponent().standardizedFileURL, store.folder.standardizedFileURL)
        XCTAssertTrue(adopted.lastPathComponent.hasPrefix("task-"))
    }

    func testAdoptingTwoFilesGivesTwoNames() throws {
        let first = try XCTUnwrap(store.adopt(try write(Data("a".utf8))))
        let second = try XCTUnwrap(store.adopt(try write(Data("b".utf8))))
        XCTAssertNotEqual(first, second)
    }

    func testAdoptingAFileThatIsGoneGivesNil() {
        XCTAssertNil(store.adopt(root.appending(path: "missing")))
    }

    // MARK: Delivering a file

    private func deliver(_ file: URL, status: Int = 200) throws -> (heads: [VoiceModelResponseHead], body: Data) {
        var heads: [VoiceModelResponseHead] = []
        var body = Data()
        try VoiceDownloadFileStore.deliver(
            file,
            head: VoiceModelResponseHead(statusCode: status),
            onHead: { heads.append($0); return true },
            onChunk: { body.append($0) }
        )
        return (heads, body)
    }

    func testDeliveringAFileSendsTheHeadThenEveryByteInOrder() throws {
        // More than two 1 MiB pieces, so the read loop runs more than once and the last piece is short.
        let bytes = Data((0..<(2 * 1024 * 1024 + 12_345)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        let file = try write(bytes)

        let delivered = try deliver(file)

        XCTAssertEqual(delivered.heads, [VoiceModelResponseHead(statusCode: 200)])
        XCTAssertEqual(delivered.body.count, bytes.count)
        XCTAssertEqual(delivered.body, bytes)
    }

    func testDeliveringAnEmptyFileSendsTheHeadAndNoBody() throws {
        let delivered = try deliver(try write(Data()))
        XCTAssertEqual(delivered.heads.count, 1)
        XCTAssertTrue(delivered.body.isEmpty)
    }

    func testDeliveringStopsWithoutAnErrorWhenTheHeadSaysNotToReadTheBody() throws {
        let file = try write(Data("body".utf8))
        var chunks = 0
        try VoiceDownloadFileStore.deliver(
            file,
            head: VoiceModelResponseHead(statusCode: 416),
            onHead: { _ in false },
            onChunk: { _ in chunks += 1 }
        )
        XCTAssertEqual(chunks, 0)
    }

    func testDeliveringRethrowsWhatTheHeadOrAChunkThrows() throws {
        struct Refused: Error {}
        let file = try write(Data(count: 3 * 1024 * 1024))

        XCTAssertThrowsError(try VoiceDownloadFileStore.deliver(
            file, head: VoiceModelResponseHead(statusCode: 200), onHead: { _ in throw Refused() }, onChunk: { _ in }
        )) { XCTAssertTrue($0 is Refused) }

        var chunks = 0
        XCTAssertThrowsError(try VoiceDownloadFileStore.deliver(
            file, head: VoiceModelResponseHead(statusCode: 200), onHead: { _ in true },
            onChunk: { _ in chunks += 1; throw Refused() }
        )) { XCTAssertTrue($0 is Refused) }
        XCTAssertEqual(chunks, 1, "the first failure ends the delivery")
    }

    func testDeliveringAFileThatIsGoneThrowsAfterTheHead() {
        var heads = 0
        XCTAssertThrowsError(try VoiceDownloadFileStore.deliver(
            root.appending(path: "missing"), head: VoiceModelResponseHead(statusCode: 200),
            onHead: { _ in heads += 1; return true }, onChunk: { _ in }
        ))
        XCTAssertEqual(heads, 1)
    }

    func testDeliveringKeepsThePartialBodyHeadOfAContinuedDownload() throws {
        let file = try write(Data("tail".utf8))
        var head: VoiceModelResponseHead?
        try VoiceDownloadFileStore.deliver(
            file,
            head: VoiceModelResponseHead(statusCode: 206, contentRangeStart: VoiceDownloadFileStore.rangeStart("bytes 100-103/104")),
            onHead: { head = $0; return true },
            onChunk: { _ in }
        )
        XCTAssertEqual(head, VoiceModelResponseHead(statusCode: 206, contentRangeStart: 100))
    }
}
