import XCTest
@testable import SessionKit

/// #4683, Design section 2g: the folder a Shortcuts action saves link lists in, on a real temporary directory.
final class LinkListHandoffFolderTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private func list(_ title: String? = "Morning brief", extra: Int = 0) -> LinkListFile {
        var entries: [LinkListFile.Entry] = [
            .init(url: "https://example.com/a", title: "A"),
            .init(url: "https://example.com/feed", follow: true),
        ]
        for index in 0..<extra { entries.append(.init(url: "https://example.com/x\(index)")) }
        return LinkListFile(title: title, entries: entries)
    }

    private func clock(_ times: [TimeInterval]) -> @Sendable () -> Date {
        let box = Box(times)
        return { box.next() }
    }

    private final class Box: @unchecked Sendable {
        private var times: [TimeInterval]
        private let lock = NSLock()
        init(_ times: [TimeInterval]) { self.times = times }
        func next() -> Date {
            lock.withLock { Date(timeIntervalSince1970: times.count > 1 ? times.removeFirst() : times[0]) }
        }
    }

    func testConstants() {
        XCTAssertEqual(LinkListHandoffFolder.maxFiles, 20)
        XCTAssertEqual(LinkListHandoffFolder.maxFileBytes, LinkListFile.maxFileBytes)
        XCTAssertEqual(LinkListHandoffFolder.directoryName, "LinkListHandoffs")
    }

    func testWriteListReadAndRemove() throws {
        let folder = LinkListHandoffFolder(baseDirectory: base)
        XCTAssertEqual(folder.pending(), [], "no folder yet means nothing waiting")

        let saved = try folder.save(list())
        XCTAssertEqual(folder.pending(), [saved])
        XCTAssertTrue(saved.url.path.contains("/LinkListHandoffs/"))

        guard case .linkList(let back) = folder.read(saved) else { return XCTFail("the saved file must read back as a list") }
        XCTAssertEqual(back.title, "Morning brief")
        XCTAssertEqual(back.entries, list().entries)

        folder.remove(saved)
        folder.remove(saved)
        XCTAssertEqual(folder.pending(), [])
        XCTAssertEqual(folder.read(saved), .notALinkList, "a removed file reads as nothing, not a crash")
    }

    func testFileNameIsUTCStampThenUUID() throws {
        let when = Date(timeIntervalSince1970: 1_795_435_200 + 7) // 2026-11-23 12:00:07 UTC
        let folder = LinkListHandoffFolder(baseDirectory: base, now: clock([when.timeIntervalSince1970]))
        let entry = try folder.save(list())
        XCTAssertTrue(entry.id.hasPrefix("20261123T120007Z-"), entry.id)
        XCTAssertTrue(entry.id.hasSuffix(".json"))
        XCTAssertTrue(LinkListHandoffFolder.isHandoffName(entry.id))
        XCTAssertEqual(entry.id.count, "20261123T120007Z-".count + 36 + ".json".count)
    }

    func testOrderIsByNameOldestFirstWhateverTheWriteOrder() throws {
        // The clock runs backwards between writes, so the write order and the name order differ.
        let folder = LinkListHandoffFolder(baseDirectory: base, now: clock([1_795_435_300, 1_795_435_100, 1_795_435_200]))
        let late = try folder.save(list("late"))
        let early = try folder.save(list("early"))
        let middle = try folder.save(list("middle"))
        XCTAssertEqual(folder.pending().map(\.id), [early.id, middle.id, late.id])
    }

    func testTheTwentyFirstWriteIsFullAndLeavesNothingBehind() throws {
        let folder = LinkListHandoffFolder(baseDirectory: base)
        for index in 0..<LinkListHandoffFolder.maxFiles { try folder.save(list("list \(index)")) }
        XCTAssertEqual(folder.pending().count, 20)
        XCTAssertThrowsError(try folder.save(list("one too many"))) { error in
            XCTAssertEqual(error as? LinkListHandoffFolder.SaveError, .full)
            XCTAssertEqual((error as? LinkListHandoffFolder.SaveError)?.message,
                           "Spoken Margins already has 20 lists waiting. Open the app to add them first.")
        }
        XCTAssertEqual(folder.pending().count, 20)
        // Freeing one makes room again.
        folder.remove(folder.pending()[0])
        XCTAssertNoThrow(try folder.save(list("fits now")))
        XCTAssertEqual(folder.pending().count, 20)
    }

    func testANewInstanceOverTheSameDirectorySeesTheFiles() throws {
        let first = LinkListHandoffFolder(baseDirectory: base)
        let saved = try first.save(list())
        let second = LinkListHandoffFolder(baseDirectory: base)
        XCTAssertEqual(second.pending(), [saved])
        guard case .linkList(let back) = second.read(saved) else { return XCTFail("not a list") }
        XCTAssertEqual(back.title, "Morning brief")
    }

    func testTheInjectedWriterSawAtomicAndFileProtectionOptions() throws {
        let seen = OptionsBox()
        let folder = LinkListHandoffFolder(baseDirectory: base, writer: { data, url, options in
            seen.record(options)
            try data.write(to: url, options: options)
        })
        try folder.save(list())
        XCTAssertEqual(seen.all.count, 1)
        let options = try XCTUnwrap(seen.all.first)
        XCTAssertTrue(options.contains(.atomic))
        XCTAssertTrue(options.contains(.completeFileProtectionUntilFirstUserAuthentication))
    }

    private final class OptionsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Data.WritingOptions] = []
        func record(_ options: Data.WritingOptions) { lock.withLock { stored.append(options) } }
        var all: [Data.WritingOptions] { lock.withLock { stored } }
    }

    func testAFailedWriteIsReportedAndLeavesNothing() throws {
        struct Boom: Error {}
        let folder = LinkListHandoffFolder(baseDirectory: base, writer: { _, _, _ in throw Boom() })
        XCTAssertThrowsError(try folder.save(list())) { XCTAssertEqual($0 as? LinkListHandoffFolder.SaveError, .couldNotWrite) }
        XCTAssertEqual(folder.pending(), [])
    }

    func testOversizedListIsRefusedBeforeAnythingIsWritten() throws {
        let folder = LinkListHandoffFolder(baseDirectory: base)
        let huge = LinkListFile(title: String(repeating: "t", count: LinkListHandoffFolder.maxFileBytes), entries: [.init(url: "https://example.com/a")])
        XCTAssertThrowsError(try folder.save(huge)) { XCTAssertEqual($0 as? LinkListHandoffFolder.SaveError, .tooLarge) }
        XCTAssertEqual(folder.pending(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(LinkListHandoffFolder.directoryName).path)
                       && !((try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent(LinkListHandoffFolder.directoryName).path)) ?? []).isEmpty)
    }

    func testAFolderThatCannotBeListedIsAFailedSaveNotARawError() throws {
        // A plain file where the folder should be: neither creating nor listing it can work.
        try Data("x".utf8).write(to: base.appendingPathComponent(LinkListHandoffFolder.directoryName))
        let folder = LinkListHandoffFolder(baseDirectory: base)
        XCTAssertThrowsError(try folder.save(list())) { XCTAssertEqual($0 as? LinkListHandoffFolder.SaveError, .couldNotWrite) }
        XCTAssertEqual(folder.pending(), [])
    }

    func testFilesThatAreNotThisFoldersNamesAreIgnoredAndNotCounted() throws {
        let folder = LinkListHandoffFolder(baseDirectory: base)
        let saved = try folder.save(list())
        let directory = base.appendingPathComponent(LinkListHandoffFolder.directoryName)
        for stray in [".DS_Store", "notes.json", "20261123T120007Z-not-a-uuid.json", "\(saved.id).tmp", "\(saved.id)-copy.json"] {
            try Data("x".utf8).write(to: directory.appendingPathComponent(stray))
        }
        XCTAssertEqual(folder.pending(), [saved])
        // Strays don't use up the 20.
        for _ in 1..<LinkListHandoffFolder.maxFiles { try folder.save(list()) }
        XCTAssertEqual(folder.pending().count, 20)
    }

    func testAnUnreadableOrOversizedFileSaysSoForTheCaller() throws {
        let folder = LinkListHandoffFolder(baseDirectory: base)
        let directory = base.appendingPathComponent(LinkListHandoffFolder.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func plant(_ name: String, _ bytes: Data) throws -> LinkListHandoffFolder.Entry {
            let id = LinkListHandoffFolder.fileName(date: Date(), id: UUID())
            _ = name
            let url = directory.appendingPathComponent(id)
            try bytes.write(to: url)
            return .init(id: id, url: url)
        }

        let notJSON = try plant("garbage", Data("not json".utf8))
        XCTAssertEqual(folder.read(notJSON), .notALinkList)

        let wrongSchema = try plant("other", Data(#"{"schemaVersion":"spoken-margins.link-list.v9","entries":[]}"#.utf8))
        guard case .rejected = folder.read(wrongSchema) else { return XCTFail("a newer version is refused with a message") }

        let big = try plant("big", Data(repeating: 0x20, count: LinkListHandoffFolder.maxFileBytes + 1))
        XCTAssertEqual(folder.read(big), .rejected(LinkListFile.tooLargeMessage))
    }

    func testEncodingRoundTripsEveryField() throws {
        let original = LinkListFile(title: "Brief with \"quotes\", a / slash and ünïcode 🌱", entries: [
            .init(url: "https://example.com/a?x=1&y=2", title: "Title one"),
            .init(url: "https://example.com/feed", follow: true),
            .init(url: "https://example.com/b", title: "Feed title", follow: true),
        ])
        let data = try LinkListHandoffFolder.encode(original)
        guard case .linkList(let back) = LinkListFile.recognize(data) else { return XCTFail("not a list") }
        XCTAssertEqual(back.title, original.title)
        XCTAssertEqual(back.entries, original.entries)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\\/"), "slashes are not escaped")
        // An untitled list and an entry with no title or follow write no empty fields.
        let plain = try LinkListHandoffFolder.encode(LinkListFile(title: nil, entries: [.init(url: "https://example.com/a")]))
        XCTAssertEqual(String(decoding: plain, as: UTF8.self),
                       #"{"entries":[{"url":"https://example.com/a"}],"schemaVersion":"spoken-margins.link-list.v1"}"#)
    }

    func testAFileSavedTodayIsThePathAShortcutTextTakes() throws {
        // The Shortcut's text path: a whole AI reply goes through LinkListText.find, then is saved, then drained.
        let reply = """
        Here is your brief:
        ```json
        {"schemaVersion": "spoken-margins.link-list.v1", "title": "Morning brief, November 23",
         "entries": [{"url": "https://example.com/a"}, {"url": "https://example.com/feed", "follow": true}]}
        ```
        """
        guard case .linkList(let found) = LinkListText.find(in: reply) else { return XCTFail("not a list") }
        let folder = LinkListHandoffFolder(baseDirectory: base)
        let saved = try folder.save(found)
        guard case .linkList(let drained) = folder.read(saved) else { return XCTFail("not a list") }
        XCTAssertEqual(drained.title, "Morning brief, November 23")
        XCTAssertEqual(drained.entries.map(\.follow), [false, true])
    }
}
