import Foundation

extension Gate1AppModel {
    /// The app's Application Support folder, made if it is missing.
    func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }
}
