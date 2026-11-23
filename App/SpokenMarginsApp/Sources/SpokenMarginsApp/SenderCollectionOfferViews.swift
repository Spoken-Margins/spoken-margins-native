import SwiftUI
import SessionKit

/// "Keep Sam’s readings together" on the item screen, under the friend's intro box (#5033). Two plain buttons, the arrival
/// screen's own pair: filled for Make a Collection, bordered for Not now. The words carry the meaning; no colour does.
struct SenderCollectionOfferRow: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject var presenter: SenderCollectionOfferPresenter

    private typealias Words = SenderCollectionOfferPresentation.Words

    var body: some View {
        if let offer = presenter.offer {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(offer.title)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                    Text(offer.detail)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true) // the container's label says both lines once
                HStack(spacing: 10) {
                    Button { presenter.isSheetPresented = true } label: {
                        Text(Words.makeButton)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .filledActionButton()
                    .disabled(presenter.isWorking)
                    .accessibilityIdentifier("item.senderCollection.make")
                    Button { presenter.notNow(model: model) } label: {
                        Text(Words.notNowButton)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.evergreen)
                    .disabled(presenter.isWorking)
                    .accessibilityIdentifier("item.senderCollection.notNow")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(offer.accessibilityLabel)
            .accessibilityIdentifier("item.senderCollection.row")
            .trackedSheet(isPresented: $presenter.isSheetPresented) {
                SenderCollectionSheet(presenter: presenter, offer: offer)
                    .environmentObject(model)
            }
        }
    }
}

/// "New Collection": a name field that starts as "From Sam", the line "2 items from Sam", and Create (#5033). The name checks
/// and their words are the Add to Collection sheet's (`ItemCollectionEditing`), so the two never differ.
struct SenderCollectionSheet: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var presenter: SenderCollectionOfferPresenter
    let offer: SenderCollectionOfferPresenter.Offer

    @State private var name: String
    @State private var problem: String?

    private typealias Words = SenderCollectionOfferPresentation.Words

    init(presenter: SenderCollectionOfferPresenter, offer: SenderCollectionOfferPresenter.Offer) {
        self.presenter = presenter
        self.offer = offer
        _name = State(initialValue: offer.defaultCollectionName)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AppTextField(Words.namePlaceholder, text: $name)
                        .submitLabel(.done)
                        .onSubmit(create)
                        .accessibilityIdentifier("item.senderCollection.name")
                    Text(offer.sheetLine)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("item.senderCollection.count")
                    if let problem {
                        Text(problem)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("item.senderCollection.problem")
                    }
                }
                Section {
                    Button(Words.createButton, systemImage: "plus.circle", action: create)
                        .disabled(ItemCollectionEditing.normalizedName(name) == nil || presenter.isWorking)
                        .accessibilityIdentifier("item.senderCollection.create")
                }
            }
            .onChange(of: name) { problem = nil } // a refusal is about the name tried, so it goes when the name changes (#4638)
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle(Words.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .accessibilityIdentifier("item.senderCollection.sheet")
    }

    private func create() {
        guard !presenter.isWorking else { return } // a second tap during the save is not a refusal
        let tried = name
        Task {
            let refusal = await presenter.create(named: tried, model: model)
            guard let refusal else { return }
            // The field stays editable during the save: a refusal of a name since edited is about a name no longer there.
            guard tried == name else { return }
            problem = refusal
            announceToVoiceOver(refusal)
        }
    }
}
