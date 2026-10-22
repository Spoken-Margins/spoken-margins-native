import Foundation
import SessionKit

extension ListeningEditionBatch.Entry {
    /// Reads one picked file into an entry, decoded or with the reason it could not be. Used by the Listening
    /// Edition screen in Settings and by the Add sheet's Files route (#2373), so both refuse the same files.
    static func reading(url: URL, id: Int) -> ListeningEditionBatch.Entry {
        let name = url.lastPathComponent
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8_000_000 else {
                return ListeningEditionBatch.Entry(id: id, name: name, error: "Listening edition exceeds 8 MB.")
            }
            return ListeningEditionBatch.Entry(id: id, name: name, data: try Data(contentsOf: url))
        } catch {
            return ListeningEditionBatch.Entry(id: id, name: name, error: error.localizedDescription)
        }
    }
}
