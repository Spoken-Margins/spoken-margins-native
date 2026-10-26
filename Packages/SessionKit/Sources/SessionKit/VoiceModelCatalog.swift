import Foundation

// The voice catalog (#1816, first slice of #1391): one JSON document that lists every voice the app
// can download, with each file's size, SHA-256 and ordered HTTPS sources, and the licence that applies.
// Schema: Contracts/schemas/voice-model-catalog.schema.json. The catalog arrives inside a signed
// envelope (VoiceModelCatalogVerifier); nothing in this file trusts its input, it only describes it.

public enum VoiceModelStatus: String, Codable, Equatable, Sendable {
    case available
    /// The publisher or we pulled it. The app stops offering it; what the listener already has is
    /// the installer's decision (#1817).
    case withdrawn
    /// Replaced by `supersededBy`. Still installed copies keep working until the listener moves.
    case superseded
}

public struct VoiceModelRuntime: Codable, Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct VoiceModelFileOrigin: Codable, Equatable, Sendable {
    public var url: String
    public var note: String?

    public init(url: String, note: String? = nil) {
        self.url = url
        self.note = note
    }
}

/// An upstream archive a voice's files are taken from (#2086): the publisher ships some files only
/// inside it, so the app downloads it once, checks it, takes out the members it needs and deletes it.
public struct VoiceModelArchive: Codable, Equatable, Sendable {
    /// The archive formats this build can unpack.
    public static let supportedFormats: Set<String> = ["tar.bz2"]

    /// Named by `VoiceModelFile.archiveMember.archive`.
    public var id: String
    /// `tar.bz2` today.
    public var format: String
    public var byteCount: Int
    /// Lowercase hex, of the archive as downloaded.
    public var sha256: String
    /// HTTPS URLs in order of preference, the publisher's pinned release first.
    public var sources: [String]

    public init(id: String, format: String = "tar.bz2", byteCount: Int, sha256: String, sources: [String]) {
        self.id = id
        self.format = format
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sources = sources
    }
}

/// Which member of which archive holds a file's bytes. The member is written to the file's own `path`,
/// never extracted by its own name.
public struct VoiceModelArchiveMember: Codable, Equatable, Sendable {
    /// A `VoiceModelArchive.id` of the same voice.
    public var archive: String
    /// The member's path inside the archive, e.g. `sherpa-onnx-…/vocoder.int8.onnx`.
    public var member: String

    public init(archive: String, member: String) {
        self.archive = archive
        self.member = member
    }
}

/// One file of a voice. Its bytes come from exactly one place: `sources` (fetched as they are),
/// `archiveMember` (taken out of an archive the voice lists) or `content` (short text the signed
/// catalog carries itself, such as our notice of modification, which no publisher serves).
public struct VoiceModelFile: Codable, Equatable, Sendable {
    /// Where the file lands inside the voice's folder, e.g. `onnx/tts.json`.
    public var path: String
    public var byteCount: Int
    /// Lowercase hex.
    public var sha256: String
    /// HTTPS URLs in order of preference: the upstream pinned revision first, our own mirror only
    /// where the licence allows redistributing the file. Empty for an archive member or carried content.
    public var sources: [String]
    /// Which of the voice's `licenses` governs this file.
    public var licenseId: String?
    /// Where the bytes were derived from when no source serves this exact file (a member of an
    /// upstream archive, say). Provenance for readers, never used to download.
    public var origin: VoiceModelFileOrigin?
    public var archiveMember: VoiceModelArchiveMember?
    /// The file's UTF-8 text, when the catalog carries it.
    public var content: String?

    public init(
        path: String,
        byteCount: Int,
        sha256: String,
        sources: [String],
        licenseId: String? = nil,
        origin: VoiceModelFileOrigin? = nil,
        archiveMember: VoiceModelArchiveMember? = nil,
        content: String? = nil
    ) {
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sources = sources
        self.licenseId = licenseId
        self.origin = origin
        self.archiveMember = archiveMember
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case path, byteCount, sha256, sources, licenseId, origin, archiveMember, content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        sha256 = try container.decode(String.self, forKey: .sha256)
        // Absent for an archive member or carried content; the verifier requires exactly one of the three.
        sources = try container.decodeIfPresent([String].self, forKey: .sources) ?? []
        licenseId = try container.decodeIfPresent(String.self, forKey: .licenseId)
        origin = try container.decodeIfPresent(VoiceModelFileOrigin.self, forKey: .origin)
        archiveMember = try container.decodeIfPresent(VoiceModelArchiveMember.self, forKey: .archiveMember)
        content = try container.decodeIfPresent(String.self, forKey: .content)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(sha256, forKey: .sha256)
        if !sources.isEmpty || (archiveMember == nil && content == nil) {
            try container.encode(sources, forKey: .sources)
        }
        try container.encodeIfPresent(licenseId, forKey: .licenseId)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(archiveMember, forKey: .archiveMember)
        try container.encodeIfPresent(content, forKey: .content)
    }
}

public struct VoiceModelLicense: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Absent for licences that have no SPDX identifier (the Open RAIL licences).
    public var spdxId: String?
    public var textURL: String
    /// SHA-256 of the licence text when it was reviewed. A change at `textURL` shows up as a mismatch.
    public var textSHA256: String
    /// True when the listener has to agree to use restrictions before the files download.
    public var requiresAcceptance: Bool
    /// Plain words for any use restrictions. Required when `requiresAcceptance` is true.
    public var restrictionsSummary: String?

    public init(id: String, name: String, spdxId: String? = nil, textURL: String, textSHA256: String, requiresAcceptance: Bool, restrictionsSummary: String? = nil) {
        self.id = id
        self.name = name
        self.spdxId = spdxId
        self.textURL = textURL
        self.textSHA256 = textSHA256
        self.requiresAcceptance = requiresAcceptance
        self.restrictionsSummary = restrictionsSummary
    }
}

public struct VoiceModelEntry: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var publisher: String
    public var version: String
    public var runtime: VoiceModelRuntime
    public var minimumIOSVersion: String
    /// The device's physical memory, in megabytes, below which the voice is not offered.
    public var minimumMemoryMegabytes: Int
    /// The oldest Apple chip the voice is offered on, as `A14` (#2700): a Neural Engine voice that is too
    /// slow or too hot on an older phone. Apple silicon counts as the A chip it grew from (M1 as A14).
    /// Nil: no floor. An older build ignores the field, so a floor is only ever paired with a runtime
    /// (`coreml`, `phonon-ptts`) that such a build already leaves out.
    public var minimumChip: String?
    public var status: VoiceModelStatus
    /// The id of the voice that replaces this one. Required when `status` is `superseded`.
    public var supersededBy: String?
    /// True when the voice ships inside the app (Kitten), so its licence shows without a download.
    public var bundled: Bool
    public var files: [VoiceModelFile]
    /// Upstream archives some of `files` are taken from. Empty for most voices.
    public var archives: [VoiceModelArchive]
    public var licenses: [VoiceModelLicense]

    public init(
        id: String,
        displayName: String,
        publisher: String,
        version: String,
        runtime: VoiceModelRuntime,
        minimumIOSVersion: String,
        minimumMemoryMegabytes: Int,
        minimumChip: String? = nil,
        status: VoiceModelStatus = .available,
        supersededBy: String? = nil,
        bundled: Bool = false,
        files: [VoiceModelFile],
        archives: [VoiceModelArchive] = [],
        licenses: [VoiceModelLicense]
    ) {
        self.id = id
        self.displayName = displayName
        self.publisher = publisher
        self.version = version
        self.runtime = runtime
        self.minimumIOSVersion = minimumIOSVersion
        self.minimumMemoryMegabytes = minimumMemoryMegabytes
        self.minimumChip = minimumChip
        self.status = status
        self.supersededBy = supersededBy
        self.bundled = bundled
        self.files = files
        self.archives = archives
        self.licenses = licenses
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, publisher, version, runtime, minimumIOSVersion, minimumMemoryMegabytes, minimumChip, status, supersededBy, bundled, files, archives, licenses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        publisher = try container.decode(String.self, forKey: .publisher)
        version = try container.decode(String.self, forKey: .version)
        runtime = try container.decode(VoiceModelRuntime.self, forKey: .runtime)
        minimumIOSVersion = try container.decode(String.self, forKey: .minimumIOSVersion)
        minimumMemoryMegabytes = try container.decode(Int.self, forKey: .minimumMemoryMegabytes)
        minimumChip = try container.decodeIfPresent(String.self, forKey: .minimumChip)
        status = try container.decode(VoiceModelStatus.self, forKey: .status)
        supersededBy = try container.decodeIfPresent(String.self, forKey: .supersededBy)
        bundled = try container.decode(Bool.self, forKey: .bundled)
        files = try container.decode([VoiceModelFile].self, forKey: .files)
        archives = try container.decodeIfPresent([VoiceModelArchive].self, forKey: .archives) ?? []
        licenses = try container.decode([VoiceModelLicense].self, forKey: .licenses)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(publisher, forKey: .publisher)
        try container.encode(version, forKey: .version)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(minimumIOSVersion, forKey: .minimumIOSVersion)
        try container.encode(minimumMemoryMegabytes, forKey: .minimumMemoryMegabytes)
        try container.encodeIfPresent(minimumChip, forKey: .minimumChip)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(supersededBy, forKey: .supersededBy)
        try container.encode(bundled, forKey: .bundled)
        try container.encode(files, forKey: .files)
        if !archives.isEmpty { try container.encode(archives, forKey: .archives) }
        try container.encode(licenses, forKey: .licenses)
    }

    /// What the listener downloads, which the Settings row shows before they agree: each file fetched on
    /// its own, plus each archive a file is taken from (once, however many members it gives).
    public var downloadByteCount: Int {
        guard !bundled else { return 0 }
        let direct = files.filter { $0.archiveMember == nil && $0.content == nil }.reduce(0) { $0 + $1.byteCount }
        let used = Set(files.compactMap(\.archiveMember?.archive))
        return direct + archives.filter { used.contains($0.id) }.reduce(0) { $0 + $1.byteCount }
    }

    /// The voice's size once installed: every file, however it arrived.
    public var installedByteCount: Int {
        bundled ? 0 : files.reduce(0) { $0 + $1.byteCount }
    }

    /// The licences the listener must agree to before this voice downloads.
    public var licensesRequiringAcceptance: [VoiceModelLicense] {
        licenses.filter(\.requiresAcceptance)
    }
}

/// Why one entry was left out of an otherwise good catalog. Each reason names the field, so the
/// publisher can find it, and none of them stops the other voices from being offered.
public enum VoiceEntryRejection: Equatable, Sendable {
    /// A required field is missing or has the wrong type.
    case malformed
    case invalidField(String)
    /// The runtime isn't one this build can run, typically a newer catalog than the app.
    case unknownRuntime(String)
    case invalidHash(path: String)
    case emptySources(path: String)
    /// A source that isn't a plain `https://` URL.
    case insecureSource(path: String)
    case duplicatePath(String)
    case unknownLicense(String)
    /// A file names an archive the voice doesn't list.
    case unknownArchive(String)
    /// An archive in a format this build can't unpack, typically a newer catalog than the app.
    case unsupportedArchiveFormat(String)
    /// A file names more than one place its bytes come from (sources, an archive member, carried content).
    case ambiguousFileSource(path: String)
    /// A downloadable voice with nothing to download.
    case noFiles
    case supersededWithoutSuccessor
    case acceptanceWithoutSummary(licenseId: String)
}

public struct RejectedVoiceEntry: Equatable, Sendable {
    /// The entry's `id` when it could be read.
    public var id: String?
    public var reason: VoiceEntryRejection

    public init(id: String?, reason: VoiceEntryRejection) {
        self.id = id
        self.reason = reason
    }
}

/// The decoded catalog document. Decoding keeps going past an entry it cannot read: that entry lands
/// in `rejected` and the rest are kept. Nothing here is checked beyond the shape; the verifier does that.
public struct VoiceModelCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "voice-model-catalog.v1"

    public var schemaVersion: String
    /// Rises with every published catalog. The app refuses one lower than the last it accepted.
    public var catalogVersion: Int
    /// RFC 3339 date-time.
    public var issuedAt: String
    public var voices: [VoiceModelEntry]
    public internal(set) var rejected: [RejectedVoiceEntry] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, catalogVersion, issuedAt, voices
    }

    public init(schemaVersion: String = VoiceModelCatalog.currentSchemaVersion, catalogVersion: Int, issuedAt: String, voices: [VoiceModelEntry]) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.issuedAt = issuedAt
        self.voices = voices
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        catalogVersion = try container.decode(Int.self, forKey: .catalogVersion)
        issuedAt = try container.decode(String.self, forKey: .issuedAt)
        var unkeyed = try container.nestedUnkeyedContainer(forKey: .voices)
        var voices: [VoiceModelEntry] = []
        var rejected: [RejectedVoiceEntry] = []
        while !unkeyed.isAtEnd {
            let probe = try unkeyed.decode(EntryProbe.self)
            if let entry = probe.entry {
                voices.append(entry)
            } else {
                rejected.append(RejectedVoiceEntry(id: probe.id, reason: .malformed))
            }
        }
        self.voices = voices
        self.rejected = rejected
    }

    /// Decodes one catalog document (the signed payload, or a draft on disk).
    public static func decode(_ data: Data) throws -> VoiceModelCatalog {
        try JSONDecoder().decode(VoiceModelCatalog.self, from: data)
    }

    private struct EntryProbe: Decodable {
        var entry: VoiceModelEntry?
        var id: String?

        private enum IDKeys: String, CodingKey { case id }

        init(from decoder: Decoder) throws {
            entry = try? VoiceModelEntry(from: decoder)
            id = try? decoder.container(keyedBy: IDKeys.self).decode(String.self, forKey: .id)
        }
    }
}
