import Foundation

/// Identifies the downloaded file instance for scheduling. The resolver still proves its byte edition
/// with SHA-256; scheduling must not hash an episode on the main actor just to join existing work.
public struct PodcastPlacementFile: Equatable, Sendable {
    public let url: URL
    private let inode: UInt64?
    private let size: UInt64?
    private let modifiedAt: Date?

    public init(url: URL) throws {
        self.url = url.standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: self.url.path)
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        size = (attributes[.size] as? NSNumber)?.uint64Value
        modifiedAt = attributes[.modificationDate] as? Date
    }
}

@MainActor
public final class PodcastPlacementPassCoordinator {
    public struct LayerInput: Equatable, Sendable {
        public let layer: ImportedCommentaryLayer
        public let records: [ImportedCommentaryInterjection]
        public init(layer: ImportedCommentaryLayer, records: [ImportedCommentaryInterjection]) {
            self.layer = layer
            self.records = records
        }
    }

    public struct Request: Sendable {
        public let itemId: String
        public let file: PodcastPlacementFile
        public let layers: [LayerInput]
        public var transcript: TranscriptTimeline?

        public init(itemId: String, file: PodcastPlacementFile, layers: [LayerInput], transcript: TranscriptTimeline? = nil) {
            self.itemId = itemId
            self.file = file
            self.layers = layers
            self.transcript = transcript
        }
    }

    public struct Context: Sendable {
        public let id: UUID
        public let request: Request
    }

    public struct Submission: Sendable {
        public let id: UUID
        public let joined: Bool
        public let completion: Task<Void, Never>
    }

    private struct Entry {
        let context: Context
        let task: Task<Void, Never>
    }
    private var active: [String: Entry] = [:]

    public init() {}

    public func schedule(
        _ request: Request,
        operation: @escaping @Sendable (Context) async -> Void
    ) -> Submission {
        var effective = request
        if let previous = active[request.itemId], previous.context.request.file == request.file {
            // A playback refresh must not replace a stronger pass with one that lost its transient
            // transcript. Changed layers still get a new pass, carrying that file-bound evidence.
            if effective.transcript == nil { effective.transcript = previous.context.request.transcript }
            if previous.context.request.layers == effective.layers,
               previous.context.request.transcript == effective.transcript {
                return Submission(id: previous.context.id, joined: true, completion: previous.task)
            }
        }
        active[request.itemId]?.task.cancel()
        let context = Context(id: UUID(), request: effective)
        let task = Task.detached { [weak self] in
            await operation(context)
            await self?.completed(context)
        }
        active[request.itemId] = Entry(context: context, task: task)
        return Submission(id: context.id, joined: false, completion: task)
    }

    public func isCurrent(_ context: Context) -> Bool {
        active[context.request.itemId]?.context.id == context.id
    }

    public func cancel(itemId: String) {
        active.removeValue(forKey: itemId)?.task.cancel()
    }

    private func completed(_ context: Context) {
        guard isCurrent(context) else { return }
        active.removeValue(forKey: context.request.itemId)
    }
}
