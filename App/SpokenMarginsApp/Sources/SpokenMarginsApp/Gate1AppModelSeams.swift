import Foundation
import SessionKit

typealias PreparedTextAudioPrewarmHandler = @Sendable (
    _ itemId: String,
    _ title: String,
    _ text: String,
    _ outputDirectory: URL,
    _ voiceIdentifier: String?,
    _ speechRate: Float
) async -> Result<PreparedTextAudio?, Error>

typealias InterjectionTranscriptionHandler = @Sendable (_ audioPath: String) async throws -> String

typealias AlignedInterjectionTranscriptionHandler = @Sendable (_ audioPath: String) async throws -> AlignedInterjectionTranscript

typealias ShareMarginSilenceAnalysisHandler = @Sendable (
    _ sourceURL: URL,
    _ alignedTranscript: AlignedInterjectionTranscript
) throws -> [InterjectionCleanupDecision]

typealias ShareMarginAudioCleanupHandler = @Sendable (
    _ sourceURL: URL,
    _ destinationURL: URL,
    _ decisions: [InterjectionCleanupDecision]
) async throws -> Int
