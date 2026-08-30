import SwiftUI
import SessionKit

struct ExperienceCanonicalNavigationTree: View {
    let nodes: [CanonicalNavigationNode]
    let chapters: [Chapter]
    let action: (Chapter) -> Void
    var depth = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(nodes) { node in
                VStack(alignment: .leading, spacing: 8) {
                    if let chapter = chapters.first(where: { $0.id == node.id }), node.children.isEmpty {
                        Button {
                            action(chapter)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(AppColors.evergreen)
                                Text(node.title)
                                    .foregroundStyle(AppColors.text)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Text("\(chapter.percent)%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("chapter.jump.\(chapter.id)")
                    } else {
                        Label(node.title, systemImage: depth == 0 ? "books.vertical" : "folder")
                            .font(depth == 0 ? .headline : .subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    if !node.children.isEmpty {
                        ExperienceCanonicalNavigationTree(
                            nodes: node.children,
                            chapters: chapters,
                            action: action,
                            depth: depth + 1
                        )
                        .padding(.leading, 20)
                    }
                }
            }
        }
    }
}

