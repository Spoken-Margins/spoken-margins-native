import Foundation
import SessionKit

/// Source coordinates, never an estimated whole-item media duration.
enum PreparedRenderFrontier {
    static func fraction(manifest: PreparedAudioManifest?, signature: TTSRenderSignature, sourceText: String, canonicalSourceText: String, root: URL) -> Double {
        guard let manifest, manifest.signature == signature, manifest.state != .needsRepreparation,
              !sourceText.isEmpty, sourceText == canonicalSourceText else { return 0 }
        func exists(_ path: String, bytes: Int64) -> Bool {
            let file = root.appendingPathComponent(path).standardizedFileURL
            guard bytes > 0, file.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else { return false }
            return values.isRegularFile == true && Int64(values.fileSize ?? -1) == bytes
        }
        if manifest.state == .readyOffline, let artifact = manifest.artifact,
           exists(artifact.relativePath, bytes: artifact.byteCount) { return 1 }
        let bytes = Array(sourceText.utf8)
        var end = 0
        var next = 0
        for chunk in manifest.chunks.sorted(by: { $0.index < $1.index }) {
            let start = chunk.sourceRange.utf8Start
            let stop = chunk.sourceRange.utf8End
            guard chunk.index == next, chunk.sourceRange.documentId == manifest.sourcePackageId,
                  start >= end, stop > start, stop <= bytes.count,
                  String(decoding: bytes[end..<start], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  exists(chunk.relativePath, bytes: chunk.byteCount) else { break }
            end = stop; next += 1
        }
        return Double(String(decoding: bytes.prefix(end), as: UTF8.self).count) / Double(sourceText.count)
    }
}

enum PlaybackQualityPresentation {
    /// Shared with the Lock Screen's Skim buttons (#115).
    static func skimTitle(destinationMs: Int?, backward: Bool) -> String {
        SkimDestinationLabel.title(destinationMs: destinationMs, backward: backward)
    }
}
