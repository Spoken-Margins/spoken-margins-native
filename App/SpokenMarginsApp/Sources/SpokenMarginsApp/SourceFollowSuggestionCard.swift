import SwiftUI
import SessionKit

/// Follow is offered on the Item screen only, not while listening (#280).
struct SourceFollowSuggestionCard: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        if !model.sourceFollowSuggestionCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Keep up with this source?", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Text("Following only adds future entries to your source inbox. Nothing is imported, downloaded, or prepared automatically.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                ForEach(model.sourceFollowSuggestionCandidates) { candidate in
                    Button {
                        model.acceptSourceFollowSuggestion(candidate)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Follow \(candidate.displayName)")
                            if model.sourceFollowSuggestionCandidates.filter({ $0.source.title == candidate.source.title }).count > 1 {
                                Text(candidate.source.canonicalURL).font(.caption).lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("source.followSuggestion.accept.\(candidate.id)")
                }
                // Own colours, not the system blue and red: those are 1.9:1 and 1.7:1 on this card in light mode (#3732).
                HStack {
                    Button(action: model.deferSourceFollowSuggestion) {
                        Text("Not now").foregroundStyle(AppColors.evergreen)
                    }
                    .accessibilityIdentifier("source.followSuggestion.notNow")
                    Button(role: .destructive, action: model.rejectSourceFollowSuggestion) {
                        Text("Don't suggest").foregroundStyle(AppColors.dangerText)
                    }
                    .accessibilityIdentifier("source.followSuggestion.never")
                }
                .font(.caption)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(AppColors.text)
            // A panel, not the dark `watchControl` tint: this card sits on bone in light mode (#3732).
            .background(AppColors.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.border, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("source.followSuggestion.card")
        }
    }
}
