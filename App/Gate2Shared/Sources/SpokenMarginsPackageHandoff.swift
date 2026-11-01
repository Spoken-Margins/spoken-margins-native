import Foundation

public enum SpokenMarginsPackageHandoffStoreError: Error, Equatable, LocalizedError {
    case appGroupUnavailable(String)
    case invalidPackage(String)
    case missingPackage(String)

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            return "App Group unavailable: \(identifier)"
        case .invalidPackage(let message):
            return "Invalid Spoken Margins package: \(message)"
        case .missingPackage(let id):
            return "Missing Spoken Margins package: \(id)"
        }
    }
}

/// Moves a package received by the Share extension into an app-group inbox.
/// The main app copies the exact bytes into its verified import staging area
/// before deleting the inbox entry.
/// Holds a folder URL and `FileManager.default`, which is safe to use from any thread; the app lists and deletes
/// inbox files off the main actor (#2510).
public struct SpokenMarginsPackageHandoffStore: @unchecked Sendable {
    #if SPOKEN_MARGINS_LEGACY
    public static let appGroupIdentifier = "group.com.spokenmargins.native.legacy"
    #else
    public static let appGroupIdentifier = "group.com.spokenmargins.native"
    #endif

    public static let uniformTypeIdentifier = "com.spokenmargins.package"
    public static let fileExtension = "spokenmargins"

    private static let packageDirectoryName = "SpokenMarginsPackageHandoffs"
    private static let maximumPackageBytes: Int64 = 100 * 1_024 * 1_024
    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public static func appGroup(fileManager: FileManager = .default) throws -> SpokenMarginsPackageHandoffStore {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw SpokenMarginsPackageHandoffStoreError.appGroupUnavailable(appGroupIdentifier)
        }
        return SpokenMarginsPackageHandoffStore(baseDirectory: containerURL, fileManager: fileManager)
    }

    @discardableResult
    public func savePackage(from sourceURL: URL, suggestedFilename: String? = nil) throws -> String {
        let suggestedExtension = ((suggestedFilename ?? "") as NSString).pathExtension.lowercased()
        guard sourceURL.pathExtension.lowercased() == Self.fileExtension
                || suggestedExtension == Self.fileExtension else {
            throw SpokenMarginsPackageHandoffStoreError.invalidPackage("the file extension is not .spokenmargins")
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw SpokenMarginsPackageHandoffStoreError.invalidPackage("the shared item is not a regular file")
        }
        if let fileSize = values.fileSize, Int64(fileSize) > Self.maximumPackageBytes {
            throw SpokenMarginsPackageHandoffStoreError.invalidPackage("the file is larger than 100 MB")
        }

        let id = UUID().uuidString.lowercased()
        let directory = packageDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uncheckedPackageURL(payloadID: id)
        let staged = directory.appendingPathComponent(".\(id).staged")
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: sourceURL, to: staged)
        try fileManager.moveItem(at: staged, to: destination)
        return id
    }

    public func packageURL(payloadID: String) throws -> URL {
        let id = try validatedPayloadID(payloadID)
        let url = uncheckedPackageURL(payloadID: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SpokenMarginsPackageHandoffStoreError.missingPackage(id)
        }
        return url
    }

    public func pendingPayloadIDs() throws -> [String] {
        let directory = packageDirectory()
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension.lowercased() == Self.fileExtension }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if lhsDate == rhsDate { return lhs.lastPathComponent < rhs.lastPathComponent }
                return lhsDate < rhsDate
            }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    public func deletePackage(payloadID: String) throws {
        let id = try validatedPayloadID(payloadID)
        let url = uncheckedPackageURL(payloadID: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func packageDirectory() -> URL {
        baseDirectory.appendingPathComponent(Self.packageDirectoryName, isDirectory: true)
    }

    private func uncheckedPackageURL(payloadID: String) -> URL {
        packageDirectory()
            .appendingPathComponent(payloadID)
            .appendingPathExtension(Self.fileExtension)
    }

    private func validatedPayloadID(_ payloadID: String) throws -> String {
        let id = payloadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              id.range(of: #"^[a-zA-Z0-9-]+$"#, options: .regularExpression) != nil else {
            throw SpokenMarginsPackageHandoffStoreError.invalidPackage("payload id is invalid")
        }
        return id
    }
}
