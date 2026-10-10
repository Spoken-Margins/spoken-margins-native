import Foundation
import SQLite3
import XCTest
@testable import SessionKit
import SessionKitPersistence

/// What the current build writes into the Library must stay readable by the last
/// shipped build (Build 29, tag `testflight/0.1-build-29`).
///
/// Build 29 decodes every row with synthesized `Codable`: a missing non-optional key
/// or an enum raw value it does not know makes the row undecodable, and the store then
/// moves the row to `quarantined_records` and deletes it from `records`. The owner's
/// Margin or episode silently disappears from Build 29. Nothing else in the Linux suite
/// compares what the current build writes with what Build 29 reads (the real Build 29
/// reader needs a Mac and only runs from a path-filtered workflow), so these tests
/// are that comparison for the parts that can be frozen here:
///
/// 1. every enum Build 29 persists has exactly the raw values Build 29 knew, unless the
///    addition is listed below with the reason Build 29 cannot meet it;
/// 2. the current code opens the real Build 29 fixture database without quarantining or
///    migrating anything Build 29 could not open again;
/// 3. a Build 29 row decoded and written back by the current code keeps every key,
///    JSON type and value Build 29 wrote.
final class Build29PersistedShapeTests: XCTestCase {
    // MARK: Frozen Build 29 facts

    /// Raw values of every enum reachable from a `Codable` type that `SQLiteSessionStore`
    /// saves, as declared at `testflight/0.1-build-29` (`fcc4974`). Generated from that
    /// tag's sources; do not edit an entry to make the test pass.
    private static let build29PersistedEnums: [String: [String]] = [
        "AnchorContextStatus": ["pending", "ready", "unavailable"],
        "AnchorResolutionEvidenceClass": ["exact_edition", "article_text_verified", "transcript_verified", "acoustic_verified", "fused", "map_interpolated", "timestamp_fallback", "recipient_confirmed", "ambiguous", "absent_from_recipient_edition", "unresolved"],
        "AnchorType": ["text", "transcript", "media", "turn"],
        "AudioAssetAvailability": ["local_phone", "local_watch", "remote", "browser_only", "missing"],
        "AudioSourceType": ["generated_tts_realtime", "generated_tts_prerendered", "native_media_file", "browser_owned_media", "remote_stream"],
        "CanonicalSourceFormat": ["plain_text", "markdown", "pdf", "epub", "article"],
        "EpisodeFingerprintProvenance": ["observed_decoded_playback", "source_window_reference", "downloaded_source_reference"],
        "EpisodeFingerprintTrigger": ["initial_playback", "periodic_playback", "pre_interjection", "post_interjection_resume", "stable_post_seek", "downloaded_preparation"],
        "EpisodeMapPreparationStage": ["verify_source", "generate_fingerprint_spine", "transcribe", "generate_phrase_sketch", "segment_scenes", "generate_summaries", "render_bridges", "commit", "completed"],
        "FeedEntryState": ["unseen", "seen", "dismissed", "imported"],
        "FeedRefreshStatus": ["idle", "refreshing", "not_modified", "succeeded", "failed"],
        "FeedSubscriptionState": ["active", "muted"],
        "ImportedCommentaryIntegrityStatus": ["integrity_checked_unsigned"],
        "ImportedCommentaryRevealMode": ["fresh", "companion", "guided"],
        "ImportedSourceResolutionStatus": ["pending", "resolved", "context_only", "ambiguous", "wrong_source", "unavailable"],
        "InterjectionCaptureKind": ["audio", "written"],
        "InterjectionCleanupDecisionKind": ["filler", "isolated_phrase", "long_pause", "manual_word"],
        "InterjectionShareRevisionStatus": ["draft", "sender_review_pending", "sender_approved"],
        "InterjectionTargetType": ["item", "summary_turn", "assistant_turn"],
        "OfflineAssetCategory": ["prepared_audio", "prepared_chunk", "podcast", "guided_tour", "audiobook", "interjection", "recording", "source_document", "fingerprint_map", "transient_episode_transcript", "resolved_listening_map_projection", "summary_bridge", "dormant_watch_package"],
        "OfflineAssetIntegrity": ["valid", "stale", "corrupt"],
        "OfflineProtectionReason": ["active_playback", "active_render", "active_commit", "active_episode_map_preparation", "active_summary_bridge", "recently_deleted", "imported_audiobook", "interjection", "recording", "dormant_watch_transfer"],
        "PDFDocumentAnalysisStatus": ["complete", "unavailable_on_os", "resource_constrained", "partial", "failed"],
        "PDFDocumentExtractionEngine": ["pdfkit", "apple_vision_document_recognition"],
        "PDFTableSpeechDisposition": ["announce_and_skip"],
        "PodcastAnchorEvidenceCaptureStatus": ["pending_post_resume_sample", "pending_exact_local_capture", "ready", "unavailable"],
        "PodcastAnchorEvidenceProvenance": ["decoded_playback_stream", "exact_local_playback_edition", "observed_decoded_playback", "source_window_reference", "downloaded_source_reference"],
        "PodcastAnchorEvidenceWindowRole": ["pre_interjection", "post_resume", "source_window_before", "source_window_after"],
        "PodcastDownloadState": ["waiting_for_wifi", "downloading", "available_offline", "streaming_only", "failed", "evicted"],
        "PortableSceneEligibility": ["eligible", "excluded", "unknown"],
        "PortableSummaryProvenance": ["publisher_supplied", "sender_authored", "deterministic", "model_generated"],
        "PreparationJobPolicy": ["explicit", "demand_window", "while_charging"],
        "PreparedAudioState": ["not_prepared", "preparing", "paused_for_thermal", "ready_offline", "needs_repreparation", "stopped", "failed"],
        "ResolvedListeningMapConfidence": ["exact_edition", "verified", "approximate", "unresolved"],
        "SessionPhase": ["idle", "item_playback", "recording_interjection", "interjection_summary", "summary_playback", "addendum_capture", "ai_response_playback", "conversation", "finished", "abandoned"],
        "SharedItemType": ["text", "podcast", "pdf", "epub", "other"],
        "SourceIdentityKind": ["podcast_feed", "article_feed", "website"],
        "SourceSuggestionDecisionKind": ["prompted", "accepted", "not_now", "never_suggest"],
        "SourceType": ["podcast_feed", "text_feed", "newsletter", "blog", "social_feed", "other"],
        "TargetType": ["item_text_tts", "transcript_backed_media", "assistant_turn_tts", "summary_turn_tts", "browser_owned_media"],
        "WatchPackageRequestType": ["prerender_requested", "watch_transfer_requested", "package_delete_requested"],
    ]

    /// A raw value added since Build 29 to a persisted enum. An entry needs the reason
    /// Build 29 can never read a row containing it, for example "only ever stored in a
    /// field that is not written until a flag the owner turns on". Empty means no case
    /// has been added since Build 29.
    private static let reviewedAdditions: [String: [String: String]] = [:]

    private static let build29SchemaVersion = 5

    // MARK: 1. Enum raw values

    func testEveryEnumBuild29PersistsStillHasExactlyTheRawValuesBuild29Knew() throws {
        let sources = try currentSessionKitSources()
        var problems: [String] = []
        for (name, frozen) in Self.build29PersistedEnums.sorted(by: { $0.key < $1.key }) {
            let declarations = try Self.declaredCases(ofEnum: name, in: sources)
            guard declarations.count == 1, let current = declarations.first else {
                problems.append("\(name): found \(declarations.count) declarations in SessionKit; Build 29 persists this enum, so renaming or splitting it needs this table updated on purpose")
                continue
            }
            let reviewed = Self.reviewedAdditions[name] ?? [:]
            let added = Set(current.rawValues).subtracting(frozen).subtracting(reviewed.keys)
            let removed = Set(frozen).subtracting(current.rawValues)
            let staleReviews = Set(reviewed.keys).subtracting(current.rawValues)
            if !added.isEmpty {
                problems.append("\(name) (\(current.file)): new raw value(s) \(added.sorted()). Build 29 throws on an unknown raw value, quarantines the row and deletes it from the Library. Don't persist the case, or list it in reviewedAdditions with the reason Build 29 never reads it")
            }
            if !removed.isEmpty {
                problems.append("\(name) (\(current.file)): raw value(s) \(removed.sorted()) were written by Build 29 and are gone, so the current build cannot read those rows")
            }
            if !staleReviews.isEmpty {
                problems.append("\(name): reviewedAdditions lists \(staleReviews.sorted()) but the enum no longer declares them")
            }
        }
        XCTAssertTrue(problems.isEmpty, "\n" + problems.joined(separator: "\n"))
    }

    func testTheEnumReaderUnderstandsExplicitRawValuesCommentsStringsAndSeveralCasesPerLine() throws {
        let source = """
        // enum Decoy: String { case wrong }
        public enum Sample: String, Codable, Sendable {
            /// case doc
            case plain
            case explicit = "wire_value" // case trailing
            case first, second = "two", third
            indirect case nested = "n"
            var label: String {
                switch self {
                case .plain: return "case { not a declaration }"
                default: return "}"
                }
            }
            /* case blockComment */
            case afterBlock
            enum Inner: String { case innerCase }
        }
        enum Other: String { case other }
        """
        let declarations = try Self.declaredCases(ofEnum: "Sample", in: ["Sample.swift": source])
        XCTAssertEqual(declarations.count, 1)
        XCTAssertEqual(declarations.first?.rawValues, ["plain", "wire_value", "first", "two", "third", "n", "afterBlock"])
        XCTAssertEqual(try Self.declaredCases(ofEnum: "Inner", in: ["Sample.swift": source]).first?.rawValues, ["innerCase"])
        XCTAssertEqual(try Self.declaredCases(ofEnum: "Decoy", in: ["Sample.swift": source]).count, 0)
        XCTAssertThrowsError(try Self.declaredCases(ofEnum: "Assoc", in: ["A.swift": "enum Assoc { case value(Int) }"]),
                             "An enum shape the reader cannot follow must fail loudly, not look like an empty enum")
    }

    // MARK: 2. The real Build 29 database

    func testTheBuild29FixtureOpensWithTheCurrentCodeAndStillOpensWithSchemaFive() throws {
        let (directory, database) = try copyOfBuild29Fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: database.path), Self.build29SchemaVersion)

        do {
            let store = try SQLiteSessionStore(path: database.path)
            try assertBuild29Library(store)
            // Write every record back the way the app does after a listener touches it.
            for item in try store.listItems() { try store.saveItem(item) }
            for session in try store.loadSessions() { try store.saveSession(session) }
            for session in try store.loadSessions() {
                for interjection in try store.loadInterjections(sessionId: session.id) { try store.saveInterjection(interjection) }
            }
            try assertBuild29Library(store)
        }

        XCTAssertEqual(SQLiteSessionStore.schemaVersion(atPath: database.path), Self.build29SchemaVersion,
                       "Build 29 refuses any other schema_version with unsupported_schema_version, so the current build must not bump it")
        let reopened = try SQLiteSessionStore(path: database.path)
        try assertBuild29Library(reopened)
    }

    // MARK: 3. What the current code writes back

    func testRewritingBuild29RecordsKeepsEveryKeyTypeAndValueBuild29Wrote() throws {
        let (directory, database) = try copyOfBuild29Fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try rawRecords(atPath: database.path)
        XCTAssertEqual(original.count, 15, "the fixture holds 4 items, 4 sessions and 7 Margins")

        let source = try SQLiteSessionStore(path: database.path)
        let rewritten = directory.appending(path: "rewritten.sqlite")
        let target = try SQLiteSessionStore(path: rewritten.path)
        for item in try source.listItems() { try target.saveItem(item) }
        for session in try source.loadSessions() {
            try target.saveSession(session)
            for interjection in try source.loadInterjections(sessionId: session.id) { try target.saveInterjection(interjection) }
        }
        let after = try rawRecords(atPath: rewritten.path)

        var problems: [String] = []
        for (key, build29Payload) in original.sorted(by: { $0.key < $1.key }) {
            guard let currentPayload = after[key] else {
                problems.append("\(key): the current build does not write this record back")
                continue
            }
            let expected = try JSONDecoder().decode(JSONShape.self, from: Data(build29Payload.utf8))
            let actual = try JSONDecoder().decode(JSONShape.self, from: Data(currentPayload.utf8))
            problems += expected.differences(from: actual, at: key)
        }
        XCTAssertTrue(problems.isEmpty, "Build 29 reads these keys as required; a rewrite by the current build lost or changed them:\n" + problems.joined(separator: "\n"))
    }

    func testTheJSONComparisonSeesAMissingKeyAChangedTypeAndAChangedValue() throws {
        func shape(_ json: String) throws -> JSONShape { try JSONDecoder().decode(JSONShape.self, from: Data(json.utf8)) }
        let build29 = try shape(#"{"a":1,"b":{"c":"x","d":[true,2]},"e":"2025-09-16T05:21:40Z"}"#)
        XCTAssertEqual(build29.differences(from: try shape(#"{"a":1,"b":{"c":"x","d":[true,2],"new":5},"e":"2025-09-16T05:21:40Z","extra":1}"#), at: "r"), [],
                       "keys added by the current build are fine")
        XCTAssertEqual(build29.differences(from: try shape(#"{"a":1,"b":{"d":[true,2]},"e":"2025-09-16T05:21:40Z"}"#), at: "r"), ["r.b.c: missing"])
        XCTAssertEqual(build29.differences(from: try shape(#"{"a":"1","b":{"c":"x","d":[true,2]},"e":"2025-09-16T05:21:40Z"}"#), at: "r"), ["r.a: was number, now string"])
        XCTAssertEqual(build29.differences(from: try shape(#"{"a":1,"b":{"c":"y","d":[true,2]},"e":"2025-09-16T05:21:40Z"}"#), at: "r"), ["r.b.c: was \"x\", now \"y\""])
        XCTAssertEqual(build29.differences(from: try shape(#"{"a":1,"b":{"c":"x","d":[true]},"e":"2025-09-16T05:21:40Z"}"#), at: "r"), ["r.b.d: had 2 elements, now 1"])
        XCTAssertEqual(build29.differences(from: try shape(#"{"a":1,"b":{"c":"x","d":[1,2]},"e":"2025-09-16T05:21:40Z"}"#), at: "r"), ["r.b.d[0]: was bool, now number"])
    }

    // MARK: Helpers

    private func assertBuild29Library(_ store: SQLiteSessionStore, file: StaticString = #filePath, line: UInt = #line) throws {
        let items = try store.listItems().sorted { $0.id < $1.id }
        XCTAssertEqual(items.map(\.id), ["b29-article", "b29-podcast-finished", "b29-podcast-known-length", "b29-podcast-no-length"], file: file, line: line)
        XCTAssertEqual(try store.loadItem(id: "b29-podcast-known-length").media?.durationMs, 3_600_000, file: file, line: line)
        XCTAssertEqual(try store.loadItem(id: "b29-podcast-known-length").title, "Episode with a known length", file: file, line: line)

        let sessions = try store.loadSessions().sorted { $0.id < $1.id }
        XCTAssertEqual(sessions.count, 4, file: file, line: line)
        let known = try XCTUnwrap(sessions.first { $0.id == "session-b29-podcast-known-length" }, file: file, line: line)
        XCTAssertEqual(known.position.mediaTimeMs, 1_080_000, file: file, line: line)
        XCTAssertEqual(known.completionPercent, 30, file: file, line: line)

        var margins: [Interjection] = []
        for session in sessions { margins += try store.loadInterjections(sessionId: session.id) }
        XCTAssertEqual(margins.count, 7, "Build 29 fixture holds seven Margins across four sessions", file: file, line: line)
        let finished = try XCTUnwrap(margins.first { $0.id == "b29-margin-finished" }, file: file, line: line)
        XCTAssertEqual(finished.anchor.anchorType, .media, file: file, line: line)
        XCTAssertEqual(finished.anchor.mediaTimeMs, 300_000, file: file, line: line)
        XCTAssertEqual(finished.transcript, "Margin on a finished episode", file: file, line: line)
        XCTAssertEqual(try store.quarantinedRecordCount(), 0, "nothing in the Build 29 library may be unreadable to the current build", file: file, line: line)
    }

    private func copyOfBuild29Fixture() throws -> (directory: URL, database: URL) {
        let fixture = try repositoryRoot().appending(path: "Contracts/fixtures/persistence/build29.sqlite")
        let directory = FileManager.default.temporaryDirectory.appending(path: "build29-shape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appending(path: "library.sqlite")
        try FileManager.default.copyItem(at: fixture, to: database)
        return (directory, database)
    }

    private func rawRecords(atPath path: String) throws -> [String: String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            throw NSError(domain: "Build29PersistedShape", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"])
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT kind, id, payload FROM records", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "Build29PersistedShape", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = String(cString: sqlite3_column_text(statement, 0))
            let id = String(cString: sqlite3_column_text(statement, 1))
            rows["\(kind)/\(id)"] = String(cString: sqlite3_column_text(statement, 2))
        }
        return rows
    }

    private func currentSessionKitSources() throws -> [String: String] {
        let directory = try repositoryRoot().appending(path: "Packages/SessionKit/Sources/SessionKit")
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "Build29PersistedShape", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot read \(directory.path)"])
        }
        var sources: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            sources[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertGreaterThan(sources.count, 20, "SessionKit sources not found")
        return sources
    }

    private func repositoryRoot() throws -> URL {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Contracts").path) {
            let parent = root.deletingLastPathComponent()
            guard parent != root else {
                throw NSError(domain: "Build29PersistedShape", code: 4, userInfo: [NSLocalizedDescriptionKey: "Repository root unavailable"])
            }
            root = parent
        }
        return root
    }
}

// MARK: - Reading enum declarations out of Swift source

private struct DeclaredEnum {
    var file: String
    var rawValues: [String]
}

private struct EnumReaderError: Error, CustomStringConvertible {
    var description: String
}

extension Build29PersistedShapeTests {
    /// Returns the raw values of every `enum <name>` in `sources`, in declaration order.
    /// Comments and string literals are masked before braces are matched so a `}` inside
    /// a string or a `case` inside a comment cannot move the enum body or add a case.
    fileprivate static func declaredCases(ofEnum name: String, in sources: [String: String]) throws -> [DeclaredEnum] {
        var found: [DeclaredEnum] = []
        let pattern = try NSRegularExpression(pattern: #"\benum\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\b[^{]*\{"#)
        for (file, text) in sources.sorted(by: { $0.key < $1.key }) {
            // Cheap pre-check so the 40-odd source files are only masked when they mention the enum.
            guard text.contains("enum \(name)") else { continue }
            let (code, masked) = Self.codeAndMask(text)
            let maskedString = String(decoding: masked, as: UTF8.self)
            let nsRange = NSRange(maskedString.startIndex..., in: maskedString)
            for match in pattern.matches(in: maskedString, range: nsRange) {
                var depth = 1
                var index = match.range.location + match.range.length
                let bodyStart = index
                while index < masked.count, depth > 0 {
                    if masked[index] == UInt8(ascii: "{") { depth += 1 } else if masked[index] == UInt8(ascii: "}") { depth -= 1 }
                    index += 1
                }
                guard depth == 0 else { throw EnumReaderError(description: "unbalanced braces in enum \(name) in \(file)") }
                found.append(DeclaredEnum(
                    file: file,
                    rawValues: try Self.caseRawValues(code: Array(code[bodyStart..<(index - 1)]), mask: Array(masked[bodyStart..<(index - 1)]), enumName: name)
                ))
            }
        }
        return found
    }

    /// Works on UTF-8 bytes. `code` keeps string literals but blanks comments; `mask` also blanks
    /// string contents and every non-ASCII byte, so offsets in both arrays line up one to one.
    private static func codeAndMask(_ text: String) -> (code: [UInt8], mask: [UInt8]) {
        let bytes = Array(text.utf8)
        var code = bytes
        var mask = bytes
        let space = UInt8(ascii: " "), newline = UInt8(ascii: "\n"), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        enum State { case normal, lineComment, blockComment(Int), string, multilineString }
        var state = State.normal
        func blank(_ k: Int, code blankCode: Bool) {
            guard bytes[k] != newline else { return }
            if blankCode { code[k] = space }
            mask[k] = space
        }
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            let next: UInt8? = i + 1 < bytes.count ? bytes[i + 1] : nil
            switch state {
            case .normal:
                if c == slash, next == slash { state = .lineComment; blank(i, code: true); blank(i + 1, code: true); i += 2 }
                else if c == slash, next == star { state = .blockComment(1); blank(i, code: true); blank(i + 1, code: true); i += 2 }
                else if c == quote, i + 2 < bytes.count, bytes[i + 1] == quote, bytes[i + 2] == quote {
                    state = .multilineString; blank(i + 1, code: false); blank(i + 2, code: false); i += 3
                } else if c == quote { state = .string; i += 1 }
                else { if c >= 0x80 { blank(i, code: false) }; i += 1 }
            case .lineComment:
                if c == newline { state = .normal } else { blank(i, code: true) }
                i += 1
            case .blockComment(let depth):
                if c == slash, next == star { state = .blockComment(depth + 1); blank(i, code: true); blank(i + 1, code: true); i += 2 }
                else if c == star, next == slash {
                    blank(i, code: true); blank(i + 1, code: true); i += 2
                    state = depth == 1 ? .normal : .blockComment(depth - 1)
                } else { blank(i, code: true); i += 1 }
            case .string:
                if c == backslash { blank(i, code: false); if i + 1 < bytes.count { blank(i + 1, code: false) }; i += 2 }
                else if c == quote { state = .normal; i += 1 }
                else { blank(i, code: false); i += 1 }
            case .multilineString:
                if c == quote, next == quote, i + 2 < bytes.count, bytes[i + 2] == quote { state = .normal; i += 3 }
                else { blank(i, code: false); i += 1 }
            }
        }
        return (code, mask)
    }

    /// Cases declared directly in the enum body (brace depth zero), not inside members or nested types.
    private static func caseRawValues(code: [UInt8], mask: [UInt8], enumName: String) throws -> [String] {
        var values: [String] = []
        func readLine(_ start: Int, _ end: Int) throws {
            var declaration = String(decoding: mask[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            var codeLine = String(decoding: code[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if declaration.hasPrefix("indirect ") {
                declaration.removeFirst("indirect ".count)
                codeLine.removeFirst("indirect ".count)
            }
            guard declaration.hasPrefix("case ") else { return }
            guard !declaration.contains("(") else {
                throw EnumReaderError(description: "enum \(enumName) has a case with associated values (\(codeLine)); the reader only follows raw-value enums")
            }
            for part in Self.splitTopLevel(String(codeLine.dropFirst(5))) {
                let pieces = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard let caseName = pieces.first, !caseName.isEmpty else { continue }
                if pieces.count == 2 {
                    guard pieces[1].hasPrefix("\""), pieces[1].hasSuffix("\""), pieces[1].count >= 2 else {
                        throw EnumReaderError(description: "enum \(enumName): case \(caseName) has a raw value that is not a string literal (\(pieces[1]))")
                    }
                    values.append(String(pieces[1].dropFirst().dropLast()))
                } else {
                    values.append(caseName)
                }
            }
        }
        var depth = 0
        var lineStart = 0
        var startDepth = 0
        for (index, byte) in mask.enumerated() {
            if index == lineStart { startDepth = depth }
            if byte == UInt8(ascii: "{") { depth += 1 } else if byte == UInt8(ascii: "}") { depth -= 1 }
            if byte == UInt8(ascii: "\n") {
                if startDepth == 0 { try readLine(lineStart, index) }
                lineStart = index + 1
            }
        }
        if lineStart < mask.count, startDepth == 0 { try readLine(lineStart, mask.count) }
        return values
    }

    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inString = false
        for character in text {
            if character == "\"" { inString.toggle() }
            if character == ",", !inString { parts.append(current); current = "" } else { current.append(character) }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - JSON shape comparison

/// A decoded JSON value that keeps number, bool and string apart (a date written as
/// `"2025-09-16T05:21:40Z"` turning into a number is a break for Build 29).
private indirect enum JSONShape: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONShape])
    case object([String: JSONShape])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONShape].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONShape].self)) }
    }

    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// What `self` (written by Build 29) had that `current` no longer has. Keys only `current` has are ignored.
    func differences(from current: JSONShape, at path: String) -> [String] {
        switch (self, current) {
        case (.object(let old), .object(let new)):
            return old.keys.sorted().flatMap { key -> [String] in
                guard let value = new[key] else { return ["\(path).\(key): missing"] }
                return old[key]!.differences(from: value, at: "\(path).\(key)")
            }
        case (.array(let old), .array(let new)):
            guard old.count == new.count else { return ["\(path): had \(old.count) elements, now \(new.count)"] }
            return zip(old, new).enumerated().flatMap { offset, pair in pair.0.differences(from: pair.1, at: "\(path)[\(offset)]") }
        case (.null, .null):
            return []
        default:
            guard typeName == current.typeName else { return ["\(path): was \(typeName), now \(current.typeName)"] }
            return self == current ? [] : ["\(path): was \(describe), now \(current.describe)"]
        }
    }

    private var describe: String {
        switch self {
        case .string(let value): return "\"\(value)\""
        case .number(let value): return "\(value)"
        case .bool(let value): return "\(value)"
        default: return typeName
        }
    }
}
