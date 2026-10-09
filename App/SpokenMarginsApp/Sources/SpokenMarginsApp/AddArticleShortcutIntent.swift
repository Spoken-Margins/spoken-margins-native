#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation
import SessionKit

enum AddArticleShortcutError: Error, Equatable, LocalizedError {
    case unsupportedURL
    case missingTitle
    case missingBody

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "Article URL must use HTTP or HTTPS."
        case .missingTitle:
            return "The article title is empty. In Shortcuts, pass the Name detail from the Article."
        case .missingBody:
            return "The article body is empty. In Shortcuts, use Get Article using Safari Reader, then pass its Body detail."
        }
    }
}

enum AddArticleShortcutImport {
    static func makeHandoff(
        articleURL: URL,
        title: String,
        body: String,
        author: String? = nil,
        publishedAt: Date? = nil,
        startListening: Bool = true
    ) throws -> BrowserTextHandoff {
        guard let scheme = articleURL.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw AddArticleShortcutError.unsupportedURL
        }

        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw AddArticleShortcutError.missingTitle
        }

        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw AddArticleShortcutError.missingBody
        }

        let author = author?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrowserTextHandoff(
            captureMode: .readablePage,
            source: BrowserTextSource(
                url: articleURL.absoluteString,
                title: title,
                author: author?.isEmpty == false ? author : nil,
                publishedAt: publishedAt.map { ISO8601DateFormatter().string(from: $0) }
            ),
            text: body,
            contentFormat: .plainText,
            requestedContinuation: BrowserTextContinuation(
                startSession: startListening,
                preferredPlaybackOwner: "app"
            )
        )
    }

    static func enqueue(
        _ handoff: BrowserTextHandoff,
        store: Gate5BrowserTextHandoffStore,
        payloadID: String = UUID().uuidString
    ) throws -> URL {
        try store.save(handoff, payloadID: payloadID)
        return Gate5BrowserTextHandoffURL.url(forPayloadID: payloadID)
    }
}

struct AddArticleToSpokenMarginsIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Article to Spoken Margins"
    static let description = IntentDescription(
        "Imports article text from a Shortcut and optionally starts a listening session."
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "Article URL",
        description: "The URL detail from the Article produced by Safari Reader."
    )
    var articleURL: URL

    @Parameter(
        title: "Title",
        description: "The Name detail from the Article produced by Safari Reader."
    )
    var articleTitle: String

    @Parameter(
        title: "Body",
        description: "The Body detail from the Article produced by Safari Reader."
    )
    var articleBody: AttributedString

    @Parameter(
        title: "Author",
        description: "The optional Author detail from the Article produced by Safari Reader."
    )
    var author: String?

    @Parameter(
        title: "Published Date",
        description: "The optional Published Date detail from the Article produced by Safari Reader."
    )
    var publishedAt: Date?

    @Parameter(
        title: "Start Listening",
        description: "Open Spoken Margins and begin a listening session after import.",
        default: true
    )
    var startListening: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$articleTitle) to Spoken Margins") {
            \.$articleURL
            \.$articleBody
            \.$author
            \.$publishedAt
            \.$startListening
        }
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        let handoff = try AddArticleShortcutImport.makeHandoff(
            articleURL: articleURL,
            title: articleTitle,
            body: String(articleBody.characters),
            author: author,
            publishedAt: publishedAt,
            startListening: startListening
        )
        let openURL = try AddArticleShortcutImport.enqueue(
            handoff,
            store: Gate5BrowserTextHandoffStore.appGroup()
        )
        return .result(opensIntent: OpenURLIntent(openURL))
    }
}
#endif

#if !SPOKEN_MARGINS_LEGACY
struct ListeningMapPromptIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Listening Map Prompt"
    static let description = IntentDescription("Numbers the original article blocks for your choice of model. Pass the result to a model action, then assemble a listening edition.")
    @Parameter(title: "Article Text") var text: String
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard !text.isEmpty, text.utf8.count <= 5_000_000 else { throw EditionError.invalid("Provide article text up to 5 MB.") }
        return .result(value: ListeningEdition.prompt(for: text))
    }
}

struct AssembleListeningEditionIntent: AppIntent {
    static let title: LocalizedStringResource = "Assemble Listening Edition"
    static let description = IntentDescription("Combines unchanged article text with your model's map response into a portable JSON file. No AI request is made by this action.")
    @Parameter(title: "Title") var title: String
    @Parameter(title: "Source URL") var sourceURL: URL?
    @Parameter(title: "Original Article Text") var text: String
    @Parameter(title: "Model or Author", default: "User-selected model") var generator: String
    @Parameter(title: "Map JSON") var mapJSON: String
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let edition = try ListeningEdition.assemble(title: title, sourceURL: sourceURL?.absoluteString, text: text, generator: generator, mapJSON: mapJSON)
        return .result(value: IntentFile(data: try edition.encoded(), filename: "Listening Edition.json", type: .json))
    }
}

struct ImportListeningEditionIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Listening Edition"
    static let description = IntentDescription("Opens Spoken Margins to import an item and its supplied map. Does not regenerate the map or start playback. Pass the Assemble Listening Edition result straight in, with no Save step, or give the edition's JSON as text. A saved file works too.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static var parameterSummary: some ParameterSummary {
        Summary("Import \(\.$file)") { \.$json }
    }
    // Both are optional so the action never stops at a "Choose" file picker when the other is supplied.
    @Parameter(title: "Listening Edition File") var file: IntentFile?
    @Parameter(title: "Listening Edition JSON Text") var json: String?
    @MainActor func perform() async throws -> some IntentResult {
        guard let model = ListeningEditionShortcutBridge.model else {
            throw EditionError.invalid("Spoken Margins could not open its Library. Try the import again.")
        }
        try model.importListeningEditionDataForShortcut(try ListeningEdition.shortcutInput(file: file?.data, text: json))
        return .result()
    }
}

@MainActor
enum ListeningEditionShortcutBridge {
    static weak var model: Gate1AppModel?
}
#endif
