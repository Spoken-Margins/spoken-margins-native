import Foundation
import XCTest
@testable import SessionKit

/// The payloads the Safari extension and Shortcuts leave for the app to import (moved from the app target, #318).
final class BrowserTextHandoffStoreTests: XCTestCase {
    private var directory: URL!
    private var store: Gate5BrowserTextHandoffStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-text-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = Gate5BrowserTextHandoffStore(baseDirectory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var pendingDirectory: URL { directory.appendingPathComponent("BrowserTextHandoffs", isDirectory: true) }
    private var failedDirectory: URL { directory.appendingPathComponent("FailedBrowserTextHandoffs", isDirectory: true) }

    private func handoff(title: String = "Page", text: String = "Body text.") -> BrowserTextHandoff {
        BrowserTextHandoff(
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/\(title)", title: title),
            text: text,
            requestedContinuation: BrowserTextContinuation(startSession: true, preferredPlaybackOwner: "app")
        )
    }

    /// Writes a payload file the way another process would, as JSON.
    private func writePayload(_ id: String, _ fields: [String: Any], in folder: URL? = nil) throws {
        let folder = folder ?? pendingDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        try data.write(to: folder.appendingPathComponent(id).appendingPathExtension("json"))
    }

    private func validFields(id: String? = nil) -> [String: Any] {
        var fields: [String: Any] = [
            "captureMode": "selected_text",
            "source": ["url": "https://example.com/a", "title": "A"],
            "text": "Some text.",
        ]
        if let id { fields["id"] = id }
        return fields
    }

    private func assertInvalid(_ id: String, _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try store.handoff(payloadID: id), file: file, line: line) { error in
            XCTAssertEqual(error as? Gate5BrowserTextHandoffStoreError, .invalidPayload(reason), file: file, line: line)
        }
    }

    func testASavedHandoffReadsBackWithItsContinuation() throws {
        let original = handoff(text: "  Body text.\n")

        try store.save(original, payloadID: "payload-1")

        var expected = original
        expected.text = "Body text."
        XCTAssertEqual(try store.handoff(payloadID: "payload-1"), expected, "the text is trimmed; everything else survives")
        XCTAssertEqual(try store.pendingPayloadIDs(), ["payload-1"])
    }

    func testAFullyPopulatedHandoffReadsBackWithEveryFieldTheStoreCarries() throws {
        let original = BrowserTextHandoff(
            itemId: "item-7",
            captureMode: .selectedText,
            source: BrowserTextSource(url: "https://example.com/full", title: "Full"),
            text: "Body text.",
            contentFormat: .markdown,
            selection: BrowserTextSelection(textStart: 4, textEnd: 9, prefix: "before ", suffix: " after"),
            requestedContinuation: BrowserTextContinuation(startSession: true, preferredPlaybackOwner: "watch")
        )

        try store.save(original, payloadID: "full")

        XCTAssertEqual(try store.handoff(payloadID: "full"), original)
        let read = try store.handoff(payloadID: "full")
        XCTAssertEqual(read.itemId, "item-7")
        XCTAssertEqual(read.contentFormat, .markdown)
        XCTAssertEqual(read.selection, BrowserTextSelection(textStart: 4, textEnd: 9, prefix: "before ", suffix: " after"))
        XCTAssertEqual(read.requestedContinuation, BrowserTextContinuation(startSession: true, preferredPlaybackOwner: "watch"))
    }

    func testTheStoreDropsTheDocumentStructureOnPurposeBecauseOnlyTheSafariAndShortcutsPayloadsUseIt() throws {
        // PDF structure travels with the in-process import (`importBrowserTextInBackground(_:structuredDocument:)`), never
        // through this store, whose writers are the Add Article shortcut and the Safari and share extensions' own JSON. If a writer
        // ever needs it here, `BrowserTextPayload` must carry it and this test changes with it.
        let structure = PDFDocumentStructure(
            extractionEngine: .pdfKit, analysisStatus: .complete, pageCount: 3, analyzedPageCount: 3
        )
        var original = handoff()
        original.documentStructure = structure

        try store.save(original, payloadID: "pdf")

        XCTAssertNil(try store.handoff(payloadID: "pdf").documentStructure)
    }

    func testAPayloadIDIsTrimmedWhereverItIsGiven() throws {
        try store.save(handoff(), payloadID: "  padded \n")

        XCTAssertEqual(try store.pendingPayloadIDs(), ["padded"])
        XCTAssertEqual(try store.handoff(payloadID: " padded ").source.title, "Page")
    }

    func testAnEmptyPayloadIDIsRefusedOnSaveAndRead() {
        XCTAssertThrowsError(try store.save(handoff(), payloadID: "   ")) {
            XCTAssertEqual($0 as? Gate5BrowserTextHandoffStoreError, .invalidPayload("payloadId is empty"))
        }
        assertInvalid("", "payloadId is empty")
        assertInvalid("  ", "payloadId is empty")
    }

    func testAMissingPayloadIsReportedByItsID() {
        XCTAssertThrowsError(try store.handoff(payloadID: "absent")) {
            XCTAssertEqual($0 as? Gate5BrowserTextHandoffStoreError, .missingPayload("absent"))
        }
    }

    func testAPayloadWithoutAContinuationAsksForNoSessionAndTheAppAsOwner() throws {
        try writePayload("bare", validFields())

        let read = try store.handoff(payloadID: "bare")

        XCTAssertEqual(read.requestedContinuation, BrowserTextContinuation(startSession: false, preferredPlaybackOwner: "app"))
        XCTAssertEqual(read.text, "Some text.")
    }

    func testEachMissingOrBlankRequiredFieldIsRefusedWithItsOwnReason() throws {
        var noMode = validFields(); noMode["captureMode"] = nil
        var blankURL = validFields(); blankURL["source"] = ["url": "  ", "title": "A"]
        var blankTitle = validFields(); blankTitle["source"] = ["url": "https://example.com/a", "title": "\n"]
        var blankText = validFields(); blankText["text"] = " \n "
        let wrongID = validFields(id: "someone-else")
        try writePayload("no-mode", noMode)
        try writePayload("blank-url", blankURL)
        try writePayload("blank-title", blankTitle)
        try writePayload("blank-text", blankText)
        try writePayload("wrong-id", wrongID)

        assertInvalid("no-mode", "captureMode is required")
        assertInvalid("blank-url", "source.url is required")
        assertInvalid("blank-title", "source.title is required")
        assertInvalid("blank-text", "text is required")
        assertInvalid("wrong-id", "payload id does not match payloadId")
    }

    func testAPayloadThatMatchesItsOwnIDReads() throws {
        try writePayload("same", validFields(id: "same"))

        XCTAssertEqual(try store.handoff(payloadID: "same").source.url, "https://example.com/a")
    }

    func testAFileThatIsNotJSONFailsToDecodeRatherThanBeingTreatedAsMissing() throws {
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: pendingDirectory.appendingPathComponent("junk.json"))

        XCTAssertThrowsError(try store.handoff(payloadID: "junk")) { error in
            XCTAssertNil(error as? Gate5BrowserTextHandoffStoreError)
        }
    }

    func testPendingPayloadsComeOldestFirstThenByNameAndIgnoreOtherFiles() throws {
        try writePayload("b-newer", validFields())
        try writePayload("a-older", validFields())
        try writePayload("c-same-time-as-a", validFields())
        try Data("x".utf8).write(to: pendingDirectory.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: pendingDirectory.appendingPathComponent(".hidden.json"))
        let base = Date(timeIntervalSince1970: 1_000_000)
        for (name, offset) in [("a-older", 0.0), ("c-same-time-as-a", 0.0), ("b-newer", 60.0)] {
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(offset)],
                ofItemAtPath: pendingDirectory.appendingPathComponent(name).appendingPathExtension("json").path)
        }

        XCTAssertEqual(try store.pendingPayloadIDs(), ["a-older", "c-same-time-as-a", "b-newer"])
    }

    func testNothingPendingBeforeAnythingWasSaved() throws {
        XCTAssertEqual(try store.pendingPayloadIDs(), [])
        XCTAssertEqual(try store.failedHandoffs(), [])
    }

    func testDeletingAPayloadRemovesItAndDeletingAMissingOneIsHarmless() throws {
        try store.save(handoff(), payloadID: "gone")

        try store.deletePayload(payloadID: "gone")
        try store.deletePayload(payloadID: "gone")

        XCTAssertEqual(try store.pendingPayloadIDs(), [])
    }

    func testAQuarantinedPayloadLeavesTheInboxAndKeepsItsReason() throws {
        try store.save(handoff(title: "Broken"), payloadID: "bad")

        try store.quarantine(payloadID: "bad", reason: "  import failed  ")

        XCTAssertEqual(try store.pendingPayloadIDs(), [])
        let failed = try store.failedHandoffs()
        XCTAssertEqual(failed.map(\.id), ["bad"])
        XCTAssertEqual(failed.first?.reason, "import failed")
        XCTAssertEqual(failed.first?.handoff.source.title, "Broken")
        XCTAssertLessThan(abs(try XCTUnwrap(failed.first).failedAt.timeIntervalSinceNow), 60)
    }

    func testQuarantiningAPayloadThatIsNotThereReportsItMissingAndCreatesNothing() throws {
        XCTAssertThrowsError(try store.quarantine(payloadID: "absent", reason: "x")) {
            XCTAssertEqual($0 as? Gate5BrowserTextHandoffStoreError, .missingPayload("absent"))
        }
        XCTAssertEqual(try store.failedHandoffs(), [])
    }

    func testFailedHandoffsComeOldestFailureFirstAndSkipUnreadableFiles() throws {
        func failed(_ id: String, at seconds: TimeInterval) -> FailedBrowserTextHandoff {
            FailedBrowserTextHandoff(id: id, handoff: handoff(title: id), reason: "r", failedAt: Date(timeIntervalSince1970: seconds))
        }
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        for item in [failed("late", at: 300), failed("early", at: 100), failed("middle", at: 200)] {
            try JSONEncoder().encode(item).write(to: failedDirectory.appendingPathComponent(item.id).appendingPathExtension("json"))
        }
        try Data("not json".utf8).write(to: failedDirectory.appendingPathComponent("corrupt.json"))
        try Data("{}".utf8).write(to: failedDirectory.appendingPathComponent("readme.txt"))

        XCTAssertEqual(try store.failedHandoffs().map(\.id), ["early", "middle", "late"])
    }

    func testRetryingAFailedPayloadPutsItBackInTheInbox() throws {
        try store.save(handoff(title: "Again"), payloadID: "retry-me")
        try store.quarantine(payloadID: "retry-me", reason: "network")

        try store.retryFailed(payloadID: "retry-me")

        XCTAssertEqual(try store.failedHandoffs(), [])
        XCTAssertEqual(try store.pendingPayloadIDs(), ["retry-me"])
        XCTAssertEqual(try store.handoff(payloadID: "retry-me").source.title, "Again")
    }

    func testRetryingAPayloadThatNeverFailedReportsItMissing() {
        XCTAssertThrowsError(try store.retryFailed(payloadID: "never")) {
            XCTAssertEqual($0 as? Gate5BrowserTextHandoffStoreError, .missingPayload("never"))
        }
    }

    func testDeletingAFailedPayloadRemovesItAndAMissingOneIsHarmless() throws {
        try store.save(handoff(), payloadID: "drop")
        try store.quarantine(payloadID: "drop", reason: "x")

        try store.deleteFailed(payloadID: "drop")
        try store.deleteFailed(payloadID: "drop")

        XCTAssertEqual(try store.failedHandoffs(), [])
    }

    /// The app drains the folder off the main thread (#2510), so the store is handed to a detached task: list, read,
    /// quarantine and delete all work there and leave the folder as the main-thread drain did.
    func testTheDrainSequenceRunsOffTheMainThread() async throws {
        try store.save(handoff(title: "kept"), payloadID: "kept")
        try store.save(handoff(title: "gone"), payloadID: "gone")
        let store = try XCTUnwrap(store)

        let ranOffMain = try await Task.detached { () throws -> Bool in
            let ids = try store.pendingPayloadIDs()
            let read = try store.handoff(payloadID: "gone")
            try store.deletePayload(payloadID: "gone")
            try store.quarantine(payloadID: "kept", reason: "could not import")
            return !Thread.isMainThread && ids.sorted() == ["gone", "kept"] && read.source.title == "gone"
        }.value

        XCTAssertTrue(ranOffMain)
        XCTAssertEqual(try store.pendingPayloadIDs(), [])
        XCTAssertEqual(try store.failedHandoffs().map(\.id), ["kept"])
    }

    func testTheErrorsReadAsSentencesForTheListener() {
        XCTAssertEqual(Gate5BrowserTextHandoffStoreError.appGroupUnavailable("group.x").errorDescription,
                       "Browser text App Group is unavailable: group.x")
        XCTAssertEqual(Gate5BrowserTextHandoffStoreError.missingPayload("p").errorDescription,
                       "Browser text payload was not found: p")
        XCTAssertEqual(Gate5BrowserTextHandoffStoreError.invalidPayload("why").errorDescription,
                       "Browser text payload is invalid: why")
    }
}
