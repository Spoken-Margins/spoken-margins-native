import Foundation
import AVFoundation
import SessionKit
import SwiftUI
import UIKit
import WebKit

struct ArticleExtractionResult: Equatable {
    var canonicalURL: String?
    var title: String
    var author: String?
    var publishedAt: String?
    var text: String
    var contentFormat: BrowserTextContentFormat
    var extractor: String
}

struct ArticleAcquisitionState: Identifiable {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
        case creating
    }

    var id: String
    var originalURL: String
    var canonicalURL: String
    var title: String
    var packageManifest: InterjectionPackageManifest?
    var extractedAudioURLs: [String: URL]
    var capturedExtraction: ArticleExtractionResult?
    var visibleExtraction: ArticleExtractionResult?
    var pendingSourceLinkPayloadID: String?
    var pendingBrowserTextPayloadID: String?
    var phase: Phase

    var extraction: ArticleExtractionResult? { visibleExtraction ?? capturedExtraction }
    var interjectionCount: Int { packageManifest?.interjections.count ?? 0 }
    var primaryActionTitle: String {
        interjectionCount > 0
            ? "Create Item & Add \(interjectionCount) Shared Interjection\(interjectionCount == 1 ? "" : "s")"
            : "Create Item from This Page"
    }
}

struct ShareInterjectionDraft: Identifiable {
    var id: String { interjection.id }
    var interjection: Interjection
    var isIncluded: Bool
    var approvedTranscript: String
    var cleanup: InterjectionCleanupResult?
    var cleanedAudioURL: URL?
    var cleanedAudioDurationMs: Int?
    var warning: String?
    var anchorBefore = ""
    var anchorAfter = ""
}

struct InterjectionSharingState {
    var drafts: [ShareInterjectionDraft] = []
    var senderDisplayLabel = UserDefaults.standard.string(forKey: "sharingSenderDisplayLabel") ?? ""
    var isPreparing = false
    var isExporting = false
    var errorMessage: String?
}

struct ImportedCommentaryPrompt: Identifiable {
    var id: String { interjection.id }
    var layer: ImportedCommentaryLayer
    var interjection: ImportedCommentaryInterjection
    var index: Int
    var count: Int

    var senderLabel: String { layer.displayLabel?.nilIfEmpty ?? "Unsigned sender" }
}

struct ArticleAcquisitionView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let acquisition: ArticleAcquisitionState
    @State private var isReaderPreviewExpanded = false

    var body: some View {
        NavigationStack {
            Group {
                if horizontalSizeClass == .regular {
                    HStack(spacing: 0) {
                        browser
                        Divider()
                        importPanel
                            .frame(width: 390)
                    }
                } else {
                    VStack(spacing: 0) {
                        browser
                        importPanel
                    }
                }
            }
            .navigationTitle("Add Article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: model.cancelArticleAcquisition)
                }
            }
        }
        .interactiveDismissDisabled(acquisition.packageManifest != nil)
    }

    private var browser: some View {
        VisibleArticleWebView(
            acquisitionID: acquisition.id,
            urlString: acquisition.canonicalURL,
            onExtraction: model.articleAcquisitionDidExtract,
            onFailure: model.articleAcquisitionDidFail
        )
        .overlay(alignment: .top) {
            if acquisition.phase == .loading {
                ProgressView("Reading the visible page…")
                    .padding(10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let manifest = acquisition.packageManifest {
                VStack(alignment: .leading, spacing: 4) {
                    Text(manifest.senderDisplayLabel?.isEmpty == false ? manifest.senderDisplayLabel! : "Someone")
                        .font(.headline)
                    Text("Integrity checked · Unsigned sender")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(manifest.interjections.count) shared interjection\(manifest.interjections.count == 1 ? "" : "s")")
                        .font(.subheadline)
                }
            }

            if let extraction = acquisition.extraction {
                DisclosureGroup("Reader Preview", isExpanded: $isReaderPreviewExpanded) {
                    ScrollView {
                        Text(extraction.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                Text(extraction.title)
                    .font(.headline)
                if let author = extraction.author, !author.isEmpty {
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if case .failed(let message) = acquisition.phase {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            Button(action: model.confirmArticleAcquisition) {
                Text(acquisition.primaryActionTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(acquisition.extraction?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false || acquisition.phase == .creating)

            if case .failed = acquisition.phase {
                Button("Retry", action: model.retryArticleAcquisition)
                    .buttonStyle(SecondaryButtonStyle())
            }
            Button("Open in Safari & Send to Spoken Margins", action: model.openArticleFallbackInSafari)
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.background)
    }
}

struct InterjectionSharingView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.sharingState.isPreparing {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Preparing deterministic share revisions…")
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ProductPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("What leaves this device")
                                        .font(.headline)
                                    Text("Only the approved transcript, derived cleaned audio when available, bounded anchor context, source attribution, and optional display label. Raw recordings, raw transcripts, full source text or audio, diagnostics, and unrelated turns are excluded.")
                                        .font(.callout)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                            }
                            TextField("Your display label (optional)", text: $model.sharingState.senderDisplayLabel)
                                .textFieldStyle(.roundedBorder)

                            DisclosureGroup("Recipient field inventory") {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Package: package ID, creation time, conversation lineage, SHA-256 integrity digest")
                                    Text("Source: type, canonical/original URL, title, available attribution and edition evidence")
                                    Text("Each selected margin: package ID, source anchor, approved transcript, provenance, optional reply target")
                                    ForEach(model.sharingState.drafts.filter(\.isIncluded)) { draft in
                                        Text(draft.cleanedAudioURL == nil
                                            ? "\(draft.id): text only; no attachment"
                                            : "\(draft.id): audio/…m4a, \(draft.cleanedAudioDurationMs ?? 0) ms")
                                    }
                                    Text("Redaction proof: raw audio/transcript, source text/audio, diagnostics, paths, and unrelated turns omitted")
                                }
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .textSelection(.enabled)
                            }

                            ForEach(model.sharingState.drafts) { draft in
                                shareDraftCard(draft)
                            }

                            if let error = model.sharingState.errorMessage {
                                Text(error).foregroundStyle(.red).font(.callout)
                            }

                            Button(action: model.exportSharedInterjections) {
                                if model.sharingState.isExporting {
                                    ProgressView().frame(maxWidth: .infinity)
                                } else {
                                    Text("Previewed — Share Package").frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.sharingState.drafts.allSatisfy { !$0.isIncluded } || model.sharingState.isExporting)
                        }
                        .padding(20)
                    }
                }
            }
            .navigationTitle("Share Interjections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func shareDraftCard(_ draft: ShareInterjectionDraft) -> some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Include interjection",
                    isOn: Binding(
                        get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.isIncluded ?? false },
                        set: { model.setShareDraftIncluded(draft.id, included: $0) }
                    )
                )
                .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Original private transcript").font(.caption.weight(.semibold))
                    Text(draft.interjection.transcript ?? "Unavailable")
                        .font(.callout)
                        .foregroundStyle(AppColors.secondaryText)
                        .textSelection(.enabled)
                    Text("Reviewed transcript sent").font(.caption.weight(.semibold)).padding(.top, 4)
                }
                TextEditor(text: Binding(
                    get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.approvedTranscript ?? "" },
                    set: { model.setShareDraftTranscript(draft.id, transcript: $0) }
                ))
                .frame(minHeight: 100)
                .padding(8)
                .background(AppColors.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(!draft.isIncluded)

                if let decisions = draft.cleanup?.decisions, !decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Deterministic edits").font(.subheadline.weight(.semibold))
                        ForEach(decisions) { decision in
                            Toggle(
                                decisionLabel(decision),
                                isOn: Binding(
                                    get: {
                                        model.sharingState.drafts
                                            .first(where: { $0.id == draft.id })?
                                            .cleanup?.decisions.first(where: { $0.id == decision.id })?.accepted ?? false
                                    },
                                    set: { model.setCleanupDecision(draftID: draft.id, decisionID: decision.id, accepted: $0) }
                                )
                            )
                            .font(.caption)
                        }
                    }
                }

                if let audioURL = draft.cleanedAudioURL {
                    ShareRevisionAudioPreviewButton(url: audioURL)
                }
                if let warning = draft.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Shared anchor excerpt").font(.subheadline.weight(.semibold))
                    TextField("Context before", text: Binding(
                        get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.anchorBefore ?? "" },
                        set: { model.setShareDraftAnchorBefore(draft.id, value: $0) }
                    ), axis: .vertical)
                    TextField("Context after", text: Binding(
                        get: { model.sharingState.drafts.first(where: { $0.id == draft.id })?.anchorAfter ?? "" },
                        set: { model.setShareDraftAnchorAfter(draft.id, value: $0) }
                    ), axis: .vertical)
                    Text("Shorten either excerpt before sharing; complete source text is never included.")
                        .font(.caption2)
                        .foregroundStyle(AppColors.secondaryText)
                }

                Text("Anchor sent: \(boundedAnchorDescription(draft))")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
        .opacity(draft.isIncluded ? 1 : 0.62)
    }

    private func decisionLabel(_ decision: InterjectionCleanupDecision) -> String {
        switch decision.kind {
        case .filler: return "Remove “\(decision.originalText ?? "filler")”"
        case .isolatedPhrase: return "Remove isolated “\(decision.originalText ?? "phrase")”"
        case .longPause: return "Shorten \(max(0, decision.endMs - decision.startMs)) ms pause"
        }
    }

    private func boundedAnchorDescription(_ draft: ShareInterjectionDraft) -> String {
        let before = String(draft.anchorBefore.suffix(80))
        let after = String(draft.anchorAfter.prefix(80))
        if before.isEmpty && after.isEmpty {
            return draft.interjection.anchor.mediaTimeMs.map { "source time \($0 / 1_000) seconds" } ?? "context unavailable"
        }
        return [before, after].filter { !$0.isEmpty }.joined(separator: " … ")
    }
}

private struct ShareRevisionAudioPreviewButton: View {
    let url: URL
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        Button {
            if isPlaying {
                player?.stop()
                isPlaying = false
            } else if let audio = try? AVAudioPlayer(contentsOf: url) {
                player = audio
                audio.play()
                isPlaying = true
            }
        } label: {
            Label(isPlaying ? "Stop Clean Audio Preview" : "Preview Clean Audio", systemImage: isPlaying ? "stop.fill" : "play.fill")
        }
        .buttonStyle(SecondaryButtonStyle())
    }
}

struct SharedInterjectionPackageActivityView: UIViewControllerRepresentable {
    let packageURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let explanationURL = URL(string: "https://spokenmargins.proximitytoprogress.com/share/")!
        return UIActivityViewController(
            activityItems: [packageURL, explanationURL],
            applicationActivities: [CopySharingExplanationLinkActivity(url: explanationURL)]
        )
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private final class CopySharingExplanationLinkActivity: UIActivity {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init()
    }

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("com.spokenmargins.copy-explanation-link")
    }

    override var activityTitle: String? { "Copy explanation link" }
    override var activityImage: UIImage? { UIImage(systemName: "link") }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override func perform() {
        UIPasteboard.general.url = url
        activityDidFinish(true)
    }
}

private struct VisibleArticleWebView: UIViewRepresentable {
    let acquisitionID: String
    let urlString: String
    let onExtraction: (String, ArticleExtractionResult) -> Void
    let onFailure: (String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.load(urlString, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loadedURLString != urlString else { return }
        context.coordinator.load(urlString, in: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: VisibleArticleWebView
        var loadedURLString: String?

        init(parent: VisibleArticleWebView) {
            self.parent = parent
        }

        func load(_ value: String, in webView: WKWebView) {
            guard let url = URL(string: value), url.scheme?.lowercased() == "https" else {
                parent.onFailure(parent.acquisitionID, "Only secure HTTPS article pages can be imported.")
                return
            }
            loadedURLString = value
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let scriptURL = Bundle.main.url(forResource: "SourceLinkPreprocessor", withExtension: "js"),
                  let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
                parent.onFailure(parent.acquisitionID, "The reader extractor is unavailable in this build.")
                return
            }
            let invocation = """
            ;(() => { var output = null;
              new SourceLinkPreprocessor().run({completionFunction: result => { output = result; }});
              return output;
            })()
            """
            webView.evaluateJavaScript(script + invocation) { [weak self] value, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.parent.onFailure(self.parent.acquisitionID, error.localizedDescription)
                        return
                    }
                    guard let dictionary = value as? [String: Any] else {
                        self.parent.onFailure(self.parent.acquisitionID, "No readable page text was found.")
                        return
                    }
                    let markdown = (dictionary["markdown"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let fallback = (dictionary["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let text = markdown.isEmpty ? fallback : markdown
                    guard !text.isEmpty else {
                        self.parent.onFailure(self.parent.acquisitionID, "No readable page text was found.")
                        return
                    }
                    self.parent.onExtraction(self.parent.acquisitionID, ArticleExtractionResult(
                        canonicalURL: dictionary["canonicalURL"] as? String,
                        title: (dictionary["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Shared Web Page",
                        author: dictionary["author"] as? String,
                        publishedAt: dictionary["publishedAt"] as? String,
                        text: text,
                        contentFormat: markdown.isEmpty ? .plainText : .markdown,
                        extractor: dictionary["extractor"] as? String ?? "visible_page_fallback"
                    ))
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onFailure(parent.acquisitionID, error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.onFailure(parent.acquisitionID, error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .cancel
            }
            if url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "about" {
                return .allow
            } else {
                await UIApplication.shared.open(url)
                return .cancel
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
