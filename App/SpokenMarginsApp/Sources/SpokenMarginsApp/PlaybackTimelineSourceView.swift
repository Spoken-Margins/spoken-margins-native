import SwiftUI
import SessionKit

/// Displays retained authored text without replacing figures with generated descriptions.
struct PlaybackTimelineSourceView: View {
    struct Selection: Identifiable {
        let entry: TimelineSourceContent.Entry
        let sourceReference: String
        var id: String { entry.id }
    }

    let selection: Selection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let page = selection.entry.pageIndex {
                        Text("Page \(page + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(selection.entry.text)
                        .font(selection.entry.role == .table ? .body.monospaced() : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = URL(string: selection.sourceReference),
                       ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Link("Open original source", destination: url).frame(minHeight: 44)
                    }
                }
                .padding()
            }
            .navigationTitle(selection.entry.label ?? selection.entry.role.timelineTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .accessibilityIdentifier("timeline.sourceText.detail")
    }
}

extension StructuredDocument.Role {
    var timelineTitle: String {
        switch self {
        case .title: "Title"
        case .heading: "Heading"
        case .abstract: "Abstract"
        case .caption: "Caption"
        case .table: "Table"
        case .footnote: "Footnote"
        case .equation: "Equation"
        case .reference: "Reference"
        case .authors: "Authors"
        case .frontMatter: "Front matter"
        case .backMatter: "Back matter"
        case .pageHeader: "Page header"
        case .pageFooter: "Page footer"
        case .figureText: "Text in figure"
        case .body, .unknown: "Passage"
        }
    }
}
