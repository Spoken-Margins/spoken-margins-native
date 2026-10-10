import Foundation

struct TrashUndoState: Identifiable, Equatable {
    let id = UUID()
    let itemId: String
    let title: String
}
