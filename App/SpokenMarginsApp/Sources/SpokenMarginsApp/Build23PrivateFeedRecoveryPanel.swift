import SwiftUI

/// Shown in place of the generic "add the source" text when a shared podcast Margin came from a
/// private feed (#454): the sender's links were left out of the package, so the listener pastes
/// their own feed link and the app finds the episode in it.
struct Build23PrivateFeedRecoveryPanel: View {
    @ObservedObject var recovery: SharedEpisodeRecovery
    let episodeTitle: String
    let recover: (String) -> Void
    let choose: (String) -> Void
    @State private var feedLink = ""

    static let explanation = "These Margins came from a private podcast feed, so the sender's link is not in the package. If you subscribe to the show, paste your own feed link and Spoken Margins will find this episode in it."
    static let privacyNote = "Your link stays on this iPhone. It is never added to a package or shared."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.explanation)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Your feed link", text: $feedLink)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .accessibilityIdentifier("build23.recipient.privateFeed.field")

            Text(Self.privacyNote)
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                recover(feedLink)
            } label: {
                Label("Find This Episode", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .filledActionButton()
            .disabled(feedLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recovery.phase == .checking)
            .accessibilityIdentifier("build23.recipient.privateFeed.find")

            status
        }
    }

    @ViewBuilder
    private var status: some View {
        switch recovery.phase {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView("Looking through your feed…")
        case .noMatch:
            Text("No episode in that feed matches “\(episodeTitle)”. Check that it is the feed for the same show, then try again.")
                .font(.subheadline)
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("build23.recipient.privateFeed.noMatch")
        case .choose(let candidates):
            VStack(alignment: .leading, spacing: 8) {
                Text("More than one episode could be the one you were sent. Pick it:")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.text)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(candidates) { candidate in
                    Button {
                        choose(candidate.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title)
                                .font(.subheadline.weight(.semibold))
                            if !candidate.detail.isEmpty {
                                Text(candidate.detail)
                                    .font(.caption)
                                    .foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("build23.recipient.privateFeed.candidate.\(candidate.id)")
                }
            }
        case .added:
            Text("That episode is in your Library, but it does not match this package. Add the matching episode another way, or cancel the import.")
                .font(.subheadline)
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            FailureMessageLabel(message)
                .font(.subheadline)
        }
    }
}
