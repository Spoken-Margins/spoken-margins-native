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
        /// Set for shared text, so each share is its own Library item (#662).
        var itemId: String?
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
        /// Plain text another app shared, such as a ChatGPT response (#662). Used only when
        /// nothing else in the share yields a file, PDF, page or link.
        case sharedText(BrowserTextSharePayload)
        case spokenMarginsPackage

        /// A link the app would download again, rather than content the share carried.
        var isLink: Bool {
            switch self {
            case .sourceLink, .remotePDF: true
            case .localPDF, .browserText, .sharedText, .spokenMarginsPackage: false
            }
        }
    }

    private var didProcess = false
    /// Each attachment's registered types, for the share diagnostics (#271).
    private var sharedAttachmentTypes: [[String]] = []
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
        sharedAttachmentTypes = providers.map(\.registeredTypeIdentifiers)
        guard !providers.isEmpty else {
            completion(.failure(SourceLinkShareError.noInput))
            return
        }
        // Safari's PDF viewer offers the PDF it is showing as well as its URL.
        // The PDF comes first: a re-download of the link can return an HTML
        // page instead (#271). The file is only copied here, never parsed.
        // Ordinary webpages still prefer the readable-page property list, and
        // links wait until every other representation has been tried.
        let candidates = ShareSheetRepresentationOrder.candidates(
            from: providers,
            conforms: { $0.hasItemConformingToTypeIdentifier($1) },
            additionalIdentifiers: { provider, preferredIdentifiers in
                provider.registeredTypeIdentifiers.filter {
                    !preferredIdentifiers.contains($0)
                        && Self.acceptsRegisteredIdentifier($0, suggestedName: provider.suggestedName)
                }
            }
        ).map { ProviderCandidate(provider: $0.provider, identifier: $0.identifier) }
        // Plain text another app shared goes after everything, links included (#662), so a link
        // written in a share's text never replaces the share's own public.url.
        let isSharedText = { (candidate: ProviderCandidate) in
            SharedTextIntake.isPlainText(candidate.identifier)
                && !SharedTextIntake.namesTextFile(candidate.provider.suggestedName)
        }
        let ordered = candidates.filter { !isSharedText($0) } + candidates.filter(isSharedText)
        // The walk is shared with the app's tests (#1049): it hands off the first content any candidate
        // yields, a link only once no file, PDF or page result is left to try (#271), and shared text
        // only once nothing else is left (#662).
        ShareSheetCandidateWalk.run(
            ordered,
            identifier: \.identifier,
            load: { candidate, report in Self.loadCandidate(candidate, report: report) },
            resume: { next in DispatchQueue.main.async(execute: next) },
            completion: { result in
                guard let result else {
                    let identifiers = Array(Set(ordered.map(\.identifier))).sorted().joined(separator: ", ")
                    completion(.failure(SourceLinkShareError.unsupportedInput(identifiers)))
                    return
                }
                completion(result)
            }
        )
    }

    private typealias CandidateReport = @Sendable (ShareSheetCandidateOutcome<SharedImport>) -> Void

    /// Loads one candidate and reports what it yielded, once.
    nonisolated private static func loadCandidate(_ candidate: ProviderCandidate, report: @escaping CandidateReport) {
        let candidateType = UTType(candidate.identifier)
        if isSpokenMarginsPackage(candidate) {
            candidate.provider.loadFileRepresentation(forTypeIdentifier: candidate.identifier) { url, error in
                guard let url else {
                    report(.failed(error ?? SourceLinkShareError.unsupportedInput()))
                    return
                }
                do {
                    _ = try SpokenMarginsPackageHandoffStore.appGroup().savePackage(
                        from: url,
                        suggestedFilename: candidate.provider.suggestedName
                    )
                    report(.content(.spokenMarginsPackage))
                } catch {
                    report(.failed(error))
                }
            }
            return
        }
        if candidateType?.conforms(to: .pdf) == true {
            candidate.provider.loadFileRepresentation(forTypeIdentifier: candidate.identifier) { url, _ in
                if let url {
                    if let sharedImport = persistedPDFImport(
                        from: url,
                        suggestedName: candidate.provider.suggestedName
                    ) {
                        report(.content(sharedImport))
                    } else {
                        // The file exists but couldn't be copied (over the
                        // size limit, say). Loading the same bytes into the
                        // extension's memory won't help, so fall back to the
                        // next representation, such as the URL.
                        report(.nothing)
                    }
                } else {
                    loadCandidateItem(candidate, report: report)
                }
            }
            return
        }
        // A named Markdown or text file is read as a file. Plain text with no file name is loaded
        // as a string below, so its title comes from its first words, not a temporary file name.
        if candidateType?.conforms(to: .text) == true, SharedTextIntake.namesTextFile(candidate.provider.suggestedName) {
            candidate.provider.loadFileRepresentation(forTypeIdentifier: candidate.identifier) { url, _ in
                if let url,
                   let payload = browserPayloadFromFile(
                       url,
                       identifier: candidate.identifier,
                       suggestedName: candidate.provider.suggestedName
                   ) {
                    report(.content(.browserText(payload)))
                } else {
                    loadCandidateItem(candidate, report: report)
                }
            }
            return
        }
        loadCandidateItem(candidate, report: report)
    }

    nonisolated private static func loadCandidateItem(_ candidate: ProviderCandidate, report: @escaping CandidateReport) {
        candidate.provider.loadItem(forTypeIdentifier: candidate.identifier, options: nil) { item, _ in
            let presentsPDF = candidate.provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            // A PDF representation that loads as a web URL would send the link again (#271),
            // so for those only a file or bytes count; otherwise try the data representation.
            // The link is kept as the last fallback, after the data and every other attachment.
            let isPDFCandidate = UTType(candidate.identifier)?.conforms(to: .pdf) == true
            let pdfFallbackLink = isPDFCandidate
                ? SourceLinkShareRepresentation.pdfFallbackLink(from: item).map { SharedImport.remotePDF($0.absoluteString) }
                : nil
            let sharedImport = isPDFCandidate
                ? sharedPDFImport(from: item, suggestedName: candidate.provider.suggestedName)
                : Self.sharedImport(
                    from: item,
                    identifier: candidate.identifier,
                    presentsPDF: presentsPDF,
                    suggestedName: candidate.provider.suggestedName
                )
            if let sharedImport, case .sharedText = sharedImport {
                // A file, PDF, page or link elsewhere in the share wins over its text (#662).
                report(.sharedText(sharedImport))
            } else if let sharedImport {
                report(sharedImport.isLink ? .link(sharedImport) : .content(sharedImport))
            } else if presentsPDF {
                candidate.provider.loadDataRepresentation(forTypeIdentifier: candidate.identifier) { data, _ in
                    if let data,
                       let sharedImport = persistedPDFImport(
                           from: data,
                           suggestedName: candidate.provider.suggestedName
                       ) {
                        report(.content(sharedImport))
                    } else if let pdfFallbackLink {
                        report(.link(pdfFallbackLink))
                    } else {
                        report(.nothing)
                    }
                }
            } else {
                report(.nothing)
            }
        }
    }

    private func handle(_ result: Result<SharedImport, Error>) {
        recordShareDiagnostics(result)
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
            case .success(.browserText(let payload)), .success(.sharedText(let payload)):
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

    /// Writes what the share offered and which route won to the App Group, so a lane run
    /// can tell which representations Safari sent (#271). Type identifiers and the route
    /// only: no URLs, titles or text. Best effort; a failure never affects the share.
    private func recordShareDiagnostics(_ result: Result<SharedImport, Error>) {
        let route: String
        switch result {
        case .success(.sourceLink): route = "share_sheet"
        case .success(.remotePDF): route = "share_sheet_pdf"
        case .success(.localPDF): route = "share_sheet_pdf_file"
        case .success(.browserText): route = "browser_text"
        case .success(.sharedText): route = "shared_text"
        case .success(.spokenMarginsPackage): route = "spoken_margins_package"
        case .failure: route = "failed"
        }
        let record: [String: Any] = [
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "attachmentTypes": sharedAttachmentTypes,
            "route": route
        ]
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SourceLinkHandoffStore.appGroupIdentifier
        ), let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        let directory = containerURL.appendingPathComponent("ShareExtensionDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("last-share.json"), options: [.atomic])
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
        titleLabel.adjustsFontForContentSizeCategory = true
        // Wraps at the largest text sizes instead of truncating (#1941).
        titleLabel.numberOfLines = 0
        titleLabel.textColor = .label

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textAlignment = .left
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("Done", for: .normal)
        closeButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
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
            // Top-aligned with the icon and at least as tall, so one line stays centred on it and a wrapped title grows down.
            titleLabel.topAnchor.constraint(equalTo: iconView.topAnchor),
            titleLabel.heightAnchor.constraint(greaterThanOrEqualTo: iconView.heightAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -14),

            closeButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            // Done is the only way out after an error, so it gets a 44 pt hit area (#1918).
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func updateStatus(_ text: String) {
        statusLabel.text = text
        // The label changes in place, which VoiceOver doesn't speak by itself, and a saved share closes soon after.
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func showError(_ message: String) {
        updateStatus(message)
        closeButton.isHidden = false
    }

    private func showSaved(_ message: String) {
        updateStatus(message)
        closeButton.isHidden = false
        // With VoiceOver or Switch Control on, stay until Done so the status can be heard and Done reached.
        guard ShareSheetSavedClosePolicy.closesAutomatically(
            voiceOverRunning: UIAccessibility.isVoiceOverRunning,
            switchControlRunning: UIAccessibility.isSwitchControlRunning
        ) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + ShareSheetSavedClosePolicy.closeDelay) { [weak self] in
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
        if identifier == UTType.propertyList.identifier,
           var results = browserResultsFromPropertyList(item) {
            // The preprocessor sends the open PDF's bytes when it can (#271). Take them out
            // first, so the link search below never scans megabytes of base64.
            let pagePDF = SourceLinkShareRepresentation.pagePDF(fromPageResults: results)
            results.removeValue(forKey: SourceLinkShareRepresentation.pagePDFKey)
            if browserResultsDescribePDF(results) {
                if let pagePDF,
                   let persisted = persistedPDFImport(from: pagePDF.data, suggestedName: pagePDF.suggestedFilename) {
                    return persisted
                }
                if let url = firstWebURL(in: results) {
                    return .remotePDF(url.absoluteString)
                }
            }
            if let payload = browserPayload(fromResults: results) {
                return .browserText(payload)
            }
            if let url = firstWebURL(in: results) {
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
            return sharedTextImport(cleaned, identifier: identifier, presentsPDF: presentsPDF)
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
            return sharedTextImport(cleaned, identifier: identifier, presentsPDF: presentsPDF)
        }
        return nil
    }

    /// Plain text shared as a string (#662): a lone link goes as that link, as Paste & go decides,
    /// and anything else becomes a text item holding the whole text.
    nonisolated private static func sharedTextImport(_ text: String, identifier: String, presentsPDF: Bool) -> SharedImport? {
        guard SharedTextIntake.isPlainText(identifier) else { return nil }
        switch SharedTextIntake.route(text) {
        case .link(let url):
            return sharedURLImport(url, forcePDF: presentsPDF)
        case .text(let title, let body):
            return .sharedText(BrowserTextSharePayload(
                id: "browser-text-\(UUID().uuidString)",
                itemId: SharedTextIntake.newItemID(),
                captureMode: "plain_text_file",
                contentFormat: "markdown",
                source: .init(url: SharedTextIntake.sourceURL, title: title),
                text: body
            ))
        case nil:
            return nil
        }
    }

    /// A PDF representation's item: a copied file or bytes, never a link.
    nonisolated private static func sharedPDFImport(from item: Any?, suggestedName: String?) -> SharedImport? {
        if let url = SourceLinkShareRepresentation.url(from: item), url.isFileURL {
            return persistedPDFImport(from: url, suggestedName: suggestedName)
        }
        if let data = item as? Data {
            return persistedPDFImport(from: data, suggestedName: suggestedName)
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

    nonisolated private static func browserPayload(fromResults results: [String: Any]) -> BrowserTextSharePayload? {
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
        return SharedTextIntake.acceptsTextRepresentation(identifier: identifier, suggestedName: suggestedName)
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
            let representationNote = identifiers.isEmpty ? "" : " The share offered: \(identifiers)."
            return "Spoken Margins could not read this share, so nothing was added. Share a .spokenmargins session, web page, podcast link, PDF, text, or a Markdown or text file. Or copy the text and use Paste & go.\(representationNote)"
        }
    }
}
