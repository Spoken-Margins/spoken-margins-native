import SwiftUI

/// Licenses for the open-source code compiled into the app and its
/// extensions. The on-device voice's licenses live in `SupertonicLegalView`.
struct OpenSourceLicensesView: View {
    struct Document: Identifiable {
        let title: String
        let detail: String
        let resourceName: String
        let subdirectory: String?

        var id: String { resourceName }
    }

    static let documents: [Document] = [
        Document(
            title: "ZIPFoundation",
            detail: "MIT · packet import and export",
            resourceName: "ZIPFoundation-LICENSE",
            subdirectory: "Legal"
        ),
        Document(
            title: "Fallback voice",
            detail: "Apache-2.0 · the bundled backup voice",
            resourceName: "NOTICES",
            subdirectory: "Kitten"
        ),
        Document(
            title: "Kokoro voice runtime",
            detail: "Apache-2.0 · runs the downloadable Kokoro voice",
            resourceName: "Kokoro-NOTICES",
            subdirectory: "Kokoro"
        ),
        Document(
            title: "CMU Pronouncing Dictionary",
            detail: "BSD-style · the backup voice's pronunciations",
            resourceName: "CMUdict-LICENSE",
            subdirectory: "Kitten"
        ),
        Document(
            title: "Defuddle",
            detail: "MIT · reading web pages",
            resourceName: "Defuddle-LICENSE",
            subdirectory: nil
        ),
        Document(
            title: "Web page reader packages",
            detail: "Every package compiled into the web page reader",
            resourceName: "BundledJavaScript-NOTICES",
            subdirectory: nil
        )
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.documents) { document in
                    NavigationLink {
                        OpenSourceLicenseDocumentView(document: document)
                            .miniPlayerKeepOut()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(document.title)
                            Text(document.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("legal.openSource.\(document.resourceName)")
                }
            } footer: {
                Text("The on-device voice's licenses are under Legal · On-Device Voice.")
            }
        }
        .navigationTitle("Open-Source Licenses")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("legal.openSource.screen")
    }

    static func bundledText(for document: Document, in bundle: Bundle = .main) -> String {
        guard let url = bundle.url(
            forResource: document.resourceName,
            withExtension: "txt",
            subdirectory: document.subdirectory
        ), let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "Bundled notice unavailable."
        }
        return contents
    }
}

private struct OpenSourceLicenseDocumentView: View {
    let document: OpenSourceLicensesView.Document

    var body: some View {
        ScrollView {
            Text(OpenSourceLicensesView.bundledText(for: document))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
