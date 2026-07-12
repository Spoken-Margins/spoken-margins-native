import UIKit
import UniformTypeIdentifiers

final class SourceLinkShareViewController: UIViewController, @unchecked Sendable {
    private struct ProviderCandidate: @unchecked Sendable {
        let provider: NSItemProvider
        let identifier: String
    }

    private var didProcess = false
    private typealias ExtractionCompletion = @Sendable (Result<String, Error>) -> Void
    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var savedPayloadID: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureStatusUI()
        updateStatus("Preparing shared link...")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didProcess else { return }
        didProcess = true
        extractSharedURL { [weak self] result in
            DispatchQueue.main.async {
                self?.handle(result)
            }
        }
    }

    private func extractSharedURL(completion: @escaping ExtractionCompletion) {
        let providers = extensionContext?.inputItems
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] } ?? []
        guard !providers.isEmpty else {
            completion(.failure(SourceLinkShareError.noInput))
            return
        }
        let preferredIdentifiers = [
            UTType.url.identifier,
            UTType.propertyList.identifier,
            UTType.plainText.identifier,
            UTType.text.identifier
        ]
        let candidates = providers.flatMap { provider -> [ProviderCandidate] in
            let identifiers = preferredIdentifiers.filter(provider.hasItemConformingToTypeIdentifier)
                + provider.registeredTypeIdentifiers.filter { !preferredIdentifiers.contains($0) }
            return identifiers.map { ProviderCandidate(provider: provider, identifier: $0) }
        }
        loadFirstSharedURL(candidates, index: 0, completion: completion)
    }

    private func loadFirstSharedURL(
        _ candidates: [ProviderCandidate],
        index: Int,
        completion: @escaping ExtractionCompletion
    ) {
        guard index < candidates.count else {
            completion(.failure(SourceLinkShareError.noURL))
            return
        }
        let candidate = candidates[index]
        candidate.provider.loadItem(forTypeIdentifier: candidate.identifier, options: nil) { [weak self] item, _ in
            if let url = Self.urlFromSharedItem(item) {
                completion(.success(url.absoluteString))
            } else {
                DispatchQueue.main.async {
                    self?.loadFirstSharedURL(candidates, index: index + 1, completion: completion)
                }
            }
        }
    }

    private func handle(_ result: Result<String, Error>) {
        switch result {
        case .success(let inputURL):
            let handoff = SourceLinkHandoff(
                id: "source-link-\(UUID().uuidString)",
                inputURL: inputURL,
                sourceSurface: "share_sheet",
                startSession: false
            )
            do {
                let store = try SourceLinkHandoffStore.appGroup()
                savedPayloadID = try store.save(handoff)
                showSaved()
            } catch {
                completeWithError(error)
            }
        case .failure(let error):
            completeWithError(error)
        }
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

        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.setTitle("Open Spoken Margins", for: .normal)
        openButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        openButton.addTarget(self, action: #selector(openSpokenMargins), for: .touchUpInside)
        openButton.isHidden = true

        view.addSubview(statusLabel)
        view.addSubview(openButton)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            openButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            openButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            closeButton.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 12),
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

    private func showSaved() {
        updateStatus("Saved to Spoken Margins. Open the app to finish importing this link.")
        openButton.isHidden = false
        closeButton.isHidden = false
    }

    @objc private func openSpokenMargins() {
        guard let savedPayloadID else { return }
        let url = SourceLinkHandoffURL.url(forPayloadID: savedPayloadID)
        extensionContext?.open(url) { [weak self] opened in
            DispatchQueue.main.async {
                if opened {
                    self?.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self?.showError("Spoken Margins could not be opened. The saved link remains available.")
                }
            }
        }
    }

    @objc private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    nonisolated private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?
            .matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .first
    }

    nonisolated private static func urlFromPropertyList(_ item: Any?) -> URL? {
        guard let dictionary = item as? [String: Any] ?? item as? NSDictionary as? [String: Any] else {
            return nil
        }
        let rawResults = dictionary[NSExtensionJavaScriptPreprocessingResultsKey]
            ?? dictionary["NSExtensionJavaScriptPreprocessingResultsKey"]
            ?? dictionary
        guard let results = rawResults as? [String: Any] ?? rawResults as? NSDictionary as? [String: Any] else {
            return nil
        }
        let candidates = [
            results["canonicalURL"],
            results["url"],
            results["URL"],
            results["documentURL"]
        ]
        for candidate in candidates {
            if let value = candidate as? String, let url = URL(string: value) {
                return url
            }
        }
        return nil
    }

    nonisolated private static func urlFromSharedItem(_ item: Any?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let text = item as? String {
            return firstURL(in: text) ?? URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let data = item as? Data,
           let text = String(data: data, encoding: .utf8),
           let url = firstURL(in: text) {
            return url
        }
        if let url = urlFromPropertyList(item) {
            return url
        }
        if let values = item as? [Any] {
            return values.lazy.compactMap(urlFromSharedItem).first
        }
        if let dictionary = item as? NSDictionary {
            return dictionary.allValues.lazy.compactMap(urlFromSharedItem).first
        }
        return nil
    }
}

private enum SourceLinkShareError: Error, LocalizedError {
    case noInput
    case noURL

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "No shared input was provided."
        case .noURL:
            return "No URL was found in the shared input."
        }
    }
}
