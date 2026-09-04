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
        case remotePDF(String)
        case localPDF(String)
        case browserText(BrowserTextSharePayload)
        case spokenMarginsPackage
    }

    private var didProcess = false
    private var didCompleteRequest = false
    private typealias ExtractionCompletion = @Sendable (Result<SharedImport, Error>) -> Void
    private let cardView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 320, height: 148)
        configureStatusUI()
        updateStatus("Adding to your library…")
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
        // Rank the representations per content type so the extension does the
        // least expensive reliable handoff for each source.
        let candidates = providers.flatMap { provider -> [ProviderCandidate] in
            let presentsPDF = provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            // Safari's PDF viewer can vend both a remote URL and a PDF file.
            // Hand the URL to the main app first so a large document is not
            // parsed inside the memory-constrained share extension. Ordinary
            // webpages still prefer the readable-page property list.
            let preferredIdentifiers = presentsPDF
                ? [
                    SpokenMarginsPackageHandoffStore.uniformTypeIdentifier,
                    UTType.url.identifier,
                    UTType.pdf.identifier,
                    UTType.fileURL.identifier,
                    UTType.propertyList.identifier
                ]
                : [
                    SpokenMarginsPackageHandoffStore.uniformTypeIdentifier,
                    UTType.propertyList.identifier,
                    UTType.fileURL.identifier,
                    UTType.url.identifier
                ]
            let identifiers = preferredIdentifiers.filter(provider.hasItemConformingToTypeIdentifier)
                + provider.registeredTypeIdentifiers.filter {
                    !preferredIdentifiers.contains($0)
                        && Self.acceptsRegisteredIdentifier($0, suggestedName: provider.suggestedName)
                }
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
            let identifiers = Array(Set(candidates.map(\.identifier))).sorted().joined(separator: ", ")
            completion(.failure(SourceLinkShareError.unsupportedInput(identifiers)))
            return
        }
        let candidate = candidates[index]
        let candidateType = UTType(candidate.identifier)
        if Self.isSpokenMarginsPackage(candidate) {
            candidate.provider.loadFileRepresentation(forTypeIdentifier: candidate.identifier) { url, error in
                guard let url else {
                    completion(.failure(error ?? SourceLinkShareError.unsupportedInput()))
                    return
                }
                do {
                    _ = try SpokenMarginsPackageHandoffStore.appGroup().savePackage(
                        from: url,
                        suggestedFilename: candidate.provider.suggestedName
                    )
                    completion(.success(.spokenMarginsPackage))
                } catch {
                    completion(.failure(error))
                }
            }
            return
        }
        if candidateType?.conforms(to: .pdf) == true {
            candidate.provider.loadFileRepresentation(forTypeIdentifier: candidate.identifier) { [weak self] url, _ in
                if let url, let sharedImport = Self.persistedPDFImport(
                    from: url,
                    suggestedName: candidate.provider.suggestedName
                ) {
                    completion(.success(sharedImport))
                } else {
                    DispatchQueue.main.async {
                        self?.loadCandidateItem(candidate, candidates: candidates, index: index, completion: completion)
                    }
                }
            }
            return
        }
        if candidateType?.conforms(to: .text) == true {
            candidate.provider.loadFileRepresentation(forTypeIdentifier: candidate.identifier) { [weak self] url, _ in
                if let url,
                   let payload = Self.browserPayloadFromFile(
                       url,
                       identifier: candidate.identifier,
                       suggestedName: candidate.provider.suggestedName
                   ) {
                    completion(.success(.browserText(payload)))
                } else {
                    DispatchQueue.main.async {
                        self?.loadCandidateItem(candidate, candidates: candidates, index: index, completion: completion)
                    }
                }
            }
            return
        }
        loadCandidateItem(candidate, candidates: candidates, index: index, completion: completion)
    }

    private func loadCandidateItem(
        _ candidate: ProviderCandidate,
        candidates: [ProviderCandidate],
        index: Int,
        completion: @escaping ExtractionCompletion
    ) {
        candidate.provider.loadItem(forTypeIdentifier: candidate.identifier, options: nil) { [weak self] item, _ in
            let presentsPDF = candidate.provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            if let sharedImport = Self.sharedImport(
                from: item,
                identifier: candidate.identifier,
                presentsPDF: presentsPDF,
                suggestedName: candidate.provider.suggestedName
            ) {
                completion(.success(sharedImport))
            } else if presentsPDF {
                candidate.provider.loadDataRepresentation(forTypeIdentifier: candidate.identifier) { data, _ in
                    if let data,
                       let sharedImport = Self.persistedPDFImport(
                           from: data,
                           suggestedName: candidate.provider.suggestedName
                       ) {
                        completion(.success(sharedImport))
                    } else {
                        DispatchQueue.main.async {
                            self?.loadFirstSharedImport(candidates, index: index + 1, completion: completion)
                        }
                    }
                }
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
                showSaved("Sent link to Spoken Margins.")
            case .success(.remotePDF(let inputURL)):
                let handoff = SourceLinkHandoff(
                    id: "source-link-\(UUID().uuidString)",
                    inputURL: inputURL,
                    sourceSurface: "share_sheet_pdf",
                    startSession: false
                )
                _ = try SourceLinkHandoffStore.appGroup().save(handoff)
                showSaved("Sent PDF to Spoken Margins.")
            case .success(.localPDF(let inputURL)):
                let handoff = SourceLinkHandoff(
                    id: "source-link-\(UUID().uuidString)",
                    inputURL: inputURL,
                    sourceSurface: "share_sheet_pdf_file",
                    startSession: false
                )
                _ = try SourceLinkHandoffStore.appGroup().save(handoff)
                showSaved("Sent PDF to Spoken Margins.")
            case .success(.browserText(let payload)):
                try saveBrowserText(payload)
                showSaved("Sent \(payload.source.title) to Spoken Margins.")
            case .success(.spokenMarginsPackage):
                showSaved("Sent shared session to Spoken Margins. Open Spoken Margins to import it.")
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
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemBackground
        cardView.layer.cornerRadius = 18
        cardView.layer.cornerCurve = .continuous

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "waveform.and.mic")
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        iconView.tintColor = .systemGreen
        iconView.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Spoken Margins"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textAlignment = .left
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("Done", for: .normal)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        closeButton.isHidden = true

        view.addSubview(cardView)
        cardView.addSubview(iconView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(statusLabel)
        cardView.addSubview(closeButton)
        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            cardView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cardView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            iconView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -14),

            closeButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: iconView.centerYAnchor)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.close()
        }
    }

    @objc private func close() {
        guard !didCompleteRequest else { return }
        didCompleteRequest = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    nonisolated private static func sharedImport(
        from item: Any?,
        identifier: String,
        presentsPDF: Bool,
        suggestedName: String? = nil
    ) -> SharedImport? {
        if identifier == UTType.propertyList.identifier {
            if let results = browserResultsFromPropertyList(item),
               browserResultsDescribePDF(results),
               let url = firstWebURL(in: results) {
                return .remotePDF(url.absoluteString)
            }
            if let payload = browserPayloadFromPropertyList(item) {
                return .browserText(payload)
            }
            if let results = browserResultsFromPropertyList(item),
               let url = firstWebURL(in: results) {
                return sharedURLImport(
                    url,
                    forcePDF: presentsPDF || browserResultsDescribePDF(results)
                )
            }
        }
        if let url = SourceLinkShareRepresentation.url(from: item) {
            if url.isFileURL {
                if url.pathExtension.lowercased() == "pdf" {
                    return persistedPDFImport(from: url)
                }
                return browserPayloadFromFile(url, identifier: identifier).map(SharedImport.browserText)
            }
            return validatedWebURL(url).map { sharedURLImport($0, forcePDF: presentsPDF) }
        }
        if let data = item as? Data, presentsPDF,
           let persisted = persistedPDFImport(from: data, suggestedName: suggestedName) {
            return persisted
        }
        if let data = item as? Data,
           let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = firstURL(in: cleaned), cleaned == url.absoluteString || cleaned.count < url.absoluteString.count + 20 {
                return sharedURLImport(url, forcePDF: presentsPDF)
            }
            return nil
        }
        if let dictionary = item as? [String: Any] ?? item as? NSDictionary as? [String: Any],
           let url = firstWebURL(in: dictionary) {
            return sharedURLImport(url, forcePDF: presentsPDF)
        }
        if let text = item as? String {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = firstURL(in: cleaned), cleaned == url.absoluteString || cleaned.count < url.absoluteString.count + 20 {
                return sharedURLImport(url, forcePDF: presentsPDF)
            }
            return nil
        }
        return nil
    }

    nonisolated private static func sharedURLImport(_ url: URL, forcePDF: Bool = false) -> SharedImport {
        forcePDF || url.pathExtension.lowercased() == "pdf"
            ? .remotePDF(url.absoluteString)
            : .sourceLink(url.absoluteString)
    }

    nonisolated private static func persistedPDFImport(
        from url: URL,
        suggestedName: String? = nil
    ) -> SharedImport? {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let copiedURL = try? SourceLinkHandoffStore.appGroup().savePDF(
            from: url,
            suggestedFilename: suggestedName
        ) else {
            return nil
        }
        return .localPDF(copiedURL.absoluteString)
    }

    nonisolated private static func persistedPDFImport(
        from data: Data,
        suggestedName: String? = nil
    ) -> SharedImport? {
        guard let copiedURL = try? SourceLinkHandoffStore.appGroup().savePDF(
            data: data,
            suggestedFilename: suggestedName
        ) else {
            return nil
        }
        return .localPDF(copiedURL.absoluteString)
    }

    nonisolated private static func browserPayloadFromFile(
        _ url: URL,
        identifier: String,
        suggestedName: String? = nil
    ) -> BrowserTextSharePayload? {
        let fileExtension = url.pathExtension.lowercased()
        let declaredType = UTType(identifier)
        let isPDF = fileExtension == "pdf" || declaredType?.conforms(to: .pdf) == true
        guard isPDF || ["md", "markdown", "txt"].contains(fileExtension) || declaredType?.conforms(to: .text) == true else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard !isPDF else { return nil }
        let extractedText = try? String(contentsOf: url, encoding: .utf8)
        guard let text = extractedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let isMarkdown = fileExtension == "md" || fileExtension == "markdown"
        let sourceFileName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? suggestedName!
            : url.lastPathComponent
        let sourceTitle = (sourceFileName as NSString).deletingPathExtension
        let encodedFileName = sourceFileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "shared-file"
        return BrowserTextSharePayload(
            id: "browser-text-\(UUID().uuidString)",
            captureMode: isMarkdown ? "markdown_file" : "plain_text_file",
            contentFormat: isMarkdown ? "markdown" : "plain_text",
            source: .init(
                url: "shared-file://share-sheet/\(encodedFileName)",
                title: sourceTitle.isEmpty ? "Shared File" : sourceTitle
            ),
            text: text
        )
    }

    nonisolated private static func browserPayloadFromPropertyList(_ item: Any?) -> BrowserTextSharePayload? {
        guard let results = browserResultsFromPropertyList(item) else { return nil }
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

    nonisolated private static func browserResultsFromPropertyList(_ item: Any?) -> [String: Any]? {
        guard let dictionary = item as? [String: Any] ?? item as? NSDictionary as? [String: Any] else { return nil }
        let rawResults = dictionary[NSExtensionJavaScriptPreprocessingResultsKey]
            ?? dictionary["NSExtensionJavaScriptPreprocessingResultsKey"]
            ?? dictionary
        return rawResults as? [String: Any] ?? rawResults as? NSDictionary as? [String: Any]
    }

    nonisolated private static func browserResultsDescribePDF(_ results: [String: Any]) -> Bool {
        if (results["isPDFDocument"] as? Bool) == true { return true }
        if let contentType = results["contentType"] as? String,
           contentType.lowercased().split(separator: ";", maxSplits: 1).first == "application/pdf" {
            return true
        }
        return ["canonicalURL", "url", "documentURL"]
            .compactMap { results[$0] as? String }
            .compactMap(URL.init(string:))
            .contains { $0.pathExtension.lowercased() == "pdf" }
    }

    nonisolated private static func acceptsRegisteredIdentifier(_ identifier: String, suggestedName: String?) -> Bool {
        if identifier == SpokenMarginsPackageHandoffStore.uniformTypeIdentifier
            || ((suggestedName ?? "") as NSString).pathExtension.lowercased() == SpokenMarginsPackageHandoffStore.fileExtension {
            return true
        }
        guard let type = UTType(identifier), type.conforms(to: .text) else { return true }
        let fileExtension = ((suggestedName ?? "") as NSString).pathExtension.lowercased()
        return ["md", "markdown", "txt"].contains(fileExtension)
    }

    nonisolated private static func isSpokenMarginsPackage(_ candidate: ProviderCandidate) -> Bool {
        candidate.identifier == SpokenMarginsPackageHandoffStore.uniformTypeIdentifier
            || ((candidate.provider.suggestedName ?? "") as NSString).pathExtension.lowercased()
                == SpokenMarginsPackageHandoffStore.fileExtension
    }

    nonisolated private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?.matches(in: text, options: [], range: range).compactMap(\.url).first.flatMap(validatedWebURL)
    }

    nonisolated private static func firstWebURL(in value: Any) -> URL? {
        if let url = value as? URL {
            return validatedWebURL(url)
        }
        if let text = value as? String {
            return firstURL(in: text)
        }
        if let dictionary = value as? [String: Any] {
            let preferredKeys = ["url", "URL", "shareURL", "episodeURL", "canonicalURL", "link"]
            for key in preferredKeys {
                if let nested = dictionary[key], let url = firstWebURL(in: nested) {
                    return url
                }
            }
            for nested in dictionary.values {
                if let url = firstWebURL(in: nested) {
                    return url
                }
            }
        }
        if let array = value as? [Any] {
            for nested in array {
                if let url = firstWebURL(in: nested) {
                    return url
                }
            }
        }
        return nil
    }

    nonisolated private static func validatedWebURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}

private enum SourceLinkShareError: Error, LocalizedError {
    case noInput
    case unsupportedInput(String = "")

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "No shared input was provided."
        case .unsupportedInput(let identifiers):
            let representationNote = identifiers.isEmpty ? "" : " Safari supplied: \(identifiers)."
            return "Spoken Margins could not read this share. Share a .spokenmargins session, web page, podcast link, PDF, Markdown file, or text file.\(representationNote)"
        }
    }
}
