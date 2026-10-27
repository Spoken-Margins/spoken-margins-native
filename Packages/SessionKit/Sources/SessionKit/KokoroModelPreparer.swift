#if canImport(CoreML)
import CoreML
#endif
import Foundation

/// Kokoro's one-time preparation (#2705): compiles each downloaded `.mlpackage` once with
/// `MLModel.compileModel` and keeps the compiled copy at `compiled/<name>.mlmodelc` in the voice's folder,
/// which is where the port's `KokoroPipeline` looks when it is given that folder as its compiled-model cache.
/// The voice's first read then loads instead of compiling for minutes, and Remove deletes the copies with the
/// rest of the folder.
///
/// It starts by deleting any `compiled/` a failed attempt left, so a retry never trips over a half-written
/// bundle, and writes nothing outside the staged folder. Register it for the `coreml` runtime.
public struct KokoroModelPreparer: VoiceModelPreparing {
    /// Compiles one `.mlpackage` and returns where the compiled bundle was written (a temporary folder).
    public typealias Compile = @Sendable (URL) throws -> URL

    /// Merges misaki's gold and silver dictionaries (their JSON) into the one file the front end reads
    /// (`MisakiLexicon.tsv`). It's a closure so this module needn't depend on the front end.
    public typealias BuildLexicon = @Sendable (_ gold: Data, _ silver: Data) throws -> Data

    private let compile: Compile
    private let buildLexicon: BuildLexicon?

    /// `buildLexicon` nil skips the dictionary step (a voice entry that doesn't list the two dictionaries).
    public init(buildLexicon: BuildLexicon? = nil, compile: @escaping Compile) {
        self.compile = compile
        self.buildLexicon = buildLexicon
    }

    #if canImport(CoreML)
    /// Core ML's own compiler.
    public init(buildLexicon: BuildLexicon? = nil) {
        self.init(buildLexicon: buildLexicon, compile: { try MLModel.compileModel(at: $0) })
    }
    #endif

    public var needsPreparation: Bool { true }

    /// Each package the entry lists, by folder name, in a stable order.
    public static func packageNames(in entry: VoiceModelEntry) -> [String] {
        let prefix = KokoroVoice.modelsFolderName + "/"
        let names = entry.files.compactMap { file -> String? in
            guard file.path.hasPrefix(prefix) else { return nil }
            let first = file.path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            return first?.hasSuffix(".mlpackage") == true ? first : nil
        }
        return Array(Set(names)).sorted()
    }

    /// Writes `lexicon/misaki-us.tsv` from the two downloaded dictionaries, or nothing when the entry lists neither.
    private func prepareLexicon(in stagedFolder: URL, entry: VoiceModelEntry, fileManager: FileManager) throws {
        guard let buildLexicon else { return }
        let listed = Set(entry.files.map(\.path))
        guard listed.contains(KokoroVoice.lexiconGoldPath), listed.contains(KokoroVoice.lexiconSilverPath) else { return }
        let gold = try Data(contentsOf: stagedFolder.appendingPathComponent(KokoroVoice.lexiconGoldPath))
        let silver = try Data(contentsOf: stagedFolder.appendingPathComponent(KokoroVoice.lexiconSilverPath))
        let output = stagedFolder.appendingPathComponent(KokoroVoice.preparedLexiconPath)
        try? fileManager.removeItem(at: output)
        try buildLexicon(gold, silver).write(to: output, options: .atomic)
    }

    public func prepare(stagedFolder: URL, entry: VoiceModelEntry) async throws {
        let fileManager = FileManager.default
        let compiledFolder = stagedFolder.appendingPathComponent(KokoroVoice.compiledFolderName, isDirectory: true)
        if fileManager.fileExists(atPath: compiledFolder.path) {
            try fileManager.removeItem(at: compiledFolder)
        }
        try fileManager.createDirectory(at: compiledFolder, withIntermediateDirectories: true)
        try prepareLexicon(in: stagedFolder, entry: entry, fileManager: fileManager)
        let models = stagedFolder.appendingPathComponent(KokoroVoice.modelsFolderName, isDirectory: true)
        for name in Self.packageNames(in: entry) {
            try Task.checkCancellation()
            let package = models.appendingPathComponent(name, isDirectory: true)
            let compiled = try compile(package)
            let destination = compiledFolder.appendingPathComponent(
                (name as NSString).deletingPathExtension + ".mlmodelc", isDirectory: true)
            do {
                try fileManager.moveItem(at: compiled, to: destination)
            } catch {
                // A temporary folder on another volume can't be moved; copy it instead.
                try fileManager.copyItem(at: compiled, to: destination)
                try? fileManager.removeItem(at: compiled)
            }
        }
    }
}
