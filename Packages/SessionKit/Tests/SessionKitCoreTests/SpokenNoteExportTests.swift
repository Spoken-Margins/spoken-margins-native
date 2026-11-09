import XCTest
@testable import SessionKit

/// #3660: Export gets a spoken note's audio (every take as one file) and transcript out of the app, from real files in a
/// real temporary folder. The audio join itself is AVFoundation's and is tested with real audio in SessionKitTests
/// (`SpokenNoteAudioJoinerTests`); here the joiner only records what it was asked to join.
final class SpokenNoteExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spoken-note-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private struct RecordingJoiner: SpokenNoteAudioJoining {
        let joined = Box()
        final class Box: @unchecked Sendable { var sources: [[URL]] = [] }
        var skipping = 0
        func join(_ sources: [URL], to destination: URL) async throws -> Int {
            joined.sources.append(sources)
            try Data("joined:\(sources.map(\.lastPathComponent).joined(separator: ","))".utf8).write(to: destination)
            return skipping
        }
    }

    private struct FailingJoiner: SpokenNoteAudioJoining {
        func join(_ sources: [URL], to destination: URL) async throws -> Int {
            try Data("half".utf8).write(to: destination)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func take(_ id: String, sentences: [String] = [], writeAudio: Bool = true, in folder: URL) throws -> SpokenNoteTake {
        if writeAudio { try Data("audio-\(id)".utf8).write(to: folder.appendingPathComponent("\(id).m4a")) }
        return SpokenNoteTake(
            id: id, audioFileName: "\(id).m4a", durationMs: 4000, createdAt: Date(timeIntervalSince1970: 0),
            sentences: sentences.enumerated().map { SpokenNoteSentence(text: $1, startMs: $0 * 1000, endMs: $0 * 1000 + 900) })
    }

    private func noteFolder() throws -> URL {
        let folder = root.appendingPathComponent("note", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var exports: URL { root.appendingPathComponent("exports", isDirectory: true) }

    // MARK: transcript

    func testTheTranscriptKeepsEverySentenceWithABlankLineBetweenTakes() throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["First idea.", "Second idea."], in: folder))
        note.appendTake(try take("b", sentences: [], in: folder))
        note.appendTake(try take("c", sentences: ["Third idea."], in: folder))
        XCTAssertEqual(SpokenNoteExport.transcriptText(of: note), "First idea. Second idea.\n\nThird idea.")
        XCTAssertEqual(SpokenNoteExport.transcriptText(of: SpokenNote(id: "empty")), "")
    }

    // MARK: text only

    func testTextOnlyPutsTheTitleOnTopAndEveryTakesWordsInOrder() throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["First idea.", "Second idea."], in: folder))
        note.appendTake(try take("b", sentences: ["Third idea."], in: folder))
        note.appendTake(try take("c", sentences: ["Fourth idea."], in: folder))

        let export = try SpokenNoteExport.prepareText(note: note, title: "Shop plans", into: exports)

        let expected = "Shop plans\n\nFirst idea. Second idea.\n\nThird idea.\n\nFourth idea."
        XCTAssertEqual(export.text, expected)
        XCTAssertEqual(export.fileURL.lastPathComponent, "Shop plans.txt")
        XCTAssertEqual(try String(contentsOf: export.fileURL, encoding: .utf8), expected)
        XCTAssertFalse(export.isPartial)
    }

    func testTextOnlyNeedsNoAudioOnThisPhone() throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Still here."], writeAudio: false, in: folder))
        XCTAssertEqual(try SpokenNoteExport.prepareText(note: note, title: "Gone", into: exports).text, "Gone\n\nStill here.")
    }

    func testTextOnlySaysSoWhenATakeHasNoWords() throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Heard."], in: folder))
        note.appendTake(try take("b", sentences: [], in: folder))
        let export = try SpokenNoteExport.prepareText(note: note, title: "Half", into: exports)
        XCTAssertEqual(export.takesWithoutWordsCount, 1)
        XCTAssertTrue(export.isPartial)
    }

    func testANoteWithNoWordsIsNeverAnEmptyShare() throws {
        let folder = try noteFolder()
        var silent = SpokenNote(id: "n")
        silent.appendTake(try take("a", sentences: [], in: folder))
        var blank = SpokenNote(id: "b")
        blank.appendTake(try take("b", sentences: ["  \n "], in: folder))

        for note in [SpokenNote(id: "empty"), silent, blank] {
            XCTAssertNil(SpokenNoteExport.plainText(of: note, title: "Title"))
            XCTAssertThrowsError(try SpokenNoteExport.prepareText(note: note, title: "Title", into: exports)) {
                XCTAssertEqual($0 as? SpokenNoteExportError, .noWordsYet)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path), "no folder is left behind")
    }

    /// The title at the top of the text and the name of the file are held to different rules: the text keeps every word,
    /// the file name has to be one a file system can hold.
    func testTextOnlyTitlesAndFileNames() throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Words."], in: folder))
        let long = String(repeating: "Très long titre ", count: 40).trimmingCharacters(in: .whitespaces)
        let rows: [(title: String, top: String, file: String)] = [
            ("Café 日本語 🎧", "Café 日本語 🎧", "Café 日本語 🎧.txt"),
            ("a/b:c?d", "a/b:c?d", "a b c d.txt"),
            ("../../etc/passwd", "../../etc/passwd", "etc passwd.txt"),
            ("  two   spaces\n\nand lines\t", "two spaces and lines", "two spaces and lines.txt"),
            ("", SpokenNoteItem.defaultTitle, "\(SpokenNoteItem.defaultTitle).txt"),
            ("   \n", SpokenNoteItem.defaultTitle, "\(SpokenNoteItem.defaultTitle).txt"),
            ("???", "???", "\(SpokenNoteItem.defaultTitle).txt"),
        ]
        for row in rows {
            let export = try SpokenNoteExport.prepareText(note: note, title: row.title, into: exports)
            XCTAssertEqual(export.text, "\(row.top)\n\nWords.", "title: \(row.title)")
            XCTAssertEqual(export.title, row.top, "title: \(row.title)")
            XCTAssertEqual(export.fileURL.lastPathComponent, row.file, "title: \(row.title)")
            XCTAssertEqual(export.fileURL.deletingLastPathComponent(), export.folderURL, "a title never leaves the export's folder")
            XCTAssertTrue(FileManager.default.fileExists(atPath: export.fileURL.path), "title: \(row.title)")
        }

        let export = try SpokenNoteExport.prepareText(note: note, title: long, into: exports)
        XCTAssertEqual(export.text, "\(long)\n\nWords.", "the text keeps the whole title")
        XCTAssertLessThanOrEqual(export.fileURL.deletingPathExtension().lastPathComponent.count, SpokenNoteExport.maxBaseNameCharacters)
    }

    func testTextOnlyLeavesTheNoteAloneAndDiscardRemovesOnlyItsOwnFolder() throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Keep me."], in: folder))
        let export = try SpokenNoteExport.prepareText(note: note, title: "T", into: exports)
        XCTAssertTrue(export.folderURL.lastPathComponent.hasPrefix(SpokenNoteExport.exportFolderPrefix), "the stale-folder sweep can find it")
        export.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.m4a").path))
    }

    func testEachShareDestinationGetsAFormItCanUse() {
        let rows: [(activity: String?, expected: SpokenNoteTextDelivery)] = [
            ("com.apple.UIKit.activity.CopyToPasteboard", .text),
            ("com.apple.UIKit.activity.Message", .text),
            ("com.apple.UIKit.activity.Mail", .text),
            ("com.apple.mobilenotes.SharingExtension", .text),
            ("com.apple.DocumentManagerUICore.SaveToFiles", .file),
            ("com.apple.UIKit.activity.AirDrop", .file),
            // Anything not on the lists must still get something it can use.
            ("com.example.some-third-party.share", .textAndFile),
            ("", .textAndFile),
            (nil, .textAndFile),
        ]
        for row in rows {
            XCTAssertEqual(SpokenNoteTextDelivery.forActivity(row.activity), row.expected, "activity: \(row.activity ?? "nil")")
        }
    }

    // MARK: file names, a table of neighbouring titles

    func testFileBaseNames() {
        let long = String(repeating: "word ", count: 60)
        let cases: [(String, String)] = [
            ("Trip ideas", "Trip ideas"),
            ("  Trip   ideas \n", "Trip ideas"),
            ("Ideas: 10/12 \"draft\"?", "Ideas 10 12 draft"),
            ("a/b\\c", "a b c"),
            ("../../etc/passwd", "etc passwd"),
            (".hidden", "hidden"),
            ("Café ☕️ 会議メモ", "Café ☕️ 会議メモ"),
            ("e\u{301}tude", "e\u{301}tude"),
            ("Family 👨\u{200D}👩\u{200D}👧 trip", "Family 👨\u{200D}👩\u{200D}👧 trip"),
            ("می\u{200C}خواهم", "می\u{200C}خواهم"),
            ("soft\u{00AD}hyphen word\u{2060}joiner", "soft\u{00AD}hyphen word\u{2060}joiner"),
            ("flag 🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}", "flag 🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"),
            ("gnp\u{202E}fdp.m4a", "gnp fdp.m4a"),
            ("iso\u{2066}late\u{2069}d", "iso late d"),
            ("", "Spoken note"),
            ("   ", "Spoken note"),
            ("???", "Spoken note"),
            ("...", "Spoken note"),
            ("tab\there\u{7}bell", "tab here bell"),
            (String(long.prefix(300)), String(long.prefix(SpokenNoteExport.maxBaseNameCharacters)).trimmingCharacters(in: .whitespaces)),
        ]
        for (title, expected) in cases {
            XCTAssertEqual(SpokenNoteExport.fileBaseName(forTitle: title), expected, "title: \(title.debugDescription)")
        }
        XCTAssertEqual(SpokenNoteExport.fileBaseName(forTitle: "", fallback: "???"), "Spoken note", "an unusable fallback still gives a name")
    }

    func testAFileNameStemFitsTheByteLimitWhateverTheCharacters() {
        for unit in ["é", "会", "😀", "👨‍👩‍👧‍👦", "e\u{301}\u{302}\u{303}\u{304}\u{305}\u{306}\u{307}\u{308}"] {
            let stem = SpokenNoteExport.fileBaseName(forTitle: String(repeating: unit, count: 500))
            XCTAssertLessThanOrEqual(stem.utf8.count, SpokenNoteExport.maxBaseNameBytes, "unit \(unit)")
            XCTAssertFalse(stem.isEmpty)
            XCTAssertNotNil(String(data: Data(stem.utf8), encoding: .utf8))
        }
    }

    func testAVeryLongTitleMakesAShortFileNameStem() {
        XCTAssertLessThanOrEqual(SpokenNoteExport.fileBaseName(forTitle: String(repeating: "é", count: 5000)).count, SpokenNoteExport.maxBaseNameCharacters)
    }

    // MARK: prepare

    func testOneTakeCopiesItsOwnFileAndWritesTheTranscript() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Hello there."], in: folder))
        let joiner = RecordingJoiner()
        let files = try await SpokenNoteExport.prepare(note: note, title: "Trip ideas", noteFolder: folder, into: exports, joiner: joiner)

        XCTAssertEqual(files.audioURL?.lastPathComponent, "Trip ideas.m4a")
        XCTAssertEqual(files.transcriptURL?.lastPathComponent, "Trip ideas.txt")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.audioURL)), Data("audio-a".utf8), "the take's bytes, not re-encoded")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.transcriptURL), encoding: .utf8), "Hello there.")
        XCTAssertEqual(files.shareURLs.map(\.lastPathComponent), ["Trip ideas.m4a", "Trip ideas.txt"])
        XCTAssertTrue(joiner.joined.sources.isEmpty, "a single take is never run through the joiner")
        XCTAssertEqual(files.missingAudioTakeCount, 0)
        XCTAssertTrue(files.folderURL.path.hasPrefix(exports.path))
    }

    func testSeveralTakesAreJoinedInOrderIntoOneFile() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        for id in ["a", "b", "c"] { note.appendTake(try take(id, sentences: ["Take \(id)."], in: folder)) }
        let joiner = RecordingJoiner()
        let files = try await SpokenNoteExport.prepare(note: note, title: "Long note", noteFolder: folder, into: exports, joiner: joiner)

        XCTAssertEqual(joiner.joined.sources.first?.map(\.lastPathComponent), ["a.m4a", "b.m4a", "c.m4a"])
        XCTAssertEqual(files.audioURL?.lastPathComponent, "Long note.m4a")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.transcriptURL), encoding: .utf8), "Take a.\n\nTake b.\n\nTake c.")
    }

    func testAMissingTakeIsLeftOutAndCounted() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", in: folder))
        note.appendTake(try take("gone", writeAudio: false, in: folder))
        note.appendTake(try take("c", in: folder))
        let joiner = RecordingJoiner()
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: joiner)
        XCTAssertEqual(joiner.joined.sources.first?.map(\.lastPathComponent), ["a.m4a", "c.m4a"])
        XCTAssertEqual(files.missingAudioTakeCount, 1)
        XCTAssertNil(files.transcriptURL, "no transcript yet means no text file")
    }

    func testATranscriptAloneIsExportedWhenTheAudioIsGone() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Only words."], writeAudio: false, in: folder))
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        XCTAssertNil(files.audioURL)
        XCTAssertEqual(files.shareURLs.map(\.lastPathComponent), ["N.txt"])
        XCTAssertEqual(files.missingAudioTakeCount, 1)
    }

    func testNothingToExportThrowsAndLeavesNoFolder() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", writeAudio: false, in: folder))
        do {
            _ = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
            XCTFail("expected nothingToExport")
        } catch {
            XCTAssertEqual(error as? SpokenNoteExportError, .nothingToExport)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path), "nothing is created for an empty note")
        do {
            _ = try await SpokenNoteExport.prepare(note: SpokenNote(id: "empty"), title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
            XCTFail("an empty note has nothing to export")
        } catch {
            XCTAssertEqual(error as? SpokenNoteExportError, .nothingToExport)
        }
    }

    func testAFailedJoinWithNoWordsLeavesNoHalfMadeFolder() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", in: folder))
        note.appendTake(try take("b", in: folder))
        do {
            _ = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: FailingJoiner())
            XCTFail("the join failed and there are no words to offer instead")
        } catch {}
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? [], [], "the folder made for this export is removed")
    }

    func testAFailedJoinStillOffersTheWordsAndSaysTheAudioIsMissing() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["One."], in: folder))
        note.appendTake(try take("b", sentences: ["Two."], in: folder))
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: FailingJoiner())
        XCTAssertNil(files.audioURL)
        XCTAssertEqual(files.shareURLs.map(\.lastPathComponent), ["N.txt"])
        XCTAssertEqual(files.missingAudioTakeCount, 2)
        XCTAssertTrue(files.isPartial)
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: files.folderURL.path)).sorted(), ["N.txt"], "no half-written audio is left")
    }

    func testTakesTheJoinerLeftOutAreCounted() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        for id in ["a", "b", "c"] { note.appendTake(try take(id, sentences: ["Take \(id)."], in: folder)) }
        var joiner = RecordingJoiner()
        joiner.skipping = 1
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: joiner)
        XCTAssertEqual(files.missingAudioTakeCount, 1)
        XCTAssertTrue(files.isPartial)
    }

    func testAWholeNoteIsNotPartialAndTakesWithoutWordsMakeItPartial() async throws {
        let folder = try noteFolder()
        var whole = SpokenNote(id: "n")
        whole.appendTake(try take("a", sentences: ["One."], in: folder))
        let files = try await SpokenNoteExport.prepare(note: whole, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        XCTAssertFalse(files.isPartial)
        var partial = whole
        partial.appendTake(try take("b", sentences: [], in: folder))
        let second = try await SpokenNoteExport.prepare(note: partial, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        XCTAssertEqual(second.takesWithoutTranscriptCount, 1)
        XCTAssertTrue(second.isPartial)
    }

    func testATakeNamingAFileOutsideTheNoteIsNeverRead() async throws {
        let folder = try noteFolder()
        try Data("secret".utf8).write(to: root.appendingPathComponent("outside.m4a"))
        var note = SpokenNote(id: "n")
        for name in ["../outside.m4a", "/etc/hosts", "a/../../outside.m4a", "note.json", ".."] {
            note.appendTake(SpokenNoteTake(id: name, audioFileName: name, durationMs: 1000, createdAt: Date(timeIntervalSince1970: 0),
                                           sentences: [SpokenNoteSentence(text: "Words.", startMs: 0, endMs: 500)]))
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent("note.json"))
        let joiner = RecordingJoiner()
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: joiner)
        XCTAssertNil(files.audioURL)
        XCTAssertTrue(joiner.joined.sources.isEmpty)
        XCTAssertEqual(files.missingAudioTakeCount, 5)
    }

    func testASymbolicLinkNamedLikeATakeIsNotAudio() async throws {
        let folder = try noteFolder()
        let target = root.appendingPathComponent("outside.m4a")
        try Data("secret".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("a.m4a"), withDestinationURL: target)
        var note = SpokenNote(id: "n")
        note.appendTake(SpokenNoteTake(id: "a", audioFileName: "a.m4a", durationMs: 1000, createdAt: Date(timeIntervalSince1970: 0),
                                       sentences: [SpokenNoteSentence(text: "Words.", startMs: 0, endMs: 500)]))
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        XCTAssertNil(files.audioURL, "a link to a file outside the note is never copied")
        XCTAssertEqual(files.missingAudioTakeCount, 1)
    }

    func testADirectoryNamedLikeATakeIsNotAudio() async throws {
        let folder = try noteFolder()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("a.m4a"), withIntermediateDirectories: true)
        var note = SpokenNote(id: "n")
        note.appendTake(SpokenNoteTake(id: "a", audioFileName: "a.m4a", durationMs: 1000, createdAt: Date(timeIntervalSince1970: 0),
                                       sentences: [SpokenNoteSentence(text: "Words.", startMs: 0, endMs: 500)]))
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        XCTAssertNil(files.audioURL)
        XCTAssertEqual(files.shareURLs.map(\.lastPathComponent), ["N.txt"])
    }

    // MARK: stale export folders

    func testSweepRemovesOnlyOldExportFolders() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: exports, withIntermediateDirectories: true)
        let old = exports.appendingPathComponent("SpokenNoteExport-old", isDirectory: true)
        let fresh = exports.appendingPathComponent("SpokenNoteExport-fresh", isDirectory: true)
        let other = exports.appendingPathComponent("SomeoneElses-old", isDirectory: true)
        for url in [old, fresh, other] { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
        let now = Date()
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: old.path)
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: other.path)
        XCTAssertEqual(SpokenNoteExport.sweepStaleExports(in: exports, olderThan: 3600, now: now), 1)
        XCTAssertFalse(fileManager.fileExists(atPath: old.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fresh.path), "an export that may still be in a share sheet stays")
        XCTAssertTrue(fileManager.fileExists(atPath: other.path), "only this feature's folders are touched")
        XCTAssertEqual(SpokenNoteExport.sweepStaleExports(in: root.appendingPathComponent("missing")), 0)
    }

    // MARK: reading a note without changing it

    func testPeekNeverMovesAnUnreadableNoteFile() throws {
        let folder = try noteFolder()
        let store = SpokenNoteStore(folderURL: folder, noteId: "n")
        XCTAssertNil(store.peek(), "no file")
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertNil(store.peek())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), Data("not json".utf8), "the damaged file is still where it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.setAsideURL.path))
        try Data(#"{"id":"n","schemaVersion":99,"takes":[]}"#.utf8).write(to: store.fileURL)
        XCTAssertNil(store.peek(), "a newer build's note is not read")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Hi."], in: folder))
        try store.save(note)
        XCTAssertEqual(store.peek(), note)
    }

    func testExportNeverTouchesTheNotesOwnFiles() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Hi."], in: folder))
        note.appendTake(try take("b", sentences: ["There."], in: folder))
        func snapshot() throws -> [String: Data] {
            Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(atPath: folder.path).map { ($0, try Data(contentsOf: folder.appendingPathComponent($0))) })
        }
        let before = try snapshot()
        let files = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        XCTAssertEqual(try snapshot(), before)
        files.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.folderURL.path), "discard removes the export folder")
        XCTAssertEqual(try snapshot(), before, "discarding the export leaves the note as it was")
    }

    func testTwoExportsOfTheSameNoteDoNotShareAFolder() async throws {
        let folder = try noteFolder()
        var note = SpokenNote(id: "n")
        note.appendTake(try take("a", sentences: ["Hi."], in: folder))
        let first = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        let second = try await SpokenNoteExport.prepare(note: note, title: "N", noteFolder: folder, into: exports, joiner: RecordingJoiner())
        XCTAssertNotEqual(first.folderURL, second.folderURL)
        first.discard()
        XCTAssertNotNil(second.audioURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
    }
}
