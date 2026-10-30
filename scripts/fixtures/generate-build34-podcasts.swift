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

// Build 34's podcasts (#1900): a streamed episode with a saved download and a Margin placed by media time, and an
// imported audio file the listener linked to its episode (Item.linkedEpisode, #755). The current code must read all
// of it and write nothing back that Build 34 couldn't (PriorBuildPersistenceTests).
var streamed = Item(id: "prior-podcast", title: "Prior release episode", mediaType: TargetType.transcriptBackedMedia.rawValue,
                    text: nil, externalReference: "https://feeds.example.com/prior", status: "ready", externalReferenceType: "url",
                    media: ItemMedia(sourceType: .remoteStream, url: "https://cdn.example.com/prior.mp3", durationMs: 1_800_000),
                    sourceTitle: "The Prior Show", createdAt: Date(timeIntervalSince1970: 1_758_000_000))
streamed.episodeGUID = "guid-prior"
streamed.showTitle = "The Prior Show"
streamed.publishedAt = "Tue, 29 Sep 2026 10:00:00 GMT"
try store.saveItem(streamed)
try store.savePodcastDownload(PodcastDownloadRecord(
    id: "prior-download", itemId: streamed.id, remoteURL: "https://cdn.example.com/prior.mp3",
    localRelativePath: "Podcasts/prior.mp3", state: .availableOffline, bytesWritten: 28_800_000, expectedBytes: 28_800_000,
    lastPlayedAt: Date(timeIntervalSince1970: 1_758_000_300), updatedAt: Date(timeIntervalSince1970: 1_758_000_400)))
let podcastSession = Session(id: "prior-podcast-session", itemId: streamed.id, createdAt: Date(timeIntervalSince1970: 1_758_000_000),
                             status: "in_progress", phase: .itemPlayback, currentTargetType: .transcriptBackedMedia,
                             currentTargetId: "https://cdn.example.com/prior.mp3", position: Position(mediaTimeMs: 600_000),
                             completionPercent: 33, playbackRate: 1)
try store.saveSession(podcastSession)
try store.saveInterjection(Interjection(
    id: "prior-podcast-margin", itemId: streamed.id, sessionId: podcastSession.id, targetType: .item, targetId: streamed.id,
    createdAt: Date(timeIntervalSince1970: 1_758_000_100), roughPercent: 33,
    anchor: Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: "", anchorAfter: "", mediaTimeMs: 600_000),
    audioPath: nil, audioStatus: "none", transcriptionStatus: "transcribed", transcript: "A podcast note", cleanedTranscript: nil,
    displayText: "A podcast note", status: "active"))
var linked = Item(id: "prior-linked-file", title: "Prior imported file", mediaType: TargetType.transcriptBackedMedia.rawValue,
                  text: nil, externalReference: "imported-audio://prior", status: "ready", externalReferenceType: "file",
                  media: ItemMedia(sourceType: .nativeMediaFile, url: "file:///var/mobile/Library/prior.mp3", durationMs: 1_790_000),
                  createdAt: Date(timeIntervalSince1970: 1_758_000_000))
linked.linkedEpisode = LinkedEpisode(guid: "guid-prior", title: "Prior release episode", showTitle: "The Prior Show",
                                     publishedAt: "Tue, 29 Sep 2026 10:00:00 GMT", pageURL: "https://feeds.example.com/prior",
                                     enclosureURL: "https://cdn.example.com/prior.mp3", durationMs: 1_800_000)
try store.saveItem(linked)
