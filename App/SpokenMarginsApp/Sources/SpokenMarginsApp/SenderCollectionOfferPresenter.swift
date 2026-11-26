import SwiftUI
import SessionKit

/// The item screen's hold on the sender collection offer (#5033). The screen creates it with the view and it goes with the
/// view; it is never in `Gate1AppModel`. The rules and the words are `SenderCollectionOffer` and
/// `SenderCollectionOfferPresentation` (SessionKit, host-tested); this reads the facts the screen already holds (the
/// Library rows, the collections and the open item's layers, all in memory), runs the taps, and lets the view redraw.
@MainActor
final class SenderCollectionOfferPresenter: ObservableObject {
    typealias Offer = SenderCollectionOfferPresentation.Offer

    /// The row to show, or nil.
    @Published private(set) var offer: Offer?
    @Published var isSheetPresented = false
    /// True while a save runs, so a double tap on Make a Collection or Create makes one collection (`burst`).
    @Published private(set) var isWorking = false

    private let keeper: SenderCollectionOfferKeeper
    /// Items a silent join is already adding, so the screen redrawing during the save does not add twice.
    private var joining: Set<String> = []

    init(keeper: SenderCollectionOfferKeeper = SenderCollectionOfferKeeper()) {
        self.keeper = keeper
    }

    /// Decides again from what the model holds. `arriving` is true while the friend's arrival screen shows: only then does
    /// a later packet join its sender's collection by itself, so an item the listener took out of the collection by hand
    /// is not put back when they open it later.
    func refresh(model: Gate1AppModel, arriving: Bool) {
        let itemId = model.selectedItem.id
        let rows = model.libraryItems
        // Before the Library's first read there are no rows and no collections: deciding then would read every recorded
        // collection as deleted.
        guard rows.contains(where: { $0.id == itemId }) else { setOffer(nil); return }
        let collections = model.libraryCollections.collections
        let result = SenderCollectionOfferPresentation.decide(
            openItemId: itemId,
            layers: model.friendItemFacts.layers,
            rows: rows,
            collections: collections,
            record: keeper.record(reconciledWith: collections),
            isHidden: { model.hiddenSenders.isHidden($0) })
        switch result {
        case .none:
            setOffer(nil)
        case .offer(let next):
            setOffer(next)
        case .join(_, let collectionId, let itemId):
            setOffer(nil)
            if arriving { join(itemId: itemId, collectionId: collectionId, model: model) }
        }
    }

    /// Not now: final for this sender.
    func notNow(model: Gate1AppModel) {
        guard let offer, !isWorking else { return }
        keeper.declined(offer.senderId)
        setOffer(nil)
    }

    /// Create on the New Collection sheet. Returns the refusal to show under the name field (empty or taken name, or a
    /// failed save), or nil once the collection is made and the sheet can close.
    func create(named name: String, model: Gate1AppModel) async -> String? {
        guard let offer, !isWorking else { return nil }
        guard let store = model.store else { return ItemCollectionEditing.Wording.saveFailed }
        isWorking = true
        defer { isWorking = false }
        let made = await model.libraryCollections.createCollection(name: name, itemIDs: offer.itemIds, store: store)
        switch made.outcome {
        case .saved:
            guard let collection = made.collection else { return ItemCollectionEditing.Wording.saveFailed }
            keeper.linked(offer.senderId, toCollection: collection.id)
            model.collectionsChanged()
            model.reportConfirmation(SenderCollectionOfferPresentation.Words.banner(collectionName: collection.name))
            isSheetPresented = false
            setOffer(nil)
            return nil
        case .needsName:
            return ItemCollectionEditing.Wording.nameRequired
        case .nameTaken:
            return ItemCollectionEditing.Wording.nameTaken
        case .failed(let error):
            model.reportFailure(error, context: "Collection change failed")
            return ItemCollectionEditing.Wording.saveFailed
        }
    }

    private func join(itemId: String, collectionId: String, model: Gate1AppModel) {
        guard let store = model.store, joining.insert(itemId).inserted else { return }
        let name = model.libraryCollections.collections.first { $0.id == collectionId }?.name
        Task { [weak self, weak model] in
            defer { self?.joining.remove(itemId) }
            guard let model else { return }
            guard case .success(let added) = await model.libraryCollections.add([itemId], toCollectionID: collectionId, store: store) else { return }
            model.collectionsChanged()
            if added > 0, let name { model.reportConfirmation(SenderCollectionOfferPresentation.Words.banner(collectionName: name)) }
        }
    }

    private func setOffer(_ next: Offer?) {
        if offer != next { offer = next }
    }
}
