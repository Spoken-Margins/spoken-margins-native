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

    public static let textItemId = "item-ui-text-regression"
    public static let podcastItemId = "item-ui-podcast"
    public static let podcastFileName = "ui-test-episode.caf"
    public static let podcastRemoteURL = "https://cdn.example.invalid/ui-test-episode.caf"

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
        } else {
            self = .fixture
        }
    }

    /// The single Item this seed adds, when it adds one of its own.
    public var item: Item? {
        switch self {
        case .none, .keepLibrary, .fixture:
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

    /// Whether a UI-test launch swaps the microphone and speech recognition for
    /// stand-ins that need no permission prompt: `SPOKEN_MARGINS_UI_TEST_RECORDING=1`,
    /// or the podcast seed, whose Margins would otherwise ask to transcribe.
    public static func usesStandInAudioServices(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--ui-testing")
            && (environment["SPOKEN_MARGINS_UI_TEST_RECORDING"] == "1" || environment["SPOKEN_MARGINS_UI_TEST_PODCAST"] == "1")
    }

    /// Whether the start of a session should add the generated timeline turns
    /// that older fixture-article UI tests expect.
    public var seedsGeneratedTimeline: Bool { self == .fixture }
}
