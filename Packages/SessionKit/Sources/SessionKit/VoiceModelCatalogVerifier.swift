#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// Proves a voice catalog is ours and current before anything in it is trusted (#1816). The catalog
// decides which code-adjacent files (ONNX models) the app installs, so it is signed, unlike the
// onboarding catalog. Every check fails closed: a catalog that can't be proven is rejected whole,
// and an entry that breaks a rule is left out while the rest are kept.
//
// The envelope (Contracts/schemas/voice-model-catalog-envelope.schema.json) carries the catalog as
// base64 bytes, so the signature covers exactly the bytes that are decoded, with no re-serialising
// to disagree about. The signature is Ed25519 over `signingContext` followed by those bytes.

public struct VoiceModelCatalogEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "voice-model-catalog-envelope.v1"
    public static let ed25519 = "ed25519"

    public var schemaVersion: String
    public var keyId: String
    public var algorithm: String
    /// Base64 of the catalog JSON.
    public var payload: String
    /// Base64 of the 64-byte Ed25519 signature.
    public var signature: String

    public init(keyId: String, payload: String, signature: String, schemaVersion: String = VoiceModelCatalogEnvelope.currentSchemaVersion, algorithm: String = VoiceModelCatalogEnvelope.ed25519) {
        self.schemaVersion = schemaVersion
        self.keyId = keyId
        self.algorithm = algorithm
        self.payload = payload
        self.signature = signature
    }
}

/// A public key the app trusts to sign catalogs. Builds ship a short list so a key can be rotated:
/// add the new key in one build, sign with it once that build is out, drop the old key in a later one.
public struct VoiceCatalogTrustedKey: Equatable, Sendable {
    public var keyId: String
    /// The 32-byte Ed25519 public key.
    public var publicKey: Data

    public init(keyId: String, publicKey: Data) {
        self.keyId = keyId
        self.publicKey = publicKey
    }
}

public enum VoiceCatalogTrust {
    /// The keys compiled into this build. Empty until the owner generates the production signing key
    /// (a secret that stays on their machine); while it is empty every catalog fails with `unknownKey`
    /// and the app offers no downloads, which is the safe state.
    public static let production: [VoiceCatalogTrustedKey] = []
}

public enum VoiceCatalogError: Error, Equatable, Sendable {
    case oversized
    case malformedEnvelope
    case unsupportedEnvelopeVersion(String)
    case unsupportedAlgorithm(String)
    /// The envelope names a key this build doesn't trust.
    case unknownKey(String)
    case badSignature
    case malformedPayload
    case unsupportedSchemaVersion(String)
    case invalidCatalogVersion
    case invalidIssuedAt
    /// `offered` is lower than the `lastAccepted` catalog: an old catalog replayed.
    case rollback(lastAccepted: Int, offered: Int)
    case duplicateVoiceID(String)
}

/// A catalog that passed every check. `voices` holds the entries that broke no rule, including
/// withdrawn and superseded ones, so the installer can tell the listener; `rejected` holds the rest.
public struct VerifiedVoiceModelCatalog: Equatable, Sendable {
    public var catalogVersion: Int
    public var issuedAt: String
    /// The trusted key that signed it.
    public var keyId: String
    public var voices: [VoiceModelEntry]
    public var rejected: [RejectedVoiceEntry]

    /// The voices the app may offer for download now.
    public var available: [VoiceModelEntry] {
        voices.filter { $0.status == .available }
    }

    public func voice(id: String) -> VoiceModelEntry? {
        voices.first { $0.id == id }
    }
}

public enum VoiceModelCatalogVerifier {
    /// The bytes a signature covers are this prefix followed by the payload bytes, so a signature
    /// made for a voice catalog can't be replayed as a signature over anything else the key signs.
    public static let signingContext = Data("SpokenMargins-VoiceModelCatalog-v1\n".utf8)

    /// A catalog is a few kilobytes; anything near this is not one.
    public static let maximumEnvelopeBytes = 1_048_576

    /// The runtimes this build can run. A voice for any other runtime is left out.
    public static let supportedRuntimes: Set<String> = ["onnxruntime"]

    /// Verifies a downloaded or cached envelope.
    ///
    /// - Parameters:
    ///   - lastAcceptedCatalogVersion: the highest `catalogVersion` the app has accepted before, if any.
    ///     A lower one is a rollback and is rejected; the same version again is fine (a refresh).
    public static func verify(
        envelopeData: Data,
        trustedKeys: [VoiceCatalogTrustedKey],
        lastAcceptedCatalogVersion: Int? = nil,
        supportedRuntimes: Set<String> = VoiceModelCatalogVerifier.supportedRuntimes
    ) throws -> VerifiedVoiceModelCatalog {
        guard envelopeData.count <= maximumEnvelopeBytes else { throw VoiceCatalogError.oversized }
        guard let envelope = try? JSONDecoder().decode(VoiceModelCatalogEnvelope.self, from: envelopeData) else {
            throw VoiceCatalogError.malformedEnvelope
        }
        guard envelope.schemaVersion == VoiceModelCatalogEnvelope.currentSchemaVersion else {
            throw VoiceCatalogError.unsupportedEnvelopeVersion(envelope.schemaVersion)
        }
        guard envelope.algorithm == VoiceModelCatalogEnvelope.ed25519 else {
            throw VoiceCatalogError.unsupportedAlgorithm(envelope.algorithm)
        }
        guard let key = trustedKeys.first(where: { $0.keyId == envelope.keyId }),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey) else {
            throw VoiceCatalogError.unknownKey(envelope.keyId)
        }
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              signature.count == 64,
              publicKey.isValidSignature(signature, for: signingContext + payload) else {
            throw VoiceCatalogError.badSignature
        }

        // Only now is the payload ours; everything below reads signed bytes.
        guard let catalog = try? VoiceModelCatalog.decode(payload) else { throw VoiceCatalogError.malformedPayload }
        guard catalog.schemaVersion == VoiceModelCatalog.currentSchemaVersion else {
            throw VoiceCatalogError.unsupportedSchemaVersion(catalog.schemaVersion)
        }
        guard catalog.catalogVersion >= 1 else { throw VoiceCatalogError.invalidCatalogVersion }
        guard isRFC3339DateTime(catalog.issuedAt) else { throw VoiceCatalogError.invalidIssuedAt }
        if let last = lastAcceptedCatalogVersion, catalog.catalogVersion < last {
            throw VoiceCatalogError.rollback(lastAccepted: last, offered: catalog.catalogVersion)
        }
        return try screen(catalog, keyId: envelope.keyId, supportedRuntimes: supportedRuntimes)
    }

    /// Applies the entry rules to a decoded catalog. `verify` calls this after the signature checks;
    /// it is public so a draft catalog on disk can be held to the same rules before it is signed.
    public static func screen(
        _ catalog: VoiceModelCatalog,
        keyId: String = "",
        supportedRuntimes: Set<String> = VoiceModelCatalogVerifier.supportedRuntimes
    ) throws -> VerifiedVoiceModelCatalog {
        guard catalog.voices.count + catalog.rejected.count <= VoiceModelCatalogRules.maximumVoices else {
            throw VoiceCatalogError.malformedPayload
        }
        var seen = Set<String>()
        for id in catalog.voices.map(\.id) + catalog.rejected.compactMap(\.id) {
            // A repeated id makes "which one does the signature vouch for" ambiguous: reject the lot.
            guard seen.insert(id).inserted else { throw VoiceCatalogError.duplicateVoiceID(id) }
        }
        var accepted: [VoiceModelEntry] = []
        var rejected = catalog.rejected
        for entry in catalog.voices {
            if let reason = rejection(for: entry, supportedRuntimes: supportedRuntimes) {
                rejected.append(RejectedVoiceEntry(id: entry.id, reason: reason))
            } else {
                accepted.append(entry)
            }
        }
        return VerifiedVoiceModelCatalog(
            catalogVersion: catalog.catalogVersion,
            issuedAt: catalog.issuedAt,
            keyId: keyId,
            voices: accepted,
            rejected: rejected
        )
    }

    /// The first rule `entry` breaks, or nil when it breaks none.
    public static func rejection(for entry: VoiceModelEntry, supportedRuntimes: Set<String> = VoiceModelCatalogVerifier.supportedRuntimes) -> VoiceEntryRejection? {
        guard VoiceModelCatalogRules.isVoiceID(entry.id) else { return .invalidField("id") }
        guard !isBlank(entry.displayName) else { return .invalidField("displayName") }
        guard !isBlank(entry.publisher) else { return .invalidField("publisher") }
        guard !isBlank(entry.version) else { return .invalidField("version") }
        guard !isBlank(entry.runtime.version) else { return .invalidField("runtime.version") }
        guard VoiceModelCatalogRules.isRuntimeName(entry.runtime.name) else { return .invalidField("runtime.name") }
        guard supportedRuntimes.contains(entry.runtime.name) else { return .unknownRuntime(entry.runtime.name) }
        guard VoiceModelCatalogRules.isIOSVersion(entry.minimumIOSVersion) else { return .invalidField("minimumIOSVersion") }
        guard entry.minimumMemoryMegabytes >= 1 else { return .invalidField("minimumMemoryMegabytes") }
        if let successor = entry.supersededBy, !VoiceModelCatalogRules.isVoiceID(successor) {
            return .invalidField("supersededBy")
        }
        if entry.status == .superseded {
            // Pointing at itself would leave the listener nowhere to go.
            guard let successor = entry.supersededBy, successor != entry.id else { return .supersededWithoutSuccessor }
        }
        guard !entry.licenses.isEmpty, entry.licenses.count <= VoiceModelCatalogRules.maximumLicenses else { return .invalidField("licenses") }
        guard entry.files.count <= VoiceModelCatalogRules.maximumFiles else { return .invalidField("files") }
        if !entry.bundled && entry.files.isEmpty { return .noFiles }

        var licenseIDs = Set<String>()
        for license in entry.licenses {
            guard VoiceModelCatalogRules.isVoiceID(license.id), licenseIDs.insert(license.id).inserted else {
                return .invalidField("licenses.id")
            }
            guard !isBlank(license.name) else { return .invalidField("licenses.name") }
            if let spdx = license.spdxId, !VoiceModelCatalogRules.isSPDXId(spdx) { return .invalidField("licenses.spdxId") }
            if let summary = license.restrictionsSummary, summary.count > VoiceModelCatalogRules.maximumSummaryCharacters {
                return .invalidField("licenses.restrictionsSummary")
            }
            guard VoiceModelCatalogRules.isHTTPSURL(license.textURL) else { return .insecureSource(path: "licenses.\(license.id).textURL") }
            guard VoiceModelCatalogRules.isLowercaseSHA256(license.textSHA256) else { return .invalidHash(path: "licenses.\(license.id).textSHA256") }
            if license.requiresAcceptance, isBlank(license.restrictionsSummary ?? "") {
                return .acceptanceWithoutSummary(licenseId: license.id)
            }
        }

        var paths = Set<String>()
        for file in entry.files {
            guard VoiceModelCatalogRules.isRelativeFilePath(file.path) else { return .invalidField("files.path") }
            // Compared case-insensitively: Model.onnx and model.onnx are one file on a default iPhone volume.
            guard paths.insert(file.path.lowercased()).inserted else { return .duplicatePath(file.path) }
            guard file.byteCount >= 1 else { return .invalidField("files.\(file.path).byteCount") }
            guard VoiceModelCatalogRules.isLowercaseSHA256(file.sha256) else { return .invalidHash(path: file.path) }
            guard !file.sources.isEmpty else { return .emptySources(path: file.path) }
            guard file.sources.count <= VoiceModelCatalogRules.maximumSources else { return .invalidField("files.\(file.path).sources") }
            for source in file.sources where !VoiceModelCatalogRules.isHTTPSURL(source) {
                return .insecureSource(path: file.path)
            }
            if let licenseId = file.licenseId, !licenseIDs.contains(licenseId) { return .unknownLicense(licenseId) }
            if let origin = file.origin, !VoiceModelCatalogRules.isHTTPSURL(origin.url) {
                return .insecureSource(path: "\(file.path).origin")
            }
            if let note = file.origin?.note, note.count > VoiceModelCatalogRules.maximumNoteCharacters {
                return .invalidField("files.\(file.path).origin.note")
            }
        }
        // A path can't be both a file and the folder another file sits in.
        let lowered = paths.sorted()
        for path in lowered where lowered.contains(where: { $0.hasPrefix(path + "/") }) {
            return .duplicatePath(path)
        }
        return nil
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isRFC3339DateTime(_ text: String) -> Bool {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) != nil || fractional.date(from: text) != nil
    }
}

/// The field-level rules, written out by hand rather than as regular expressions so they mean the
/// same on every platform and a trailing newline can't slip past an end-of-line anchor. The schema
/// states the same rules as patterns; the neighbouring-input table in the fixtures holds both to it.
public enum VoiceModelCatalogRules {
    public static let maximumVoices = 64
    public static let maximumFiles = 256
    public static let maximumSources = 8
    public static let maximumLicenses = 16
    public static let maximumURLCharacters = 2_048
    public static let maximumSummaryCharacters = 1_500
    public static let maximumNoteCharacters = 500

    /// `^[a-z0-9][a-z0-9-]{0,63}$`
    public static func isVoiceID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...64).contains(bytes.count), isLowerAlnum(bytes[0]) else { return false }
        return bytes.allSatisfy { isLowerAlnum($0) || $0 == UInt8(ascii: "-") }
    }

    /// `^[a-z0-9][a-z0-9-]{0,31}$`
    public static func isRuntimeName(_ text: String) -> Bool {
        isVoiceID(text) && text.utf8.count <= 32
    }

    /// `^[A-Za-z0-9.+-]+$`
    public static func isSPDXId(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 64 && text.utf8.allSatisfy { isAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") }
    }

    /// 64 lowercase hex characters.
    public static func isLowercaseSHA256(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 64 && bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// A plain `https://host[:port][/path][?query]` URL of at most 2,048 characters. Lowercase scheme, a
    /// dotted ASCII host, a port from 1 to 65535, and a path of unreserved characters, sub-delimiters,
    /// `:`, `@`, `/`, `?` and `%XX` escapes. No credentials, fragment, whitespace or other characters.
    /// Hand-written so Foundation's URL parsing, which differs between platforms, never decides.
    public static func isHTTPSURL(_ text: String) -> Bool {
        let prefix = "https://"
        guard text.hasPrefix(prefix), text.utf8.count <= maximumURLCharacters else { return false }
        let rest = Array(text.utf8.dropFirst(prefix.utf8.count))
        let authorityEnd = rest.firstIndex(of: UInt8(ascii: "/")) ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        let hostAndPort = authority.split(separator: UInt8(ascii: ":"), maxSplits: 1, omittingEmptySubsequences: false)
        guard let host = hostAndPort.first, let first = host.first, let last = host.last,
              isAlnum(first), isAlnum(last),
              host.allSatisfy({ isAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }) else {
            return false
        }
        if hostAndPort.count == 2 {
            let port = hostAndPort[1]
            guard (1...5).contains(port.count), port.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let number = Int(String(decoding: port, as: UTF8.self)), (1...65_535).contains(number) else { return false }
            guard port.first != UInt8(ascii: "0") else { return false }
        }
        var index = authorityEnd
        while index < rest.endIndex {
            let byte = rest[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < rest.count, isHexDigit(rest[index + 1]), isHexDigit(rest[index + 2]) else { return false }
                index += 3
                continue
            }
            guard isAlnum(byte) || pathPunctuation.contains(byte) else { return false }
            index += 1
        }
        return true
    }

    /// A path inside the voice's folder: relative, `/`-separated, only letters, digits and `. _ + -`
    /// in each segment, no empty or `.`/`..` segments. Nothing a file system treats specially.
    public static func isRelativeFilePath(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 256 else { return false }
        let segments = text.split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".."
                && segment.utf8.allSatisfy { isAlnum($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") }
        }
    }

    /// `26`, `26.0` or `26.0.1`.
    public static func isIOSVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.utf8.count <= 4 && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
    }

    private static let pathPunctuation: Set<UInt8> = Set("-._~!$&'()*+,;=:@/?".utf8)

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    private static func isAlnum(_ byte: UInt8) -> Bool {
        isLowerAlnum(byte) || (byte >= 0x41 && byte <= 0x5A)
    }

    private static func isLowerAlnum(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x7A)
    }
}
