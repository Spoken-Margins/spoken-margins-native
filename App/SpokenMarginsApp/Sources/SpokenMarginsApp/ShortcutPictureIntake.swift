#if !SPOKEN_MARGINS_LEGACY
import AppIntents
import Foundation
import SessionKit

/// A screenshot or photo a Shortcut handed to Add Margin or Add Voice Margin (#4925): the bytes, or the address of a
/// file the Shortcut holds. It is read only when the Margin goes to a live session, where a picture has a place; for a
/// Library item nothing is read and the confirmation line says the picture was not kept.
struct ShortcutPicture: Sendable {
    /// The most a picture may be before it is fitted. A phone photo is a few MB and a screenshot less; anything near
    /// this is not a picture of a page, and the fitting step decodes the whole file.
    static let maxInputBytes = 40_000_000

    private let url: URL?
    private let data: Data?

    init(file: IntentFile) {
        // A file held by address is read later, off the main actor; one that came as bytes is already in memory.
        if let url = file.fileURL {
            self.url = url
            self.data = nil
        } else {
            self.url = nil
            self.data = file.data
        }
    }

    /// For a test, or a caller that already holds the bytes.
    init(data: Data) {
        self.url = nil
        self.data = data
    }

    /// For a test, or a caller that holds a file in the app's own folders.
    init(fileURL: URL) {
        self.url = fileURL
        self.data = nil
    }

    /// The picture's bytes, nil when the file can't be read or is over `maxInputBytes`. Reads run off the main actor.
    func bytes() async -> Data? {
        if let data { return data.count <= Self.maxInputBytes ? data : nil }
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Data? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            // One byte past the cap tells a file that is too large from one that is exactly at it.
            guard let read = try? handle.read(upToCount: Self.maxInputBytes + 1), read.count <= Self.maxInputBytes else { return nil }
            return read
        }.value
    }
}

/// What staging a Shortcut's picture came to.
enum ShortcutPictureStaging {
    case staged(LiveSessionPhotoStore.Staged)
    case unreadable
    case couldNotKeep
}

enum ShortcutPictureIntake {
    /// The picture staged for the worker, or why there is none: `(nil, .noneGiven)` with no picture,
    /// `(staged, .kept)` when it is ready to go with the Margin, else `(nil, why)`.
    static func prepare(
        _ picture: ShortcutPicture?, in store: LiveSessionPhotoStore? = LiveSessionPhotoIntake.store
    ) async -> (staged: LiveSessionPhotoStore.Staged?, outcome: SiriMarginRoute.PictureOutcome) {
        guard let picture else { return (nil, .noneGiven) }
        switch await stage(picture, in: store) {
        case let .staged(file): return (file, .kept)
        case .unreadable: return (nil, .unreadable)
        case .couldNotKeep: return (nil, .couldNotKeep)
        }
    }

    /// Fits the picture to what a Margin may keep (2,048 px, a JPEG within 1.5 MB, no metadata: the #2708 rules) and
    /// writes it to the temporary folder, where the live-session worker takes it over. The scaling and the write run off
    /// the main actor.
    static func stage(_ picture: ShortcutPicture, in store: LiveSessionPhotoStore? = LiveSessionPhotoIntake.store) async -> ShortcutPictureStaging {
        guard let bytes = await picture.bytes(), !bytes.isEmpty else { return .unreadable }
        // The encoder is the check that the bytes are a picture at all.
        let fitted = await Task.detached(priority: .userInitiated) { try? LiveSessionPhotoEncoder.encode(bytes) }.value
        guard let fitted else { return .unreadable }
        guard let store else { return .couldNotKeep }
        let staged = await Task.detached(priority: .userInitiated) {
            try? store.stage(data: fitted.data, widthPx: fitted.widthPx, heightPx: fitted.heightPx)
        }.value
        return staged.map { .staged($0) } ?? .couldNotKeep
    }

    /// The outcome to tell the listener once the worker has filed (or refused) a staged picture.
    static func outcome(of filing: LiveSessionFileWorker.PhotoFiling) -> SiriMarginRoute.PictureOutcome {
        // A save that filed nothing took its picture back out, so that too is a picture not kept.
        filing.photoFailed || filing.session == nil ? .couldNotKeep : .kept
    }
}

/// What a filed Margin reports back to the Shortcut: where it went and what became of the picture, if one came.
struct ShortcutMarginFiled: Equatable {
    let name: String
    let picture: SiriMarginRoute.PictureOutcome

    var dialogLine: String { SiriMarginRoute.confirmation(named: name, picture: picture) }
}
#endif
