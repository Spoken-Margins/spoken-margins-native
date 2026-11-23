import SessionKit
import SwiftUI

/// The cards above Following's rows (#4046): the change card for lists whose address changed (PR 7b), then the strongest
/// rule suggestion (PR 12). At most two, change card first. Following draws this only when `hasCards` says one is due, so
/// an empty row never shows. The words are SessionKit's (`ListChangeCard`, `ListLinkWords`, `RuleSuggestionWords`).
struct FollowingListCards: View {
    let model: Gate1AppModel
    let subscriptions: [FeedSubscription]

    @ObservedObject private var linksState = ListLinksState.shared
    @ObservedObject private var listsState = FollowListsState.shared
    @ObservedObject private var suggestionsState = RuleSuggestionsState.shared
    /// The link whose "Changes to <list>" sheet is open.
    @State private var reviewing: ListLink?
    /// The links already opened in this round of **Review**, so the next one opens after each sheet closes.
    @State private var reviewed: Set<String> = []
    @State private var refusal: ListeningRuleScreens.Refusal?
    @State private var isTurningOn = false

    /// Whether Following should draw the cards at all.
    @MainActor
    static var hasCards: Bool {
        ListChangeCard.text(links: ListLinksState.shared.links, lists: FollowListsState.shared.lists) != nil
            || !RuleSuggestionsState.shared.suggestions.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = ListChangeCard.text(links: linksState.links, lists: listsState.lists) {
                changeCard(text)
            }
            if let suggestion = suggestionsState.suggestions.first {
                RuleSuggestionCard(suggestion: suggestion, isBusy: isTurningOn) {
                    turnOn(suggestion)
                } notNow: {
                    Task { await model.putOffSuggestion(suggestion) }
                } never: {
                    Task { await model.refuseSuggestion(suggestion) }
                }
            }
        }
        .trackedSheet(item: $reviewing, onDismiss: reviewNext) { link in
            ListChangesSheet(
                model: model, link: link, listName: listsState.lists.first { $0.id == link.listId }?.name ?? link.title,
                subscriptions: subscriptions)
        }
        .alert(refusal?.title ?? "", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal?.message ?? "")
        }
    }

    private func changeCard(_ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(ListLinkWords.review) {
                reviewed = []
                reviewNext()
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("following.listChange.review")
        }
        .padding(12)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(AppColors.border) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("following.listChange.card")
    }

    /// Opens the next list with a change, in the chips' order, skipping those already opened this round.
    private func reviewNext() {
        let next = ListChangeCard.waiting(links: linksState.links, lists: listsState.lists).first { !reviewed.contains($0.id) }
        guard let next else { return }
        reviewed.insert(next.id)
        reviewing = next
    }

    private func turnOn(_ suggestion: RuleSuggestion) {
        guard !isTurningOn else { return }
        isTurningOn = true
        Task {
            let change = await model.turnOnSuggestion(suggestion)
            if let refused = change?.refusal { refusal = refused }
            if change?.isFull == true { refusal = ListeningRuleScreens.fullRefusal }
            isTurningOn = false
        }
    }
}

/// One suggested rule (#4046 PR 12), on Following and in the Rules screen's Suggested section: the eyebrow, the question,
/// why it is offered, **Turn on**, **Not now**, and **Don’t suggest this** in the `…` menu.
struct RuleSuggestionCard: View {
    let suggestion: RuleSuggestion
    var isBusy = false
    let turnOn: () -> Void
    let notNow: () -> Void
    let never: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(RuleSuggestionWords.eyebrow)
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(AppColors.secondaryText)
                Spacer()
                Menu {
                    Button(RuleSuggestionWords.never, systemImage: "hand.raised", action: never)
                } label: {
                    Image(systemName: "ellipsis").minimumTapTarget()
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("ruleSuggestion.menu")
            }
            Text(RuleSuggestionWords.title(suggestion))
                .font(.headline)
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(suggestion.reasonLine)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
            HStack(spacing: 12) {
                Button(action: turnOn) {
                    Text(RuleSuggestionWords.turnOn).frame(minHeight: 36)
                }
                .filledActionButton()
                .disabled(isBusy)
                .accessibilityIdentifier("ruleSuggestion.turnOn")
                Button(action: notNow) {
                    Text(RuleSuggestionWords.notNow).frame(minHeight: 36)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("ruleSuggestion.notNow")
            }
        }
        .padding(12)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(AppColors.border) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ruleSuggestion.card.\(suggestion.key)")
    }
}
