import Foundation
@testable import SessionKit
import SessionKitPersistence

// This program is compiled against the pinned prior build's unmodified sources.
// The fixture is synthetic, not a copy of a user's library.
let store = try SQLiteSessionStore(path: CommandLine.arguments[1])
let item = Item(id: "prior-article", title: "Prior release article", mediaType: "text",
                text: "The source must survive an upgrade.", externalReference: nil, status: "ready")
try store.saveItem(item)
for (id, offset, words) in [("prior-A", 7, "ALPHA prior note"), ("prior-B", 19, "BRAVO prior note")] {
    let session = Session(id: id, itemId: item.id, status: "in_progress", phase: .itemPlayback,
                          currentTargetType: .itemTextTTS, currentTargetId: item.id,
                          position: Position(charOffset: offset), completionPercent: 20, playbackRate: 1.5)
    try store.saveSession(session)
    let note = Interjection(id: "shared-note-id", itemId: item.id, sessionId: id,
                            targetType: .item, targetId: item.id, createdAt: Date(timeIntervalSince1970: 1),
                            roughPercent: 20,
                            anchor: Anchor(anchorType: .text, startChar: offset, endChar: offset + 1,
                                           anchorBefore: "The source", anchorAfter: "must survive"),
                            audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed",
                            transcript: words, cleanedTranscript: nil, displayText: nil, status: "active")
    try store.saveInterjection(note)
}
