import Foundation

extension PlaybackLivePassage {
    /// Canonical source coordinates, never a generated response's independent text clock.
    public static func sourceOffset(snapshot: SessionSnapshot, itemID: String,
                                    isNativeAudio: Bool, textLength: Int) -> Int? {
        guard !itemID.isEmpty, !isNativeAudio, textLength > 0,
              snapshot.itemId == itemID,
              let rawTarget = snapshot.targetType, let target = TargetType(rawValue: rawTarget),
              let offset = snapshot.currentTextStart else { return nil }
        switch target {
        case .itemTextTTS, .transcriptBackedMedia:
            return max(0, min(offset, textLength))
        case .assistantTurnTTS, .summaryTurnTTS, .browserOwnedMedia:
            return nil
        }
    }
}

extension PlaybackLivePassage.Margin {
    public init?(own note: Interjection, itemID: String, textLength: Int) {
        let anchor = note.anchor
        guard textLength > 0, note.itemId == itemID, note.status == "active", note.targetType == .item,
              anchor.startChar >= 0, anchor.startChar <= anchor.endChar,
              anchor.endChar <= textLength else { return nil }
        switch anchor.anchorType {
        case .text:
            break // A text point at EOF is a valid source anchor.
        case .transcript, .media:
            guard anchor.endChar > anchor.startChar else { return nil }
        case .turn:
            return nil
        }
        self.init(id: "\(note.sessionId)::\(note.id)", offset: anchor.startChar, origin: .own)
    }

    public init?(shared note: ImportedCommentaryInterjection, layer: ImportedCommentaryLayer,
                 itemID: String, textLength: Int) {
        let resolution = note.resolution
        guard textLength > 0, layer.itemId == itemID, layer.deletedAt == nil, note.layerId == layer.id,
              !resolution.isAmbiguous, let start = resolution.localStartChar,
              start >= 0, start <= textLength else { return nil }
        switch resolution.evidenceClass {
        case .articleTextVerified, .exactEdition, .recipientConfirmed:
            break
        case .transcriptVerified, .acousticVerified, .fused, .mapInterpolated, .timestampFallback,
             .ambiguous, .absentFromRecipientEdition, .unresolved:
            return nil
        }
        if let end = resolution.localEndChar {
            guard end >= start, end <= textLength else { return nil }
        }
        self.init(id: "shared::\(layer.id)::\(note.id)", offset: start, origin: .shared)
    }
}
