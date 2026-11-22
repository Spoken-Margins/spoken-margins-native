import SwiftUI
import SessionKit

/// "Follow <show>?" at the end of the item a friend's file or link opened on a first launch (#4672, rule 5). The
/// decision of when it shows is `FirstLaunchArrival`; this view only draws it. It looks like `SourceFollowSuggestionCard`
/// but has no "Don't suggest": it shows once.
///
/// The card latches once it has appeared, so following (which makes the show no longer followable) turns it into
/// "Following <show>" instead of making it vanish under the listener's finger.
struct ArrivalFollowCard: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var candidate: SourceCandidateEvidence?
    @State private var tappedFollow = false
    @State private var dismissed = false

    private var isFollowed: Bool {
        tappedFollow && !model.isFollowingSelectedSource && !model.canManuallyFollowSelectedSource
    }

    var body: some View {
        Group {
            if let candidate, !dismissed {
                card(for: candidate.displayName)
            }
        }
        // Re-asked when the listener's item changes and when discovery lands, never once the card is up.
        .task(id: "\(model.snapshot.itemId ?? "")|\(model.canManuallyFollowSelectedSource)") {
            // The offer is spent inside `arrivalFollowCandidateToOffer`, with no await after its last check.
            guard candidate == nil, let found = await model.arrivalFollowCandidateToOffer() else { return }
            candidate = found
        }
        .onChange(of: model.snapshot.itemId) {
            candidate = nil
            tappedFollow = false
            dismissed = false
        }
    }

    private func card(for name: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Follow \(name)?", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("New episodes show up in Following.")
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if isFollowed {
                // A tick and words, never a colour change alone.
                Label("Following \(name)", systemImage: "checkmark")
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("arrival.followCard.following")
            } else {
                // Stacked, not side by side: at the largest text sizes both labels wrap and stay whole.
                Button {
                    tappedFollow = true
                    model.followSelectedSource()
                } label: {
                    Text("Follow \(name)").fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isFollowingSelectedSource)
                .accessibilityIdentifier("arrival.followCard.follow")
                Button {
                    model.declineArrivalFollow()
                    dismissed = true
                } label: {
                    Text("Not now")
                        .foregroundStyle(AppColors.evergreen)
                        .fixedSize(horizontal: false, vertical: true)
                        .minimumTapTarget()
                }
                .accessibilityIdentifier("arrival.followCard.notNow")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(AppColors.text)
        .background(AppColors.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isFollowed ? "Following \(name)" : "Follow \(name)? New episodes show up in Following.")
        .accessibilityIdentifier("arrival.followCard")
    }
}
