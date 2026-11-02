import Foundation
import SessionKit

/// The job-table reads of the Library audio-preparation passes, for a caller off the main actor (#2507, fix class
/// `async-store`). `loadAudioPreparationJobs` and `loadEpisodeMapPreparationJobs` read whole tables, and the passes
/// asked for them up to eight times each, on the main actor, between awaits.
///
/// A pass reads the tables once through `StoreReader.readInOrder(AudioPreparationQueueEdits.orderKey)`, so what it
/// sees already includes the queue's Move, Prioritize, Skip and Clear that the listener asked for before it, and its
/// answer is not dropped when the pass is cancelled right after a committed chunk (the commit before it is not).
public enum AudioPreparationPassReads {
    /// Both job tables as the store holds them at one moment.
    public struct Jobs: Sendable, Equatable {
        public var audio: [AudioPreparationJob]
        public var episode: [EpisodeMapPreparationJob]

        public init(audio: [AudioPreparationJob] = [], episode: [EpisodeMapPreparationJob] = []) {
            self.audio = audio
            self.episode = episode
        }

        /// What changed between two reads of the same queue; an unchanged token means a pass made no progress.
        public var progressToken: [String] {
            BackgroundPreparationPlanner.progressToken(audioJobs: audio, episodeJobs: episode)
        }
    }

    /// Each table is read on its own and a failed read counts as empty, as the passes' `try?` reads did.
    public static func jobs(in store: SQLiteSessionStore) -> Jobs {
        Jobs(audio: (try? store.loadAudioPreparationJobs()) ?? [], episode: (try? store.loadEpisodeMapPreparationJobs()) ?? [])
    }

    /// Both tables, read off the caller's actor and in line behind the queue's own edits.
    public static func readJobs(_ store: SQLiteSessionStore) async -> Jobs {
        (try? await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey) { jobs(in: $0) }) ?? Jobs()
    }

    /// The audio jobs alone, for the passes that throw: a failed read is an error here, not an empty queue, because
    /// the pass picks its next job from it.
    public static func audioJobs(_ store: SQLiteSessionStore) async throws -> [AudioPreparationJob] {
        try await StoreReader(store).readInOrder(AudioPreparationQueueEdits.orderKey) { try $0.loadAudioPreparationJobs() }
    }
}
