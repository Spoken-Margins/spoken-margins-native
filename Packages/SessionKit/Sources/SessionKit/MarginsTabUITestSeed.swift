import Foundation

/// The Margins tab fixture (part of #3216), shared by the SessionKit tests and the app's UI-test seed
/// (`SPOKEN_MARGINS_UI_TEST_MARGINS_TAB=1`, so the simulator shows the same Margins the tests check): one podcast episode (the `.offlinePodcast` seed) with the
/// listener's own Margins and two friends' Margins, enough to scroll. Synthetic names and words only, never owner data.
///
/// - Two friends, Sam and Rae.
/// - A conversation of four: the listener's Margin, Sam's reply, the listener's answer, Sam's answer to that.
/// - Some friends' Margins heard, some not.
/// - One of Sam's voice Margins carries placeholder words (#3025), as one recorded on the web without transcription.
/// The HTML prototype of the screen can mirror this data.
public enum MarginsTabUITestSeed {
    public static let samLayerId = "layer-ui-tab-sam"
    public static let raeLayerId = "layer-ui-tab-rae"
    public static let samDigest = String(repeating: "5", count: 64)
    public static let raeDigest = String(repeating: "7", count: 64)
    /// The packet the listener's own Margins went out in, so Sam's replies find them.
    public static let listenerDigest = String(repeating: "1", count: 64)
    public static let sessionId = "session-\(UITestingLaunchSeed.podcastItemId)-ui-tab"
    /// Where the listener has got to: 13:00 of the 25-minute episode.
    public static let placeSeconds = 780
    /// Every friend's voice is this long.
    public static let voiceDurationMs = 6_000

    public static let ownFirstId = "own-ui-tab-sleep"
    public static let ownAnswerId = "own-ui-tab-answer"
    public static let ownWalkId = "own-ui-tab-walk"
    public static let placeholderId = "sam-ui-tab-placeholder"

    private struct Own {
        let id: String
        let seconds: Int
        let words: String
        let before: String
        let starred: Bool
        let answers: (digest: String, scoped: String)?
        let createdOffset: TimeInterval
    }

    private struct Friend {
        let id: String
        let layer: String
        let seconds: Int
        let words: String
        let before: String
        let heard: Bool
        let answers: (digest: String, scoped: String)?
        let createdOffset: TimeInterval
    }

    private static let own: [Own] = [
        Own(id: ownFirstId, seconds: 190,
            words: "This is the part I wanted you to hear. The bit about sleep debt adding up across the week.",
            before: "and what surprised the researchers was that the volunteers felt fine. They said they were rested, but by Friday their reaction times",
            starred: false, answers: nil, createdOffset: 0),
        Own(id: ownAnswerId, seconds: 212,
            words: "Ha, same. Try the no-screens hour they mention near the end.",
            before: "by Friday their reaction times looked like someone who had been awake all night, and none of them noticed",
            starred: false, answers: (samDigest, "sam-ui-tab-reply"), createdOffset: 200),
        Own(id: ownWalkId, seconds: 930,
            words: "Write this down: walk after lunch, not before. Ten minutes is enough.",
            before: "the glucose curves flattened when people walked for ten minutes after eating, and it didn't matter how fast they walked",
            starred: true, answers: nil, createdOffset: 10),
    ]

    private static let friends: [Friend] = [
        Friend(id: "rae-ui-tab-forty", layer: raeLayerId, seconds: 100,
               words: "Wait, the study had only forty people? I'd love to know how they picked them.",
               before: "the first trial was small, forty volunteers over six weeks, and every one of them slept in the lab",
               heard: true, answers: nil, createdOffset: 50),
        Friend(id: "sam-ui-tab-reply", layer: samLayerId, seconds: 200,
               words: "Okay, I see why you flagged it. I think I've been running on sleep debt for a month.",
               before: "They said they were rested, but by Friday their reaction times looked like someone who had been awake",
               heard: false, answers: (listenerDigest, ownFirstId), createdOffset: 100),
        Friend(id: "sam-ui-tab-tried", layer: samLayerId, seconds: 214,
               words: "Tried it last night. Slept like a rock. Keep sending these.",
               before: "awake all night, and none of them noticed it happening, which is the part that should worry us",
               heard: false, answers: (listenerDigest, ownAnswerId), createdOffset: 300),
        Friend(id: placeholderId, layer: samLayerId, seconds: 465,
               words: "Voice Margin at 7:45 in “UI Test Episode”, recorded 12 Nov 2026",
               before: "so the second study moved out of the lab and into people's homes, with a ring that tracked their sleep",
               heard: false, answers: nil, createdOffset: 110),
        Friend(id: "rae-ui-tab-guest", layer: raeLayerId, seconds: 680,
               words: "This guest is great. Can we get her on the book club list? She explains it without talking down.",
               before: "and I always tell people, you don't have to be perfect, you have to be boring. Same bedtime, same light",
               heard: false, answers: nil, createdOffset: 60),
        Friend(id: "sam-ui-tab-naps", layer: samLayerId, seconds: 1145,
               words: "Disagree here. Naps have never worked for me, I wake up groggier.",
               before: "a twenty-minute nap before three in the afternoon seemed to help almost everyone who tried it",
               heard: true, answers: nil, createdOffset: 120),
        Friend(id: "rae-ui-tab-ending", layer: raeLayerId, seconds: 1360,
               words: "The ending made me tear up a little. Thanks for sending this one.",
               before: "she said the thing she wished someone had told her at twenty was that rest isn't a reward you earn",
               heard: false, answers: nil, createdOffset: 70),
    ]

    /// The listener's own Margins, each with a recording at `audioPath(id)`, marked as sent in `listenerDigest`.
    public static func ownMargins(createdAt: Date, audioPath: (String) -> String) -> [Interjection] {
        own.map { margin in
            var anchor = Anchor(anchorType: .media, startChar: 0, endChar: 0, anchorBefore: margin.before, anchorAfter: "")
            anchor.mediaTimeMs = margin.seconds * 1_000
            var interjection = Interjection(
                id: margin.id, itemId: UITestingLaunchSeed.podcastItemId, sessionId: sessionId,
                targetType: .item, targetId: UITestingLaunchSeed.podcastItemId,
                createdAt: createdAt.addingTimeInterval(margin.createdOffset),
                roughPercent: margin.seconds * 100 / 1_500, anchor: anchor,
                audioPath: audioPath(margin.id), audioStatus: "saved", transcriptionStatus: "transcribed",
                transcript: margin.words, cleanedTranscript: nil, displayText: margin.words, status: "active",
                isStarredForSharing: margin.starred ? true : nil, captureKind: .audio
            )
            interjection.sharedAs = [MarginPacketIdentity(packageDigest: listenerDigest, packageScopedId: margin.id)]
            if let answers = margin.answers {
                interjection.replyTo = MarginReplyLink.replying(
                    to: MarginPacketIdentity(packageDigest: answers.digest, packageScopedId: answers.scoped),
                    parentConversationId: MarginReplyLink.conversationId(
                        rootedAt: MarginPacketIdentity(packageDigest: listenerDigest, packageScopedId: ownFirstId)))
            }
            return interjection
        }
    }

    public static func layers(importedAt: Date) -> [ImportedCommentaryLayer] {
        [(samLayerId, samDigest, "Sam"), (raeLayerId, raeDigest, "Rae")].map { id, digest, label in
            ImportedCommentaryLayer(
                id: id, itemId: UITestingLaunchSeed.podcastItemId, packageDigest: digest, packageId: "package-\(id)",
                itemIdentity: SharedItemIdentity(itemType: .podcast, title: "UI Test Episode", durationMs: 1_500_000),
                displayLabel: label, importedAt: importedAt, sourceResolutionStatus: .resolved, isEnabled: true
            )
        }
    }

    /// Each friend's Margins for `layerId`, placed exactly, with a recording at `audioPath(id)`.
    public static func friendMargins(layerId: String, createdAt: Date, audioPath: (String) -> String) -> [ImportedCommentaryInterjection] {
        let conversation = MarginReplyLink.conversationId(
            rootedAt: MarginPacketIdentity(packageDigest: listenerDigest, packageScopedId: ownFirstId))
        return friends.filter { $0.layer == layerId }.map { margin in
            let ms = margin.seconds * 1_000
            let created = createdAt.addingTimeInterval(margin.createdOffset)
            return ImportedCommentaryInterjection(
                id: margin.id, layerId: margin.layer, packageScopedId: margin.id, createdAt: created,
                anchorEvidence: PortableAnchorEvidence(anchorType: .media, prefix: margin.before, mediaTimeMs: ms),
                approvedTranscript: margin.words, audioPath: audioPath(margin.id), audioDurationMs: voiceDurationMs,
                resolution: ImportedAnchorResolution(evidenceClass: .exactEdition, localMediaTimeMs: ms, confidence: 1),
                firstHeardAt: margin.heard ? created.addingTimeInterval(3_600) : nil,
                replyLinks: margin.answers.map { answers in
                    [MarginReplyLink.replying(
                        to: MarginPacketIdentity(packageDigest: answers.digest, packageScopedId: answers.scoped),
                        parentConversationId: conversation)]
                }
            )
        }
    }

    /// Every Margin id the seed writes, own first, for the recordings it needs.
    public static var allMarginIds: [String] { own.map(\.id) + friends.map(\.id) }

}
