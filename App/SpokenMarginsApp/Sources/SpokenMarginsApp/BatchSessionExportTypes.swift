import Foundation
import SessionKit

enum BatchSessionExportFilter: String, CaseIterable, Identifiable {
    case withInterjections = "with_interjections"
    case all = "all"

    var id: String { rawValue }
}

struct BatchSessionExportRow: Identifiable {
    let session: Session
    let itemTitle: String
    let interjectionCount: Int

    var id: String { session.id }
}
