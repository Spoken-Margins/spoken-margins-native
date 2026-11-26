import Foundation
import SessionKit
import Vision

/// Reads a page number off a photo Margin's picture (#2708, item 4), on the phone, with Vision's text recogniser. Nothing
/// leaves the phone and no Apple Intelligence is involved. Only the number is kept: the lines recognised on the page
/// are handed to `LiveSessionPagePhoto`, which returns a number, and are then dropped. The rule for what counts as a
/// page number is SessionKit's, so it is tested on the host; this type only turns Vision's output into its input.
enum LiveSessionPagePhotoReader {
    enum Outcome: Equatable, Sendable {
        /// The picture was read. `nil` means it has no page number to offer.
        case read(LiveSessionPlace?)
        /// The file is gone or could not be read. Nothing is recorded, so a later screen may try again.
        case unreadable
    }

    /// Runs off the main actor: decoding the picture and recognising its text take a moment.
    static func read(_ photo: LiveSessionPhoto) async -> Outcome {
        guard let url = LiveSessionPhotoImages.fileURL(for: photo) else { return .unreadable }
        return await Task.detached(priority: .utility) { recognise(url) }.value
    }

    nonisolated private static func recognise(_ url: URL) -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .unreadable }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // A page number is digits; "correcting" them toward words would only make mistakes.
        request.usesLanguageCorrection = false
        // Vision skips text shorter than about 3% of the picture by default; a page number in the footer of a whole-page
        // photo is often a third of that.
        request.minimumTextHeight = 0.008
        do {
            try VNImageRequestHandler(url: url, options: [:]).perform([request])
        } catch {
            return .unreadable
        }
        let lines: [LiveSessionPagePhoto.TextLine] = (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return LiveSessionPagePhoto.TextLine(
                text: best.string, minX: Double(box.minX), minY: Double(box.minY),
                width: Double(box.width), height: Double(box.height), confidence: Double(best.confidence)
            )
        }
        return .read(LiveSessionPagePhoto.place(in: lines))
    }
}
