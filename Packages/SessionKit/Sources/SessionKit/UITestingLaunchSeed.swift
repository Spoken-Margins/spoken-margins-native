import Foundation

/// What a UI-test launch puts in the Library before it loads.
///
/// Every case but `.none` needs the `--ui-testing` launch argument, so a normal
/// launch always gets `.none` and loads the listener's own Library untouched,
/// whatever the environment holds.
public enum UITestingLaunchSeed: Equatable, Sendable {
    /// A normal launch: load the Library as it is.
    case none
    /// A UI-test relaunch that keeps what the previous launch left, so a script
    /// can check what survives a force-quit (J2).
    case keepLibrary
    /// The bundled fixture article with its Listening Map.
    case fixture
    /// One article from `SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT`.
    case text(title: String, text: String, reference: String)
    /// One podcast episode that is already downloaded: a generated local audio
    /// file, so the script needs no network.
    case offlinePodcast(title: String, durationSeconds: Int)
    /// The fixture article plus a generated multi-page PDF, imported through the
    /// app's own Files import so PDF extraction and the reader run (J7).
    case importedPDF
    /// A fresh install (#2854): the Library is emptied and the app's defaults wiped, then nothing is seeded, so the
    /// first-run flow (Welcome sample, drawer, Terms, first Margin prompt) runs as a new listener meets it.
    case firstRun

    public static let textItemId = "item-ui-text-regression"
    public static let podcastItemId = "item-ui-podcast"
    public static let podcastFileName = "ui-test-episode.caf"
    public static let podcastRemoteURL = "https://cdn.example.invalid/ui-test-episode.caf"

    /// The friend's Margin that a co-op relaunch imports onto the seeded podcast (#474).
    public static let coopLayerId = "layer-ui-coop"
    public static let coopMarginId = "margin-ui-coop"
    public static let coopSenderLabel = "Sam"
    /// Five minutes in: well before the place the co-op journey pauses at, so it is a Margin the listener has skipped past.
    public static let coopMarginMediaTimeMs = 300_000
    public static let coopMarginDurationMs = 6_000

    /// The packet the screen tour's listener is taken to have sent (#3237): Sam's reply fixture,
    /// `App/TestFixtures/sharing-loop-sam-reply.spokenmargins`, answers the Margin `margin-ui-listener` in it. The
    /// listener's real export gets a digest of its own each run, so a checked-in reply can't name it; a reply relaunch
    /// records this identity on the listener's Margin instead, as `SpokenMarginsPackageExportRecord.recordExport` would.
    public static let listenerSharedIdentity = MarginPacketIdentity(
        packageDigest: "77840c24cc7d8c6854165504894b46cbc3222557310a4aaf7af2b16e9bd1f903",
        packageScopedId: "margin-ui-listener"
    )

    /// The listener's first Margin on the seeded podcast, marked as sent in `listenerSharedIdentity`, so Sam's reply
    /// finds it. Nil when the listener has no Margin there or it is already marked.
    public static func listenerMarginMarkedShared(_ margins: [Interjection]) -> Interjection? {
        guard let first = margins.filter({ $0.itemId == podcastItemId }).min(by: { $0.createdAt < $1.createdAt }),
              !(first.sharedAs ?? []).contains(listenerSharedIdentity) else { return nil }
        return first.recordingShare(as: listenerSharedIdentity)
    }

    // The parsing below names the launch argument and environment values. A Release build compiles
    // none of it (#517); the app reads them only through `UITestingHooks`, in Debug.
    #if DEBUG
    public init(arguments: [String], environment: [String: String]) {
        guard arguments.contains("--ui-testing") else {
            self = .none
            return
        }
        let title = environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TITLE"]
        if environment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] == "1" {
            self = .keepLibrary
        } else if let text = environment["SPOKEN_MARGINS_UI_TEST_SOURCE_TEXT"] {
            self = .text(
                title: title ?? "UI Test Text",
                text: text,
                reference: environment["SPOKEN_MARGINS_UI_TEST_SOURCE_URL"] ?? "ui-test"
            )
        } else if environment["SPOKEN_MARGINS_UI_TEST_PODCAST"] == "1" {
            let seconds = environment["SPOKEN_MARGINS_UI_TEST_PODCAST_SECONDS"].flatMap(Int.init) ?? 1_500
            self = .offlinePodcast(title: title ?? "UI Test Episode", durationSeconds: min(max(seconds, 10), 3_600))
        } else if environment["SPOKEN_MARGINS_UI_TEST_FIRST_RUN"] == "1" {
            self = .firstRun
        } else if environment["SPOKEN_MARGINS_UI_TEST_PDF"] == "1" {
            self = .importedPDF
        } else {
            self = .fixture
        }
    }
    #endif

    /// Whether a launch with this seed replaces the Library's contents. `.none` and
    /// `.keepLibrary` load the Library as it is.
    public var writesLibrary: Bool {
        switch self {
        case .none, .keepLibrary: return false
        case .fixture, .text, .offlinePodcast, .importedPDF, .firstRun: return true
        }
    }

    /// Whether a launch with this seed also starts with no Live sessions (#3967). Live sessions are files outside the
    /// store, so a Library reset leaves one that an earlier test started, at the top of every later test's Library.
    /// It follows `writesLibrary`: a seed that replaces the Library starts clean, and a kept Library keeps them.
    public var clearsLiveSessions: Bool { writesLibrary }

    /// Whether the Library bootstrap has work to do for this seed at launch: writing the Library, or adding the
    /// co-op relaunch's friend's layer to a kept one (#2918). The app used to keep only seeds that write, so a kept
    /// Library reached the bootstrap as `.none`, the friend's Margin never arrived, and J9's Continue had nothing
    /// to offer. The co-op import does nothing without its switch, and nothing on a second relaunch.
    public var runsAtLibraryBootstrap: Bool {
        writesLibrary || self == .keepLibrary
    }

    /// The single Item this seed adds, when it adds one of its own.
    public var item: Item? {
        switch self {
        case .none, .keepLibrary, .fixture, .importedPDF, .firstRun:
            return nil
        case let .text(title, text, reference):
            return Item(
                id: Self.textItemId,
                title: title,
                mediaType: "text",
                text: text,
                externalReference: reference,
                status: "needs_listening_map"
            )
        case let .offlinePodcast(title, durationSeconds):
            return Item(
                id: Self.podcastItemId,
                title: title,
                mediaType: TargetType.transcriptBackedMedia.rawValue,
                text: nil,
                externalReference: "https://example.invalid/ui-test/episode",
                status: "ready",
                externalReferenceType: "url",
                media: ItemMedia(
                    sourceType: .remoteStream,
                    url: Self.podcastRemoteURL,
                    durationMs: durationSeconds * 1_000
                ),
                sourceTitle: "UI Test Show"
            )
        }
    }

    /// The finished download for the podcast seed, pointing at `podcastFileName`
    /// inside the app's `PodcastAudio` folder.
    public func podcastDownload(bytesWritten: Int64) -> PodcastDownloadRecord? {
        guard case .offlinePodcast = self else { return nil }
        return PodcastDownloadRecord(
            id: "download-\(Self.podcastItemId)",
            itemId: Self.podcastItemId,
            remoteURL: Self.podcastRemoteURL,
            localRelativePath: Self.podcastFileName,
            state: .availableOffline,
            bytesWritten: bytesWritten,
            expectedBytes: bytesWritten
        )
    }

    /// The friend's collection that arrives with the co-op relaunch: enabled and placed on the seeded podcast, as an
    /// import of a packet for an episode the listener already has leaves it.
    public static func coopLayer(importedAt: Date) -> ImportedCommentaryLayer {
        ImportedCommentaryLayer(
            id: coopLayerId, itemId: podcastItemId,
            packageDigest: "ui-test-coop-digest", packageId: "ui-test-coop-package",
            itemIdentity: SharedItemIdentity(itemType: .podcast, title: "UI Test Episode", durationMs: 1_500_000),
            displayLabel: coopSenderLabel, importedAt: importedAt,
            sourceResolutionStatus: .resolved, isEnabled: true
        )
    }

    /// The friend's one new Margin: a voice, placed at `coopMarginMediaTimeMs`, not yet heard.
    public static func coopInterjection(audioPath: String, createdAt: Date) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: coopMarginId, layerId: coopLayerId, packageScopedId: coopMarginId, createdAt: createdAt,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: coopMarginMediaTimeMs),
            approvedTranscript: "A friend's UI test Margin.",
            audioPath: audioPath, audioDurationMs: coopMarginDurationMs,
            resolution: ImportedAnchorResolution(
                evidenceClass: .exactEdition, localMediaTimeMs: coopMarginMediaTimeMs, confidence: 1
            )
        )
    }

    /// A friend's written Margin that is never read aloud, at the same place as `coopInterjection`: no recording, and the
    /// sender asked that it not be read (#4934). It is not `SharedMarginAudio.canOffer`, so Skim and the Margins tab's Go-to
    /// are what take the listener to it.
    public static func coopSilentInterjection(createdAt: Date) -> ImportedCommentaryInterjection {
        ImportedCommentaryInterjection(
            id: coopMarginId, layerId: coopLayerId, packageScopedId: coopMarginId, createdAt: createdAt,
            anchorEvidence: PortableAnchorEvidence(anchorType: .media, mediaTimeMs: coopMarginMediaTimeMs),
            approvedTranscript: "A friend's UI test Margin.",
            audioPath: nil,
            resolution: ImportedAnchorResolution(
                evidenceClass: .exactEdition, localMediaTimeMs: coopMarginMediaTimeMs, confidence: 1
            ),
            senderReadAloud: false
        )
    }

    /// The listener's saved place on the seeded podcast, as the Session that Continue would resume (#4100): in progress
    /// at `placeSeconds`, or finished (100%, Continue then starts again from 0) when that is the end of the episode or
    /// past it. The place is clamped to the episode.
    public static func podcastSession(placeSeconds: Int, durationSeconds: Int, now: Date) -> Session {
        let durationMs = max(durationSeconds, 1) * 1_000
        let placeMs = min(max(placeSeconds, 0) * 1_000, durationMs)
        let finished = placeMs >= durationMs
        return Session(
            id: "session-\(podcastItemId)-ui-test-place",
            itemId: podcastItemId,
            createdAt: now,
            updatedAt: now,
            completedAt: finished ? now : nil,
            status: finished ? "finished" : "in_progress",
            phase: finished ? .finished : .itemPlayback,
            currentTargetType: .transcriptBackedMedia,
            currentTargetId: podcastRemoteURL,
            position: Position(charOffset: 0, mediaTimeMs: placeMs, chapterId: nil),
            completionPercent: finished ? 100 : min(99, placeMs * 100 / durationMs),
            playbackRate: 1
        )
    }

    /// Plain articles that make a fixture Library longer than the screen, so a script can scroll to its last row (#4314).
    /// Each is added an hour before the one above it, all before `fixtureAddedAt`, so Recently Added keeps the fixture
    /// article first and puts these below it.
    public static func libraryFillerItems(count: Int, fixtureAddedAt: Date) -> [Item] {
        (0..<max(count, 0)).map { index in
            Item(
                id: "item-ui-filler-\(index + 1)",
                title: "Filler article \(index + 1)",
                mediaType: "text",
                text: "A short article that only makes the Library long enough to scroll.",
                externalReference: "ui-test-filler-\(index + 1)",
                status: "ready",
                createdAt: fixtureAddedAt.addingTimeInterval(-3_600 * Double(index + 1))
            )
        }
    }

    public static let followedShowSubscriptionId = "ui-test-followed-show"
    public static let followedShowLibraryItemId = "ui-test-followed-show-heard"

    /// The followed show `seedsFollowedShow` stores, for the Up next card's captures: three entries, newest first.
    /// 1. A long title with a publisher description, unseen: the one the card features.
    /// 2. No description, unseen.
    /// 3. Already in the Library, as the item `libraryItem` (matched by its audio link).
    /// Its addresses use the reserved `.example` domain, so a refresh of the feed finds nothing and changes nothing.
    public static func followedShow(now: Date) -> (subscription: FeedSubscription, entries: [FeedEntry], libraryItem: Item) {
        let feed = "https://walking-podcast.example"
        let source = SourceIdentity(
            id: "ui-test-followed-source", kind: .podcastFeed, canonicalURL: "\(feed)/feed.xml",
            host: "walking-podcast.example", title: "The Walking Podcast")
        let subscription = FeedSubscription(
            id: followedShowSubscriptionId, source: source, lastRefreshAt: now, createdAt: now.addingTimeInterval(-14 * 86_400))
        func entry(_ id: String, title: String, summary: String?, days: Double, state: FeedEntryState, minutes: Int) -> FeedEntry {
            FeedEntry(
                id: "ui-test-followed-\(id)", subscriptionId: subscription.id, canonicalURL: "\(feed)/\(id)",
                audioURL: "\(feed)/\(id).mp3", title: title, summary: summary,
                publishedAt: now.addingTimeInterval(-days * 86_400), state: state,
                audioDurationMs: minutes * 60_000, episodeGUID: "guid-\(id)", firstSeenAt: now.addingTimeInterval(-days * 86_400))
        }
        let entries = [
            entry("ep3", title: "Why the river path bends, what the hedgerow birds are saying, and a long walk home along the railway cutting with a bell somewhere marking the hour",
                  summary: "<p>This week we follow the old river path from the willows to the hill, and ask why walkers &amp; birds keep to the same bends.</p><p>Plus: the allotments, the burning leaves, and what the town looks like from the top of the hill at dusk.</p>",
                  days: 1, state: .unseen, minutes: 42),
            entry("ep2", title: "A short walk in the rain", summary: nil, days: 3, state: .unseen, minutes: 18),
            entry("ep1", title: "The first walk", summary: "The first walk, at the river.", days: 9, state: .imported, minutes: 25),
        ]
        let heard = entries[2]
        let libraryItem = Item(
            id: followedShowLibraryItemId, title: heard.title, mediaType: "transcript_backed_media", text: nil,
            externalReference: heard.audioURL, status: "ready", externalReferenceType: "url",
            media: ItemMedia(sourceType: .remoteStream, url: heard.audioURL, durationMs: heard.audioDurationMs))
        return (subscription, entries, libraryItem)
    }

    #if DEBUG
    /// How many filler articles a fixture launch adds below the fixture article: `SPOKEN_MARGINS_UI_TEST_LIBRARY_FILLER`
    /// (#4314), at most 40. Zero for any other seed, and for anything but a whole number above 0.
    public static func libraryFillerCount(arguments: [String], environment: [String: String]) -> Int {
        guard UITestingLaunchSeed(arguments: arguments, environment: environment) == .fixture,
              let count = environment["SPOKEN_MARGINS_UI_TEST_LIBRARY_FILLER"].flatMap(Int.init), count > 0 else { return 0 }
        return min(count, 40)
    }

    /// Where a fresh podcast launch starts the listener, in seconds: `SPOKEN_MARGINS_UI_TEST_PODCAST_PLACE` (J14, #4100).
    /// Only the launch that seeds the podcast sets it, so a kept-Library relaunch never moves a place the script reached.
    /// Nil for anything but a whole number of seconds above 0, which is "not started".
    public static func podcastPlaceSeconds(arguments: [String], environment: [String: String]) -> Int? {
        guard case .offlinePodcast = UITestingLaunchSeed(arguments: arguments, environment: environment),
              let seconds = environment["SPOKEN_MARGINS_UI_TEST_PODCAST_PLACE"].flatMap(Int.init), seconds > 0 else { return nil }
        return seconds
    }

    /// Whether a fresh podcast launch starts with the episode marked complete by hand:
    /// `SPOKEN_MARGINS_UI_TEST_PODCAST_COMPLETED=1` (J14, #4100). It changes nothing else about the item, as
    /// `ManualItemCompletion.markComplete` does.
    public static func podcastStartsCompleted(arguments: [String], environment: [String: String]) -> Bool {
        guard case .offlinePodcast = UITestingLaunchSeed(arguments: arguments, environment: environment) else { return false }
        return environment["SPOKEN_MARGINS_UI_TEST_PODCAST_COMPLETED"] == "1"
    }

    /// Whether a keep-library UI-test relaunch also imports one friend's Margin onto the seeded podcast, the way a
    /// co-op packet would: `SPOKEN_MARGINS_UI_TEST_COOP=1` (J5-style co-op journey, #474). It adds to the kept
    /// Library and never changes which seed runs.
    public static func importsCoopLayer(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--ui-testing")
            && environment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] == "1"
            && environment["SPOKEN_MARGINS_UI_TEST_COOP"] == "1"
    }

    /// Whether the friend's Margin a co-op relaunch imports is the written one that is never read aloud
    /// (`coopSilentInterjection`, #4934): `SPOKEN_MARGINS_UI_TEST_COOP_SILENT=1` beside the co-op switches. It changes the
    /// Margin's kind, never whether one is imported, so alone it does nothing.
    public static func importsSilentCoopMargin(arguments: [String], environment: [String: String]) -> Bool {
        importsCoopLayer(arguments: arguments, environment: environment)
            && environment["SPOKEN_MARGINS_UI_TEST_COOP_SILENT"] == "1"
    }

    /// Whether a launch also follows one show for the Following tab and its show screen (#3863):
    /// `SPOKEN_MARGINS_UI_TEST_FOLLOWED_SHOW=1`. It adds to the Library the launch seeds (the `text` and podcast seeds,
    /// and a kept Library) and changes nothing else. The fixture seed does not carry it.
    public static func seedsFollowedShow(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--ui-testing") && environment["SPOKEN_MARGINS_UI_TEST_FOLLOWED_SHOW"] == "1"
    }

    /// Whether a keep-library UI-test relaunch marks the listener's Margin as sent in `listenerSharedIdentity`:
    /// `SPOKEN_MARGINS_UI_TEST_LISTENER_SHARED=1` (the screen tour's replies, #3237).
    public static func marksListenerMarginShared(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--ui-testing")
            && environment["SPOKEN_MARGINS_UI_TEST_KEEP_LIBRARY"] == "1"
            && environment["SPOKEN_MARGINS_UI_TEST_LISTENER_SHARED"] == "1"
    }

    /// Whether a UI-test launch swaps the microphone and speech recognition for
    /// stand-ins that need no permission prompt: `SPOKEN_MARGINS_UI_TEST_RECORDING=1`,
    /// or the podcast seed, whose Margins would otherwise ask to transcribe.
    public static func usesStandInAudioServices(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--ui-testing")
            && (environment["SPOKEN_MARGINS_UI_TEST_RECORDING"] == "1" || environment["SPOKEN_MARGINS_UI_TEST_PODCAST"] == "1")
    }

    /// Whether a UI-test launch may fetch the guided tour from the product server at startup:
    /// `SPOKEN_MARGINS_UI_TEST_GUIDED_TOUR_FETCH=1`, set by a script that covers the tour (J10 does, against an
    /// unreachable host). Every other UI-test launch skips the fetch, so the answer can't add a `guided-onboarding`
    /// row to a Library the script has seeded (#4071, as #2772 did for unit tests). A launch that isn't a UI test
    /// always fetches.
    public static func fetchesGuidedTour(arguments: [String], environment: [String: String]) -> Bool {
        !arguments.contains("--ui-testing") || environment["SPOKEN_MARGINS_UI_TEST_GUIDED_TOUR_FETCH"] == "1"
    }
    #endif

    /// Whether the start of a session should add the generated timeline turns
    /// that older fixture-article UI tests expect.
    public var seedsGeneratedTimeline: Bool { self == .fixture }
}
