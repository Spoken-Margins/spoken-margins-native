import Foundation
import SessionKit

extension Gate5BrowserTextHandoffStore {
    #if SPOKEN_MARGINS_LEGACY
    static let appGroupIdentifier = "group.com.spokenmargins.native.legacy"
    #else
    static let appGroupIdentifier = "group.com.spokenmargins.native"
    #endif

    static func appGroup(fileManager: FileManager = .default) throws -> Gate5BrowserTextHandoffStore {
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw Gate5BrowserTextHandoffStoreError.appGroupUnavailable(appGroupIdentifier)
        }
        return Gate5BrowserTextHandoffStore(baseDirectory: containerURL, fileManager: fileManager)
    }
}
