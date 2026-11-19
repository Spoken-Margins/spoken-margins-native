import Foundation

/// Words the learner never offers as a rule (#4046): too common in episode titles to say anything about a show. Only words of
/// four letters or more are listed, because shorter ones are never candidates. Folded the way rule words are (lowercase, no
/// diacritics), so a candidate is compared with this set as it stands. A Swift constant because SessionKit has no bundled
/// resources.
enum RuleSuggesterStopwords {
    static let words: Set<String> = [
        // Function words.
        "about", "above", "after", "again", "against", "along", "also", "always", "among", "another", "anything", "around",
        "because", "been", "before", "being", "below", "between", "both", "cannot", "could", "does",
        "doing", "done", "down", "during", "each", "either", "else", "even", "ever", "every", "everything", "from", "further",
        "gets", "getting", "give", "goes", "going", "gone", "have", "having", "here", "hers", "himself", "into", "itself",
        "just", "keep", "know", "last", "later", "less", "like", "made", "make", "makes", "many", "might", "more", "most",
        "much", "must", "myself", "need", "needs", "never", "next", "nothing", "only", "onto", "other", "others", "ours",
        "ourselves", "over", "same", "should", "since", "some", "something", "still", "such", "take", "than", "that",
        "their", "theirs", "them", "themselves", "then", "there", "these", "they", "thing", "things",
        "think", "this", "those", "though", "through", "thus", "today", "together", "under", "until", "upon", "very", "want",
        "wants", "well", "were", "what", "when", "where", "whether", "which", "while", "whom", "whose", "will",
        "with", "within", "without", "would", "your", "yours", "yourself", "yourselves",
        // Words that fill podcast and newsletter titles without naming a topic.
        "back", "best", "better", "big", "bonus", "chat", "classic", "come", "comes", "conversation", "daily", "edition",
        "episode", "episodes", "essay", "essays", "featuring", "first", "free", "full", "good", "great", "guest",
        "hear", "high", "highlights", "hour", "interview", "interviews", "issue", "listen", "live", "long", "look", "looking",
        "minute", "minutes", "monthly", "morning", "news", "newsletter", "night", "notes", "part", "plus", "podcast", "post",
        "preview", "question", "questions", "reading", "recap", "replay", "return", "returns", "review", "season", "series",
        "show", "special", "story", "stories", "talk", "talks", "tell", "tells", "thoughts", "time", "update", "updates",
        "video", "week", "weekly", "year", "years",
    ]

    static func contains(_ word: String) -> Bool { words.contains(word) }
}
