#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation
import SessionKit

/// A Library item a shortcut can name (#1073): what the Add Margin action's Item parameter picks from.
struct LibraryItemEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Library Item")
    static var defaultQuery: LibraryItemEntityQuery { LibraryItemEntityQuery() }

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(_ choice: StoredSessionMargin.ItemChoice) {
        self.init(id: choice.id, title: choice.title)
    }
}

/// The picker offers items the listener has started, most recently listened first, since only those can take a
/// Margin. A shortcut that already names an item keeps finding it, started or not, so running it says to start
/// the item rather than quietly forgetting the choice.
struct LibraryItemEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [LibraryItemEntity] {
        guard let model = ListeningEditionShortcutBridge.model else { return [] }
        let wanted = Set(identifiers)
        return await model.shortcutItemChoices(startedOnly: false).filter { wanted.contains($0.id) }.map { LibraryItemEntity($0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [LibraryItemEntity] {
        guard let model = ListeningEditionShortcutBridge.model else { return [] }
        return await model.shortcutItemChoices(startedOnly: true).prefix(25).map { LibraryItemEntity($0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [LibraryItemEntity] {
        guard let model = ListeningEditionShortcutBridge.model else { return [] }
        return await model.shortcutItemChoices(startedOnly: true, matching: string).prefix(25).map { LibraryItemEntity($0) }
    }
}
#endif
