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
                        Text("Page \(page + 1)").font(.caption).foregroundStyle(AppColors.secondaryText)
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

extension SourceElement.Kind {
    var timelineName: String {
        switch self {
        case .picture: "Picture"
        case .embed: "Embed"
        case .link: "Link"
        case .table: "Table"
        }
    }
}

extension SourceElement {
    /// The second line of a Timeline row: what kind of element it is, and for a link, where it goes.
    var timelineDetail: String {
        guard kind == .link, let host = URL(string: url)?.host else { return kind.timelineName }
        return "Link · " + (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }
}

/// A picture, embed, link or table from the imported page, at full size: the picture (a GIF plays) or the whole
/// table, its description, and the address to open. Pictures load when Timeline draws a row (owner, 2026-11-17),
/// and this sheet shows the same picture from the loader's copy; the import itself fetches nothing but the page (#2032).
struct PlaybackTimelineElementView: View {
    let element: SourceElement
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let url = element.previewImageURL {
                        SourcePictureView(url: url, accessibilityText: element.altText ?? element.label)
                    }
                    if element.kind == .table, let rows = element.rows {
                        SourceTableView(rows: rows)
                    }
                    if element.kind != .table {
                        Text(element.label)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let alt = element.altText, alt != element.label {
                        Text("Picture description: \(alt)").font(.callout).foregroundStyle(AppColors.secondaryText)
                            .textSelection(.enabled)
                    }
                    if let url = URL(string: element.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Link(element.kind == .link ? "Open link" : "Open on the web", destination: url).frame(minHeight: 44)
                    }
                }
                .padding()
            }
            .navigationTitle(element.kind.timelineName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .accessibilityIdentifier("timeline.sourceElement.detail")
    }
}

extension SourceElement {
    /// Where tapping a link row goes: the link's web address. Nil for any other kind, or an address that isn't http(s).
    var linkDestination: URL? {
        guard kind == .link, let url = URL(string: url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }
}
