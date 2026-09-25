import Foundation
import SessionKit

#if canImport(FoundationModels)
import FoundationModels
#endif

enum DesktopChapterSummaryError: LocalizedError {
    case unavailable(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .invalidResponse: "The on-device model did not return a short chapter summary. Try again."
        }
    }
}

enum DesktopChapterSummarizer {
    static func availabilityMessage() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence to generate on-device summaries."
            case .unavailable(.modelNotReady): return "Apple's on-device model is still downloading or not ready."
            @unknown default: return "Apple's on-device model is unavailable."
            }
        }
        #endif
        return "On-device chapter summaries require macOS 26 or later."
    }

    static func summarize(chapter: Chapter, number: Int, sourceText: String) async throws -> String {
        if let reason = availabilityMessage() { throw DesktopChapterSummaryError.unavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let characters = Array(sourceText)
            let start = max(0, min(chapter.startChar, characters.count))
            let end = max(start, min(chapter.endChar, characters.count))
            let excerpt = String(characters[start..<end].prefix(6_000))
            let session = LanguageModelSession(
                model: .default,
                instructions: "Process this source only on device. Describe its content without inventing facts or copying long passages."
            )
            let response = try await session.respond(
                to: "Summarize chapter \(number), titled \(chapter.title), in one source-grounded sentence of at most 28 words. Return only the sentence.\n\n\(excerpt)",
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 100)
            )
            let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty, result.split(whereSeparator: \.isWhitespace).count <= 28,
                  !result.contains("\n") else { throw DesktopChapterSummaryError.invalidResponse }
            return result
        }
        #endif
        throw DesktopChapterSummaryError.unavailable("On-device chapter summaries require macOS 26 or later.")
    }
}
