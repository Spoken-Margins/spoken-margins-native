import SessionKit
import SwiftUI

/// "Keep Sam's readings together" on the item screen (#5033). The rules are `SenderCollectionOffer` in SessionKit; this
/// keeps the listener's choices (`SenderCollectionOfferRecord`), makes the collection, and adds a later item from the
/// same sender to it. Kept out of `Gate1AppModel`: the item screen owns one.
@MainActor
final class SenderCollectionOfferPresenter: ObservableObject {
    @Published private(set) var record: SenderCollectionOfferRecord
    /// The offer whose New Collection sheet is open.
    @Published var sheetOffer: SenderCollectionOffer.Offer?
    /// Why Create was refused (empty or taken name, a failed save), under the name field.
    @Published var nameProblem: String?
    /// True while Create saves, so a second tap makes no second collection.
    @Published private(set) var isCreating = false
    /// Joins under way, so a redraw while one saves doesn't start it twice.
    private var joining = Set<String>()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        record = SenderCollectionOfferRecord.load(from: defaults)
    }

    /// What the open item's screen shows or does, from the Library's rows (items in Recently Deleted are not among them).
    func decision(itemID: String, model: Gate1AppModel) -> SenderCollectionOffer.Decision {
        // Most items carry no friend's Margins: answer those from their own row, without reading the whole Library.
        guard !itemID.isEmpty,
              let row = model.libraryItems.first(where: { $0.id == itemID }),
              row.sharedMargins.senders.contains(where: { SenderCollectionOffer.senderID(of: $0) != nil })
        else { return .none }
        return SenderCollectionOffer.decide(
            itemID: itemID,
            items: model.libraryItems.map(SenderCollectionOffer.ItemSenders.init),
            collections: model.libraryCollections.collections,
            record: record,
            hidden: model.hiddenSenders.current)
    }

    /// Not now: this sender is never offered again.
    func decline(_ offer: SenderCollectionOffer.Offer) {
        record.recordDeclined(for: offer.senderID)
        record.save(to: defaults)
    }

    func openSheet(for offer: SenderCollectionOffer.Offer) {
        nameProblem = nil
        sheetOffer = offer
    }

    /// Create: a collection holding every item from the sender, linked to the sender so later items join it. Returns
    /// true once it is made.
    func create(name: String, offer: SenderCollectionOffer.Offer, model: Gate1AppModel) async -> Bool {
        guard !isCreating else { return false }
        guard let store = model.store else {
            nameProblem = ItemCollectionEditing.Wording.saveFailed
            return false
        }
        isCreating = true
        defer { isCreating = false }
        let id = "collection-\(UUID().uuidString)"
        switch await model.libraryCollections.create(name: name, itemIDs: offer.itemIDs, store: store, id: id) {
        case .saved:
            record.recordCollection(id, for: offer.senderID)
            record.recordPlaced(offer.itemIDs)
            record.save(to: defaults)
            model.collectionsChanged()
            let saved = model.libraryCollections.collections.first { $0.id == id }?.name
                ?? ItemCollectionEditing.normalizedName(name) ?? name
            model.reportConfirmation(SenderCollectionOffer.addedBanner(collectionName: saved))
            return true
        case .needsName:
            nameProblem = ItemCollectionEditing.Wording.nameRequired
        case .nameTaken:
            nameProblem = ItemCollectionEditing.Wording.nameTaken
        case .failed(let error):
            model.reportFailure(error, context: "Collection change failed")
            nameProblem = ItemCollectionEditing.Wording.saveFailed
        }
        return false
    }

    /// A later item from a sender whose collection the listener made here joins it, with a banner and no question.
    func join(_ join: SenderCollectionOffer.Join, model: Gate1AppModel) async {
        let key = join.collectionID + "\u{1F}" + join.itemID
        guard let store = model.store, joining.insert(key).inserted else { return }
        defer { joining.remove(key) }
        switch await model.libraryCollections.add([join.itemID], toCollectionID: join.collectionID, store: store) {
        case .success(let added):
            record.recordPlaced([join.itemID])
            record.save(to: defaults)
            model.collectionsChanged()
            // Zero when the collection was deleted meanwhile, or the item was already in it: nothing to say.
            if added > 0 { model.reportConfirmation(join.banner) }
        case .failure(let error):
            model.reportFailure(error, context: "Collection change failed")
        }
    }
}

/// The offer row under the friend's intro on the item screen.
struct SenderCollectionOfferRow: View {
    let offer: SenderCollectionOffer.Offer
    let makeCollection: () -> Void
    let notNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(offer.title, systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.text)
                Text(offer.detail)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(offer.accessibilityLabel)
            // Side by side when they fit, stacked at the largest text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { buttons }
                VStack(alignment: .leading, spacing: 10) { buttons }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item.senderCollectionOffer")
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: makeCollection) {
            Text("Make a Collection")
                .fontWeight(.semibold)
                .frame(minHeight: 44)
        }
        .filledActionButton()
        .accessibilityIdentifier("item.senderCollectionOffer.make")
        Button(action: notNow) {
            Text("Not now")
                .fontWeight(.semibold)
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(AppColors.evergreen)
        .accessibilityIdentifier("item.senderCollectionOffer.notNow")
    }
}

/// "New Collection" from the offer: a name, prefilled "From Sam", and Create. The items are the sender's, so there is no
/// checklist.
struct SenderCollectionOfferSheet: View {
    let offer: SenderCollectionOffer.Offer
    @ObservedObject var presenter: SenderCollectionOfferPresenter
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(offer: SenderCollectionOffer.Offer, presenter: SenderCollectionOfferPresenter) {
        self.offer = offer
        self.presenter = presenter
        _name = State(initialValue: offer.defaultCollectionName)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    AppTextField("Name, such as HIST 210", text: $name)
                        .submitLabel(.done)
                        .onSubmit(create)
                        .accessibilityIdentifier("senderCollection.name.field")
                    if let problem = presenter.nameProblem {
                        Text(problem)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("senderCollection.name.problem")
                    }
                } footer: {
                    Text(offer.countLine)
                }
                Section {
                    Button("Create", systemImage: "plus.circle", action: create)
                        .disabled(ItemCollectionEditing.normalizedName(name) == nil || presenter.isCreating)
                        .accessibilityIdentifier("senderCollection.create.button")
                }
            }
            .onChange(of: name) { presenter.nameProblem = nil }
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("senderCollection.cancel.button")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("senderCollection.sheet")
    }

    private func create() {
        guard ItemCollectionEditing.normalizedName(name) != nil, !presenter.isCreating else { return }
        Task {
            if await presenter.create(name: name, offer: offer, model: model) { dismiss() }
        }
    }
}
