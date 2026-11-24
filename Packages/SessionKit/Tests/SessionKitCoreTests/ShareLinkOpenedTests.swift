import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SessionKit
import SessionKitTestInputs

/// Opened marks on share links (#5275): the token, the sender's records and line, the friend's notice and signal,
/// and the switch that stops both.
final class ShareLinkOpenedTests: XCTestCase {
    private struct Vector: Decodable {
        let keyFragment: String
        let linkID: String
        let message: String
        let tokenHex: String
        let otherLinkID: String
        let otherTokenHex: String
    }

    private func vector() throws -> Vector {
        try JSONDecoder().decode(Vector.self, from: TestInputs.data(.research, "B4/contracts/fixtures/share-link-opened-token.json"))
    }

    private let id = "5e2d0c4b7a8f41e39c6b2d18f0a7e4c1"
    private let otherID = "0123456789abcdef0123456789abcdef"
    private let token = String(repeating: "ab", count: 32)
    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func freshDefaults() -> UserDefaults {
        let name = "ShareLinkOpenedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func scratchFile() -> SentShareLinkFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sent-links-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SentShareLinkFile(url: directory.appendingPathComponent("sent-share-links.json"))
    }

    private func record(_ id: String, item: String = "item", made: Date? = nil, opened: Bool = false, checked: Date? = nil) -> SentShareLink {
        let made = made ?? now
        return SentShareLink(id: id, token: token, itemID: item, createdAt: made, expiresAt: made.addingTimeInterval(30 * day), opened: opened, lastCheckedAt: checked)
    }

    // MARK: The token

    func testTheTokenMatchesTheSharedVector() throws {
        let v = try vector()
        let key = try XCTUnwrap(ShareLinkSealing.Key(fragment: v.keyFragment))
        XCTAssertEqual(ShareLinkOpenedToken.label + v.linkID, v.message)
        XCTAssertEqual(ShareLinkOpenedToken.make(key: key, id: v.linkID), v.tokenHex)
        XCTAssertEqual(ShareLinkOpenedToken.make(key: key, id: v.otherLinkID), v.otherTokenHex)
        let link = try XCTUnwrap(ShareLinkURL(url: URL(string: "https://spokenmargins.com/l/\(v.linkID)#\(v.keyFragment)")!))
        XCTAssertEqual(ShareLinkOpenedToken.make(for: link), v.tokenHex)
        XCTAssertTrue(ShareLinkOpenedToken.isValid(v.tokenHex))
    }

    /// Holding only `/l/<id>`, as a messenger's preview fetcher does, gives no token.
    func testALinkWithoutItsKeyHasNoToken() throws {
        let link = try XCTUnwrap(ShareLinkURL(url: URL(string: "https://spokenmargins.com/l/\(id)")!))
        XCTAssertNil(ShareLinkOpenedToken.make(for: link))
        XCTAssertNil(SentShareLink(link: URL(string: "https://spokenmargins.com/l/\(id)")!, serverExpiresAt: nil, itemID: "item", createdAt: now))
    }

    // MARK: The sender's records

    func testARecordKeepsTheIdAndTokenButNeverTheKey() throws {
        let v = try vector()
        let url = URL(string: "https://spokenmargins.com/l/\(v.linkID)#\(v.keyFragment)")!
        let record = try XCTUnwrap(SentShareLink(link: url, serverExpiresAt: "2026-12-24T09:00:00.123456789Z", itemID: "item-1", createdAt: now))
        XCTAssertEqual(record.id, v.linkID)
        XCTAssertEqual(record.token, v.tokenHex)
        XCTAssertEqual(record.expiresAt.timeIntervalSince1970, ISO8601DateFormatter().date(from: "2026-12-24T09:00:00Z")!.timeIntervalSince1970 + 0.123, accuracy: 0.001)
        let file = scratchFile()
        try file.save([record])
        let text = try String(contentsOf: file.url, encoding: .utf8)
        XCTAssertFalse(text.contains(v.keyFragment), "the file must never hold the key")
        XCTAssertFalse(text.contains("https://"), "the file must never hold the URL")
    }

    func testExpiryFallsBackToThirtyDays() {
        for value in [nil, "", "tomorrow", "2026-12-24"] as [String?] {
            XCTAssertEqual(SentShareLink.expiry(serverValue: value, createdAt: now), now.addingTimeInterval(30 * day), "\(String(describing: value))")
        }
        XCTAssertEqual(SentShareLink.expiry(serverValue: "2026-12-24T09:00:00Z", createdAt: now), ISO8601DateFormatter().date(from: "2026-12-24T09:00:00Z"))
    }

    func testTheFileSurvivesARelaunchAndPrunesExpiredRecords() throws {
        let file = scratchFile()
        XCTAssertEqual(file.load(now: now), [], "no file reads as empty")
        let live = record(id), old = record(otherID, made: now.addingTimeInterval(-31 * day))
        try file.save([live, old])
        XCTAssertEqual(SentShareLinkFile(url: file.url).load(now: now), [live])
        try Data("{not json".utf8).write(to: file.url)
        XCTAssertEqual(file.load(now: now), [], "a corrupt file reads as empty")
    }

    // MARK: The switch and the checks

    func testAnUnsetSwitchIsOnAndOffIsOff() {
        let defaults = freshDefaults()
        XCTAssertTrue(ShareLinkOpenedPolicy.isOn(defaults))
        defaults.set(false, forKey: ShareLinkOpenedPolicy.defaultsKey)
        XCTAssertFalse(ShareLinkOpenedPolicy.isOn(defaults))
        defaults.set(true, forKey: ShareLinkOpenedPolicy.defaultsKey)
        XCTAssertTrue(ShareLinkOpenedPolicy.isOn(defaults))
    }

    func testChecksSkipOpenedRecentAndExpiredRecordsAndStopAtTwenty() {
        let opened = record("a", opened: true)
        let recent = record("b", checked: now.addingTimeInterval(-5 * 60))
        let due = record("c", checked: now.addingTimeInterval(-11 * 60))
        let expired = record("d", made: now.addingTimeInterval(-30 * day))
        let never = record("e")
        let picked = ShareLinkOpenedPolicy.checksToRun([opened, recent, due, expired, never], receiptsOn: true, now: now).map(\.id)
        XCTAssertEqual(Set(picked), ["c", "e"])
        XCTAssertEqual(ShareLinkOpenedPolicy.checksToRun([due, never], receiptsOn: false, now: now), [], "switch off checks nothing")
        let fifty = (0..<50).map { record("r\($0)", made: now.addingTimeInterval(-Double($0) * 60)) }
        let first = ShareLinkOpenedPolicy.checksToRun(fifty, receiptsOn: true, now: now)
        XCTAssertEqual(first.count, 20)
        XCTAssertEqual(first.first?.id, "r0", "newest first")
    }

    // MARK: The client

    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        var reply: (Int, Data) = (204, Data())
        var fails = false
        func transport() -> ShareLinkOpenedClient.Transport {
            { request in
                try self.lock.withLock {
                    self.requests.append(request)
                    if self.fails { throw URLError(.notConnectedToInternet) }
                    return self.reply
                }
            }
        }
        var count: Int { lock.withLock { requests.count } }
    }

    func testTheClientPostsExactlyTheTokenAndAsksWithAHeader() async throws {
        let recorder = Recorder()
        let client = ShareLinkOpenedClient(host: "spokenmargins.proximitytoprogress.com", transport: recorder.transport())
        let sent = await client.markOpened(id: id, token: token)
        XCTAssertTrue(sent)
        let post = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.absoluteString, "https://spokenmargins.proximitytoprogress.com/l/\(id)/opened")
        XCTAssertEqual(post.httpBody, Data(token.utf8))
        XCTAssertNil(post.value(forHTTPHeaderField: "Cookie"))
        recorder.reply = (200, Data(#"{"opened":true}"#.utf8))
        let opened = await client.isOpened(id: id, token: token)
        XCTAssertEqual(opened, true)
        let get = recorder.requests[1]
        XCTAssertEqual(get.httpMethod, "GET")
        XCTAssertEqual(get.value(forHTTPHeaderField: ShareLinkOpenedClient.tokenHeader), token)
        XCTAssertNil(get.httpBody)
    }

    func testTheClientDefaultsToTheProductServerHost() {
        XCTAssertEqual(ShareLinkOpenedClient(transport: { _ in (204, Data()) }).url(id: id).host, ProductServer.host)
    }

    func testServerAnswersReadAsNotOpenedOrUnknown() async {
        let recorder = Recorder()
        let client = ShareLinkOpenedClient(host: "h.example", transport: recorder.transport())
        for (status, expected) in [(404, false), (405, false), (429, nil), (500, nil), (503, nil), (400, nil)] as [(Int, Bool?)] {
            recorder.reply = (status, Data())
            let answer = await client.isOpened(id: id, token: token)
            XCTAssertEqual(answer, expected, "\(status)")
        }
        recorder.reply = (200, Data("garbage".utf8))
        let garbage = await client.isOpened(id: id, token: token)
        XCTAssertNil(garbage)
        recorder.fails = true
        let offline = await client.isOpened(id: id, token: token)
        XCTAssertNil(offline)
        let sentOffline = await client.markOpened(id: id, token: token)
        XCTAssertFalse(sentOffline)
        let before = recorder.count
        let malformed = await client.markOpened(id: "nope", token: token)
        XCTAssertFalse(malformed)
        XCTAssertEqual(recorder.count, before, "a malformed id sends nothing")
    }

    // MARK: The friend's side

    @MainActor
    func testSwitchOffMeansNoSignalLeavesTheDevice() async {
        let defaults = freshDefaults()
        let signals = FriendLinkSignals(defaults: defaults)
        signals.recordArrival(id: id, token: token, offered: true, now: now)
        defaults.set(false, forKey: ShareLinkOpenedPolicy.defaultsKey)
        let recorder = Recorder()
        let signaller = FriendLinkSignaller(signals: signals, client: ShareLinkOpenedClient(host: "h.example", transport: recorder.transport()),
                                            defaults: defaults, ownLinkIDs: { [] }, now: { [now] in now })
        await signaller.signal(ids: [id])?.value
        XCTAssertEqual(recorder.count, 0)
        XCTAssertEqual(signals.signal(for: id, now: now)?.sent, false)
    }

    @MainActor
    func testADoubleTapSendsOnceAndAFailureIsRetried() async {
        let defaults = freshDefaults()
        let signals = FriendLinkSignals(defaults: defaults)
        signals.recordArrival(id: id, token: token, offered: true, now: now)
        let recorder = Recorder()
        recorder.fails = true
        let signaller = FriendLinkSignaller(signals: signals, client: ShareLinkOpenedClient(host: "h.example", transport: recorder.transport()),
                                            defaults: defaults, ownLinkIDs: { [] }, now: { [now] in now })
        let first = signaller.signal(ids: [id])
        XCTAssertNil(signaller.signal(ids: [id]), "a second tap while the first is in flight sends nothing")
        await first?.value
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(signals.signal(for: id, now: now)?.sent, false, "offline is not sent")
        recorder.fails = false
        await signaller.signal(ids: [id, id])?.value
        XCTAssertEqual(recorder.count, 2, "the next start control tries again, once")
        XCTAssertEqual(signals.signal(for: id, now: now)?.sent, true)
        XCTAssertNil(signaller.signal(ids: [id]), "a signalled link is not signalled again")
        // A relaunch reads the same store.
        signals.recordArrival(id: id, token: token, offered: true, now: now)
        XCTAssertEqual(FriendLinkSignals(defaults: defaults).signal(for: id, now: now)?.sent, true)
    }

    @MainActor
    func testNoHeaderOrYourOwnLinkSendsNothing() async {
        let defaults = freshDefaults()
        let signals = FriendLinkSignals(defaults: defaults)
        signals.recordArrival(id: id, token: token, offered: false, now: now)
        signals.recordArrival(id: otherID, token: token, offered: true, now: now)
        let recorder = Recorder()
        let signaller = FriendLinkSignaller(signals: signals, client: ShareLinkOpenedClient(host: "h.example", transport: recorder.transport()),
                                            defaults: defaults, ownLinkIDs: { [otherID = self.otherID] in [otherID] }, now: { [now] in now })
        await signaller.signal(ids: [id, otherID, "ffffffffffffffffffffffffffffffff"])?.value
        XCTAssertEqual(recorder.count, 0)
    }

    /// Before the listener's own sent links are read, nothing is sent: a cold launch from their own link can't signal it.
    @MainActor
    func testNothingIsSentBeforeYourOwnLinksAreKnown() async {
        let defaults = freshDefaults()
        let signals = FriendLinkSignals(defaults: defaults)
        signals.recordArrival(id: id, token: token, offered: true, now: now)
        let recorder = Recorder()
        let signaller = FriendLinkSignaller(signals: signals, client: ShareLinkOpenedClient(host: "h.example", transport: recorder.transport()),
                                            defaults: defaults, ownLinkIDs: { nil }, now: { [now] in now })
        XCTAssertNil(signaller.signal(ids: [id]))
        XCTAssertEqual(recorder.count, 0)
    }

    func testSignalsArePrunedAfterThirtyOneDays() {
        let defaults = freshDefaults()
        let signals = FriendLinkSignals(defaults: defaults)
        signals.recordArrival(id: id, token: token, offered: true, now: now.addingTimeInterval(-32 * day))
        signals.recordArrival(id: otherID, token: token, offered: true, now: now)
        XCTAssertEqual(Set(signals.all(now: now).keys), [otherID])
    }

    // MARK: The arrival notice

    private func entry(layer id: String, link: String?, name: String? = "Ana") -> SharedMarginReview.Entry {
        let layer = ImportedCommentaryLayer(
            id: id, itemId: "item", packageDigest: "d", packageId: "p",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "Episode", durationMs: 600_000),
            displayLabel: name, importedAt: now, sourceResolutionStatus: .resolved, isEnabled: true, isMuted: false,
            shareLinkId: link)
        let record = ImportedCommentaryInterjection(
            id: "m-\(id)", layerId: id, packageScopedId: "m-\(id)", createdAt: now,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media), approvedTranscript: "Words",
            audioPath: "ImportedCommentary/m.m4a", audioDurationMs: 4_000,
            resolution: ImportedAnchorResolution(evidenceClass: .acousticVerified, localMediaTimeMs: 1_000, confidence: 1))
        return SharedMarginReview.Entry(layer: layer, interjection: record, mediaTimeMs: 1_000, isApproximate: false)
    }

    func testTheNoticeShowsOnlyForAnOfferedUnsignalledLinkThatIsNotYours() {
        let offered = FriendLinkSignal(importedAt: now, offered: true, token: token, sent: false)
        let signals = [id: offered, otherID: offered]
        let fromFile = FriendLinkArrival.make(waiting: [entry(layer: "l1", link: nil)], signals: signals, receiptsOn: true, ownLinkIDs: [])
        XCTAssertFalse(fromFile.showsNotice, "a file from AirDrop has no link")

        let one = FriendLinkArrival.make(waiting: [entry(layer: "l1", link: id)], signals: signals, receiptsOn: true, ownLinkIDs: [])
        XCTAssertEqual(one.linkIDs, [id])
        XCTAssertEqual(one.noticeText, "When you open these Margins, Ana can see that you did.")
        XCTAssertEqual(one.dontTellTitle, "Don't tell Ana")

        let two = FriendLinkArrival.make(waiting: [entry(layer: "l1", link: id), entry(layer: "l2", link: otherID)], signals: signals, receiptsOn: true, ownLinkIDs: [])
        XCTAssertEqual(two.linkIDs, [otherID, id].sorted())

        let off = FriendLinkArrival.make(waiting: [entry(layer: "l1", link: id)], signals: signals, receiptsOn: false, ownLinkIDs: [])
        XCTAssertFalse(off.showsNotice)
        XCTAssertEqual(off.toldNotText, "Ana won't be told, and you won't see when your own links are opened. Change this in Settings.", "after Don't tell the name stays")
        XCTAssertFalse(FriendLinkArrival.make(waiting: [entry(layer: "l1", link: id)], signals: signals, receiptsOn: true, ownLinkIDs: [id]).showsNotice)
        XCTAssertFalse(FriendLinkArrival.make(waiting: [entry(layer: "l1", link: id)], signals: [id: FriendLinkSignal(importedAt: now, offered: false, token: token, sent: false)], receiptsOn: true, ownLinkIDs: []).showsNotice, "no header, no notice")
        XCTAssertFalse(FriendLinkArrival.make(waiting: [entry(layer: "l1", link: id)], signals: [id: FriendLinkSignal(importedAt: now, offered: true, token: token, sent: true)], receiptsOn: true, ownLinkIDs: []).showsNotice, "returning: already signalled")
        XCTAssertFalse(FriendLinkArrival.make(waiting: [entry(layer: "l1", link: id)], signals: [:], receiptsOn: true, ownLinkIDs: []).showsNotice)
    }

    func testTheNoticeWithNoNameSaysYourFriend() {
        let signals = [id: FriendLinkSignal(importedAt: now, offered: true, token: token, sent: false)]
        let arrival = FriendLinkArrival.make(waiting: [entry(layer: "l1", link: id, name: nil)], signals: signals, receiptsOn: true, ownLinkIDs: [])
        XCTAssertEqual(arrival.noticeText, "When you open these Margins, your friend can see that you did.")
        XCTAssertEqual(arrival.dontTellTitle, "Don't tell them")
        XCTAssertTrue(arrival.toldNotText.hasPrefix("Your friend won't be told"))
    }

    // MARK: The sender's line

    func testTheLineTable() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        let now = ISO8601DateFormatter().date(from: "2026-11-24T15:00:00Z")!
        func made(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        func line(_ records: [SentShareLink], on: Bool = true, at: Date? = nil) -> SentLinkLine? {
            SentLinkLine.make(records: records, receiptsOn: on, now: at ?? now, calendar: calendar, locale: locale)
        }
        func sent(_ id: String, _ date: String, opened: Bool = false) -> SentShareLink {
            let created = made(date)
            return SentShareLink(id: id, token: token, itemID: "item", createdAt: created, expiresAt: created.addingTimeInterval(30 * day), opened: opened)
        }
        XCTAssertNil(line([]))
        XCTAssertEqual(line([sent("a", "2026-11-24T09:00:00Z")])?.text, "Link sent today")
        XCTAssertEqual(line([sent("a", "2026-11-24T09:00:00Z")])?.accessibilityLabel, "Link sent today.")
        XCTAssertEqual(line([sent("a", "2026-11-23T09:00:00Z")])?.text, "Link sent yesterday")
        XCTAssertEqual(line([sent("a", "2026-11-10T09:00:00Z", opened: true)])?.text, "Link sent Nov 10 · Opened")
        XCTAssertEqual(line([sent("a", "2026-11-10T09:00:00Z", opened: true)])?.accessibilityLabel, "Link sent November 10. Opened.")
        XCTAssertEqual(line([sent("a", "2026-11-10T09:00:00Z", opened: true)])?.showsOpenedIcon, true)
        XCTAssertEqual(line([sent("a", "2025-12-30T09:00:00Z")], at: made("2026-01-10T12:00:00Z"))?.text, "Link sent Dec 30, 2025")
        XCTAssertEqual(line([sent("a", "2026-11-10T09:00:00Z", opened: true)], on: false)?.text, "Link sent Nov 10", "switch off never shows Opened")
        XCTAssertEqual(line([sent("a", "2026-11-10T09:00:00Z", opened: true)], on: false)?.showsOpenedIcon, false)
        let three = [sent("a", "2026-11-20T09:00:00Z"), sent("b", "2026-11-21T09:00:00Z", opened: true), sent("c", "2026-11-22T09:00:00Z")]
        XCTAssertEqual(line(three)?.text, "3 links sent · 1 opened")
        XCTAssertEqual(line(three)?.accessibilityLabel, "3 links sent, 1 opened.")
        XCTAssertEqual(line(three, on: false)?.text, "3 links sent")
        XCTAssertEqual(line(three.map { var r = $0; r.opened = true; return r })?.text, "3 links sent · all opened")
        XCTAssertEqual(line(three.map { var r = $0; r.opened = false; return r })?.text, "3 links sent")
        XCTAssertNil(line([sent("a", "2026-10-01T09:00:00Z", opened: true)]), "expired: no line")
        for records in [[sent("a", "2026-11-24T09:00:00Z")], three] {
            XCTAssertFalse(line(records)!.text.lowercased().contains("not opened"))
            XCTAssertFalse(line(records)!.text.lowercased().contains("unopened"))
        }
    }

    // MARK: The packet download

    func testTheDownloadSaysWhetherTheServerOffersMarks() async throws {
        let key = ShareLinkSealing.Key.random()
        let sealed = try ShareLinkSealing.seal(Data("PK packet".utf8), as: .packet, key: key)
        let link = try XCTUnwrap(ShareLinkURL(url: ShareLinkSealing.linkURL(base: URL(string: "https://spokenmargins.com/l/\(id)")!, key: key)!))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opened-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        for offers in [true, false] {
            let downloader = ShareLinkPacketDownloader.offering({ _, _ in (200, sealed, offers) })
            let result = try await downloader.downloadOffering(link, into: directory)
            XCTAssertEqual(result.offersOpened, offers)
        }
        let plain = ShareLinkPacketDownloader(fetch: { _, _ in (200, sealed) })
        let result = try await plain.downloadOffering(link, into: directory)
        XCTAssertFalse(result.offersOpened)
        XCTAssertTrue(ShareLinkPacketDownloader.offersOpened(["x-sm-link-opened": "1"]))
        XCTAssertTrue(ShareLinkPacketDownloader.offersOpened(["X-SM-Link-Opened": "1"]))
        XCTAssertFalse(ShareLinkPacketDownloader.offersOpened(["X-SM-Link-Opened": "0"]))
        XCTAssertFalse(ShareLinkPacketDownloader.offersOpened([:]))
    }

    // MARK: The sender's status

    #if canImport(Combine)
    @MainActor
    func testStatusShowsNoLineUntilReadThenOpenedAfterACheck() async throws {
        let file = scratchFile()
        try file.save([record(id)])
        let recorder = Recorder()
        recorder.reply = (200, Data(#"{"opened":true}"#.utf8))
        let status = SentLinkStatus(file: file, client: ShareLinkOpenedClient(host: "h.example", transport: recorder.transport()), now: { [now] in now })
        XCTAssertNil(status.line(forItem: "item", receiptsOn: true), "no line before the file is read")
        await status.load()
        XCTAssertEqual(status.line(forItem: "item", receiptsOn: true)?.text, "Link sent today")
        let defaults = freshDefaults()
        defaults.set(false, forKey: ShareLinkOpenedPolicy.defaultsKey)
        await status.runChecks(defaults: defaults)
        XCTAssertEqual(recorder.count, 0, "switch off checks nothing")
        defaults.removeObject(forKey: ShareLinkOpenedPolicy.defaultsKey)
        await status.runChecks(defaults: defaults)
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(status.line(forItem: "item", receiptsOn: true)?.text, "Link sent today · Opened")
        XCTAssertEqual(status.line(forItem: "item", receiptsOn: false)?.text, "Link sent today")
        await status.runChecks(defaults: defaults)
        XCTAssertEqual(recorder.count, 1, "an opened record is never checked again")
        await status.waitForSaves()
        XCTAssertEqual(file.load(now: now).first?.opened, true, "the answer survives a relaunch")
    }

    @MainActor
    func testStatusKeepsTheLastStateWhenTheServerFails() async throws {
        let file = scratchFile()
        let recorder = Recorder()
        recorder.fails = true
        let status = SentLinkStatus(file: file, client: ShareLinkOpenedClient(host: "h.example", transport: recorder.transport()), now: { [now] in now })
        XCTAssertNil(status.knownLinkIDs, "own links are unknown until the file is read")
        status.add(record(id))
        let defaults = freshDefaults()
        await status.runChecks(defaults: defaults)
        XCTAssertEqual(status.line(forItem: "item", receiptsOn: true)?.text, "Link sent today")
        XCTAssertEqual(status.knownLinkIDs, [id])
        await status.runChecks(defaults: defaults)
        XCTAssertEqual(recorder.count, 1, "the ten-minute rule holds after a failure")
    }
    #endif
}
