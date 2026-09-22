import Foundation
import SessionKit

/// App navigation uses source coordinates, never a synthetic reel timeline.
enum ConversationScope: String, CaseIterable, Identifiable {
    case all = "All"
    case margins = "Margins"
    case newMargins = "New Margins"
    var id: String { rawValue }
}

struct ConversationDestination: Identifiable, Equatable {
    enum Content: Equatable {
        case archived(MarginConversationSnapshot)
        case chapter
        case local(Interjection)
        case shared(ImportedCommentaryLayer, ImportedCommentaryInterjection)
    }
    let id: String
    let position: Int
    let title: String
    let content: Content
    var isMargin: Bool { if case .chapter = content { return false }; return true }
    var conversation: MarginConversation? {
        switch content {
        case .chapter: nil
        case .local(let note): note.conversation
        case .shared(_, let note): note.conversation
        case .archived(let node): node.conversation
        }
    }
    var transcript: String? {
        switch content {
        case .archived(let node): node.transcript
        case .chapter: nil
        case .local(let note): note.cleanedTranscript ?? note.transcript ?? note.displayText
        case .shared(_, let note): note.approvedTranscript
        }
    }
}

struct ConversationLeadIn: Equatable {
    let destination: ConversationDestination
    let origin: Int
    let wasPlaying: Bool
    let isMedia: Bool
    var contextEnd: Int? = nil
}

enum ConversationNavigation {
    static func next(in destinations: [ConversationDestination], position: Int, currentID: String?, backward: Bool) -> ConversationDestination? {
        let ordered = destinations.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            if $0.isMargin != $1.isMargin { return !$0.isMargin }
            return $0.id < $1.id
        }
        if let currentID, let index = ordered.firstIndex(where: { $0.id == currentID }) {
            let next = backward ? index - 1 : index + 1
            return ordered.indices.contains(next) ? ordered[next] : nil
        }
        return backward ? ordered.last { $0.position < position } : ordered.first { $0.position > position || ($0.position == position && $0.isMargin) }
    }

    /// Approximately 180 words/minute; stop at a sentence/paragraph boundary.
    /// Text positions remain characters even when a prepared voice is in use.
    static func contextStart(text: String, destination: Int, seconds: Int) -> Int {
        let chars = Array(text)
        let end = min(max(0, destination), chars.count)
        guard seconds > 0, end > 0 else { return end }
        var start = end
        var words = 0
        var inWord = false
        while start > 0 && words < seconds * 3 {
            start -= 1
            if chars[start].isWhitespace { inWord = false }
            else if !inWord { words += 1; inWord = true }
        }
        if start == 0 { return 0 }
        while start < end && !".!?\n".contains(chars[start]) { start += 1 }
        while start < end && (chars[start].isWhitespace || ".!?".contains(chars[start])) { start += 1 }
        return start
    }
}
