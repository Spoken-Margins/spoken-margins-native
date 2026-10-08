import Foundation
import XCTest
@testable import SessionKit

/// The provider receives `DiscussionContext.contextJSON` as text, so the exact characters matter. The Linux tests
/// compare parsed JSON; this Mac-host test pins the text for one fixed input. The expected strings were produced by
/// the code that lived in `Gate1AppModel.sessionContextJSON` before the move (P15, #973), run on Linux; Darwin was
/// not available when they were captured. If this fails on whitespace alone, capture the string again from the
/// old code on `next` and fix the literal, not the code.
final class DiscussionContextBytesTests: XCTestCase {
    private let note = Interjection(
        id: "a",
        itemId: "item-1",
        sessionId: "session-1",
        targetType: .item,
        targetId: "item-1",
        createdAt: Date(timeIntervalSince1970: 1),
        roughPercent: 0,
        anchor: Anchor(anchorType: .text, startChar: 0, endChar: 8, anchorBefore: "First", anchorAfter: "line."),
        audioPath: nil,
        audioStatus: "saved",
        transcriptionStatus: "transcribed",
        transcript: nil,
        cleanedTranscript: "A clean note.",
        displayText: nil,
        status: "active"
    )

    private let turns = [
        ConversationTurn(
            id: "t-ai", sessionId: "session-1", role: "assistant", turnType: "assistant_response", status: "done",
            summary: nil, text: "An answer.", rawText: nil, sourceInterjectionIds: []
        )
    ]

    private let chapters = [Chapter(id: "c1", title: "Opening", startChar: 0, endChar: 11, percent: 0)]

    func testSummaryContextIsByteForByteWhatTheModelSentBeforeTheMove() {
        let json = DiscussionContext.contextJSON(
            itemTitle: "Pinned title", itemText: "First line.\nSecond line.", overview: "Pinned overview.",
            chapters: chapters, turns: turns,
            currentTargetType: TargetType.itemTextTTS.rawValue, currentTargetId: "item-1",
            interjections: [note], currentFollowUp: nil
        )

        XCTAssertEqual(json, """
        {
          "currentFollowUp" : null,
          "interjections" : [
            {
              "anchorAfter" : "line.",
              "anchorBefore" : "First",
              "targetType" : "item",
              "transcript" : "A clean note.",
              "transcriptionStatus" : "transcribed"
            }
          ],
          "item" : {
            "text" : "First line.\\nSecond line.",
            "title" : "Pinned title"
          },
          "listeningMap" : {
            "chapters" : [
              {
                "endChar" : 11,
                "startChar" : 0,
                "title" : "Opening"
              }
            ],
            "overview" : "Pinned overview."
          },
          "primaryUserIntent" : null,
          "recentTurns" : [
            {
              "role" : "assistant",
              "text" : "An answer.",
              "turnType" : "assistant_response"
            }
          ],
          "schemaVersion" : "session-export.v1"
        }
        """)
    }

    func testConversationContextIsByteForByteWhatTheModelSentBeforeTheMove() {
        let json = DiscussionContext.contextJSON(
            itemTitle: "Pinned title", itemText: "First line.\nSecond line.", overview: "Pinned overview.",
            chapters: chapters, turns: turns,
            currentTargetType: TargetType.itemTextTTS.rawValue, currentTargetId: "item-1",
            interjections: [note], currentFollowUp: "Why?", explicitFollowUp: "Why?", primaryInterjections: [note]
        )

        XCTAssertEqual(json, """
        {
          "currentFollowUp" : "Why?",
          "interjections" : [
            {
              "anchorAfter" : "line.",
              "anchorBefore" : "First",
              "targetType" : "item",
              "transcript" : "A clean note.",
              "transcriptionStatus" : "transcribed"
            }
          ],
          "item" : {
            "text" : "First line.\\nSecond line.",
            "title" : "Pinned title"
          },
          "listeningMap" : {
            "chapters" : [
              {
                "endChar" : 11,
                "startChar" : 0,
                "title" : "Opening"
              }
            ],
            "overview" : "Pinned overview."
          },
          "primaryUserIntent" : {
            "interjections" : [
              {
                "anchorAfter" : "line.",
                "anchorBefore" : "First",
                "targetType" : "item",
                "transcript" : "A clean note.",
                "transcriptionStatus" : "transcribed"
              }
            ],
            "request" : "Why?",
            "source" : "typed_follow_up",
            "target" : {
              "overview" : "Pinned overview.",
              "targetType" : "item_text_tts",
              "title" : "Pinned title"
            },
            "targetType" : "item_text_tts"
          },
          "recentTurns" : [
            {
              "role" : "assistant",
              "text" : "An answer.",
              "turnType" : "assistant_response"
            }
          ],
          "schemaVersion" : "conversation-context.v2"
        }
        """)
    }
}
