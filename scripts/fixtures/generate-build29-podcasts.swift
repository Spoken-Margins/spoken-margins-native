import Foundation
@testable import SessionKit
import SessionKitPersistence

// This program is compiled against Build 29's unmodified sources (#352). The
// Library is synthetic, shaped the way Build 29 leaves podcasts: streamed episodes
// whose length was never stored, Margins anchored by media time, and an episode
// already finished before the upgrade.
let store = try SQLiteSessionStore(path: CommandLine.arguments[1])

func podcast(_ id: String, _ title: String, durationMs: Int?) -> Item {
    Item(id: id, title: title, mediaType: TargetType.transcriptBackedMedia.rawValue, text: nil,
         externalReference: "https://feeds.example.com/b29/\(id)", status: "ready", externalReferenceType: "url",
         media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/b29/\(id).mp3", durationMs: durationMs),
         sourceTitle: "Build 29 Show", createdAt: Date(timeIntervalSince1970: 1_758_000_000))
}

func margin(_ id: String, item: Item, session: Session, mediaTimeMs: Int?, startChar: Int = 0, endChar: Int = 0,
            roughPercent: Int, words: String, voice: Bool) -> Interjection {
    Interjection(id: id, itemId: item.id, sessionId: session.id, targetType: .item, targetId: item.id,
                 createdAt: Date(timeIntervalSince1970: 1_758_000_100), roughPercent: roughPercent,
                 anchor: Anchor(anchorType: mediaTimeMs == nil ? .text : .media, startChar: startChar, endChar: endChar,
                                anchorBefore: "", anchorAfter: "", mediaTimeMs: mediaTimeMs),
                 audioPath: voice ? "\(id).m4a" : nil, audioStatus: voice ? "saved" : "none",
                 transcriptionStatus: "transcribed", transcript: words, cleanedTranscript: nil,
                 displayText: words, status: "active")
}

func mediaSession(_ item: Item, atMs mediaTimeMs: Int, percent: Int, finished: Bool = false) -> Session {
    Session(id: "session-\(item.id)", itemId: item.id, createdAt: Date(timeIntervalSince1970: 1_758_000_000),
            completedAt: finished ? Date(timeIntervalSince1970: 1_758_003_600) : nil,
            status: finished ? "finished" : "in_progress", phase: finished ? .finished : .itemPlayback,
            currentTargetType: .transcriptBackedMedia, currentTargetId: item.media?.url ?? item.id,
            position: Position(mediaTimeMs: mediaTimeMs), completionPercent: percent, playbackRate: 1)
}

// Streamed, length never stored, in progress at 12:00. Voice and written Margins
// before, near and far past the listener's place.
let noLength = podcast("b29-podcast-no-length", "Streamed episode, length never stored", durationMs: nil)
try store.saveItem(noLength)
let noLengthSession = mediaSession(noLength, atMs: 720_000, percent: 20)
try store.saveSession(noLengthSession)
try store.saveInterjection(margin("b29-margin-early", item: noLength, session: noLengthSession, mediaTimeMs: 120_000, roughPercent: 3, words: "Early voice Margin", voice: true))
try store.saveInterjection(margin("b29-margin-here", item: noLength, session: noLengthSession, mediaTimeMs: 750_000, roughPercent: 20, words: "Written Margin at the listener's place", voice: false))
try store.saveInterjection(margin("b29-margin-late", item: noLength, session: noLengthSession, mediaTimeMs: 2_700_000, roughPercent: 75, words: "Late voice Margin", voice: true))

// Length known from the feed (60:00), in progress at 18:00 (30%).
let known = podcast("b29-podcast-known-length", "Episode with a known length", durationMs: 3_600_000)
try store.saveItem(known)
let knownSession = mediaSession(known, atMs: 1_080_000, percent: 30)
try store.saveSession(knownSession)
try store.saveInterjection(margin("b29-margin-known-early", item: known, session: knownSession, mediaTimeMs: 600_000, roughPercent: 16, words: "Known-length early Margin", voice: true))
try store.saveInterjection(margin("b29-margin-known-late", item: known, session: knownSession, mediaTimeMs: 2_400_000, roughPercent: 66, words: "Known-length later Margin", voice: false))

// Finished before the upgrade, length never stored.
var finished = podcast("b29-podcast-finished", "Episode finished before the upgrade", durationMs: nil)
finished.sourceCompletedAt = Date(timeIntervalSince1970: 1_758_003_600)
try store.saveItem(finished)
let finishedSession = mediaSession(finished, atMs: 3_000_000, percent: 100, finished: true)
try store.saveSession(finishedSession)
try store.saveInterjection(margin("b29-margin-finished", item: finished, session: finishedSession, mediaTimeMs: 300_000, roughPercent: 10, words: "Margin on a finished episode", voice: true))

// An article, so the text path is covered by the same sweep.
let articleText = "Upgrades must keep the listener's place. Nothing here is finished yet."
let article = Item(id: "b29-article", title: "Article in progress", mediaType: "text", text: articleText,
                   externalReference: nil, status: "ready", createdAt: Date(timeIntervalSince1970: 1_758_000_000))
try store.saveItem(article)
let articleSession = Session(id: "session-\(article.id)", itemId: article.id, createdAt: Date(timeIntervalSince1970: 1_758_000_000),
                             status: "in_progress", phase: .itemPlayback, currentTargetType: .itemTextTTS,
                             currentTargetId: article.id, position: Position(charOffset: 9), completionPercent: 12, playbackRate: 1)
try store.saveSession(articleSession)
try store.saveInterjection(margin("b29-margin-article", item: article, session: articleSession, mediaTimeMs: nil,
                                  startChar: 23, endChar: 33, roughPercent: 32, words: "Written Margin on the article", voice: false))
