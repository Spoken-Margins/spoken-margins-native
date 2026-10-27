import Foundation
import SessionKit

enum BatchSessionExportFilter: String, CaseIterable, Identifiable {
    case withInterjections = "with_interjections"
    case all = "all"

    var id: String { rawValue }
}
