import UIKit
import UniformTypeIdentifiers

final class SourceLinkShareViewController: UIViewController, @unchecked Sendable {
    private struct ProviderCandidate: @unchecked Sendable {
        let provider: NSItemProvider
        let identifier: String
    }

    private struct BrowserTextSharePayload: Codable, Sendable {
        struct Source: Codable, Sendable {
            var url: String
            var title: String
            var author: String?
            var publishedAt: String?
        }

        struct Continuation: Codable, Sendable {
            var startSession = false
            var preferredPlaybackOwner = "app"
        }

        var id: String
        var schemaVersion = "browser-text-handoff.v1"
        var captureMode: String
        var contentFormat: String
        var source: Source
        var text: String
        var requestedContinuation = Continuation()
        var createdAt = ISO8601DateFormatter().string(from: Date())
    }

    private enum SharedImport: Sendable {
        case sourceLink(String)
        case browserText(BrowserTextSharePayload)
    }

    private var didProcess = false
    private typealias ExtractionCompletion = @Sendable (Result<SharedImport, Error>) -> Void
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureStatusUI()
        updateStatus("Preparing shared item...")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didProcess else { return }
        didProcess = true
        extractSharedImport { [weak self] result in
            DispatchQueue.main.async {
                self?.handle(result)
            }
        }
    }

    private func extractSharedImport(completion: @escaping ExtractionCompletion) {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
        guard !providers.isEmpty else {
            completion(.failure(SourceLinkShareError.noInput))
            return
        }
        // Safari's preprocessor and local files carry typed content. Prefer those
        // before the generic URL representation supplied by the same share.
        let preferredIdentifiers = [
            UTType.propertyList.identifier,
            UTType.fileURL.identifier,
            UTType.url.identifier,
            UTType.plainText.identifier,
            UTType.text.identifier
        ]
        let candidates = providers.flatMap { provider -> [ProviderCandidate] in
            let identifiers = preferredIdentifiers.filter(provider.hasItemConformingToTypeIdentifier)
                + provider.registeredTypeIdentifiers.filter { !preferredIdentifiers.contains($0) }
            return identifiers.map { ProviderCandidate(provider: provider, identifier: $0) }
        }
        loadFirstSharedImport(candidates, index: 0, completion: completion)
    }

    private func loadFirstSharedImport(
        _ candidates: [ProviderCandidate],
        index: Int,
        completion: @escaping ExtractionCompletion
    ) {
        guard index < candidates.count else {
            completion(.failure(SourceLinkShareError.unsupportedInput))
            return
        }
        let candidate = candidates[index]
        candidate.provider.loadItem(forTypeIdentifier: candidate.identifier, options: nil) { [weak self] item, _ in
            if let sharedImport = Self.sharedImport(from: item, identifier: candidate.identifier) {
                completion(.success(sharedImport))
            } else {
                DispatchQueue.main.async {
                    self?.loadFirstSharedImport(candidates, index: index + 1, completion: completion)
                }
            }
        }
    }

    private func handle(_ result: Result<SharedImport, Error>) {
        do {
            switch result {
            case .success(.sourceLink(let inputURL)):
                let handoff = SourceLinkHandoff(
                    id: "source-link-\(UUID().uuidString)",
                    inputURL: inputURL,
                    sourceSurface: "share_sheet",
                    startSession: false
                )
                _ = try SourceLinkHandoffStore.appGroup().save(handoff)
                showSaved("Saved podcast link to Spoken Margins. Open the app to finish importing it.")
            case .success(.browserText(let payload)):
                try saveBrowserText(payload)
                showSaved("Saved \(payload.source.title) to Spoken Margins. Open the app to finish importing it.")
            case .failure(let error):
                throw error
            }
        } catch {
            completeWithError(error)
        }
    }

    private func saveBrowserText(_ payload: BrowserTextSharePayload) throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SourceLinkHandoffStore.appGroupIdentifier
        ) else {
            throw SourceLinkHandoffStoreError.appGroupUnavailable(SourceLinkHandoffStore.appGroupIdentifier)
        }
        let directory = containerURL.appendingPathComponent("BrowserTextHandoffs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(payload.id).appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: url, options: [.atomic])
    }

    private func completeWithError(_ error: Error) {
        showError(error.localizedDescription)
    }

    private func configureStatusUI() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .label

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("Done", for: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.isHidden = true

        view.addSubview(statusLabel)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            closeButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            closeButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    private func updateStatus(_ text: String) {
        statusLabel.text = text
    }

    private func showError(_ message: String) {
        updateStatus(message)
        closeButton.isHidden = false
    }

    private func showSaved(_ message: String) {
        updateStatus(message)
        closeButton.isHidden = false
    }

    @objc private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    nonisolated private static func sharedImport(from item: Any?, identifier: String) -> SharedImport? {
        if identifier == UTType.propertyList.identifier,
           let payload = browserPayloadFromPropertyList(item) {
            return .browserText(payload)
        }
        if let url = item as? URL {
            if url.isFileURL {
                return browserPayloadFromFile(url).map(SharedImport.browserText)
            }
            return validatedWebURL(url).map { .sourceLink($0.absoluteString) }
        }
        if let data = item as? Data,
           let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return browserPayloadForPlainText(text, title: "Shared Text").map(SharedImport.browserText)
        }
        if let text = item as? String {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = firstURL(in: cleaned), cleaned == url.absoluteString || cleaned.count < url.absoluteString.count + 20 {
                return .sourceLink(url.absoluteString)
            }
            return browserPayloadForPlainText(cleaned, title: "Shared Text").map(SharedImport.browserText)
        }
        return nil
    }

    nonisolated private static func browserPayloadFromFile(_ url: URL) -> BrowserTextSharePayload? {
        let fileExtension = url.pathExtension.lowercased()
        guard ["md", "markdown", "txt"].contains(fileExtension) else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let isMarkdown = fileExtension == "md" || fileExtension == "markdown"
        return BrowserTextSharePayload(
            id: "browser-text-\(UUID().uuidString)",
            captureMode: isMarkdown ? "markdown_file" : "plain_text_file",
            contentFormat: isMarkdown ? "markdown" : "plain_text",
            source: .init(url: url.absoluteString, title: url.deletingPathExtension().lastPathComponent),
            text: text
        )
    }

    nonisolated private static func browserPayloadFromPropertyList(_ item: Any?) -> BrowserTextSharePayload? {
        guard let dictionary = item as? [String: Any] ?? item as? NSDictionary as? [String: Any] else { return nil }
        let rawResults = dictionary[NSExtensionJavaScriptPreprocessingResultsKey]
            ?? dictionary["NSExtensionJavaScriptPreprocessingResultsKey"]
            ?? dictionary
        guard let results = rawResults as? [String: Any] ?? rawResults as? NSDictionary as? [String: Any] else { return nil }
        let markdown = (results["markdown"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackText = (results["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let content = markdown.isEmpty ? fallbackText : markdown
        guard !content.isEmpty else { return nil }
        let contentFormat = markdown.isEmpty ? "plain_text" : "markdown"
        let sourceURL = ["canonicalURL", "url", "documentURL"]
            .compactMap { results[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "about:blank"
        let title = (results["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrowserTextSharePayload(
            id: "browser-text-\(UUID().uuidString)",
            captureMode: "readable_page",
            contentFormat: contentFormat,
            source: .init(
                url: sourceURL,
                title: title?.isEmpty == false ? title! : "Shared Web Page",
                author: results["author"] as? String,
                publishedAt: results["publishedAt"] as? String
            ),
            text: content
        )
    }

    nonisolated private static func browserPayloadForPlainText(_ text: String, title: String) -> BrowserTextSharePayload? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return BrowserTextSharePayload(
            id: "browser-text-\(UUID().uuidString)",
            captureMode: "plain_text_file",
            contentFormat: "plain_text",
            source: .init(url: "shared-text://share-sheet", title: title),
            text: cleaned
        )
    }

    nonisolated private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?.matches(in: text, options: [], range: range).compactMap(\.url).first.flatMap(validatedWebURL)
    }

    nonisolated private static func validatedWebURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return url
    }
}

private enum SourceLinkShareError: Error, LocalizedError {
    case noInput
    case unsupportedInput

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "No shared input was provided."
        case .unsupportedInput:
            return "Spoken Margins could not read this share. Share a web page, podcast link, Markdown file, or text file."
        }
    }
}
