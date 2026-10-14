import Foundation

/// Summarizes each context, then folds the partial summaries in groups of four until one is left
/// (#1006). Each group is sent as `PARTIAL <n>:` blocks, which the on-device client reads back.
public enum SummaryPartialsReducer {
    public static let groupSize = 4
    public static let partialCharacterLimit = 1_200

    /// The reduced summaries: one string, or none when `contexts` is empty. Calls `summarize` one at
    /// a time, in order, and passes its errors through.
    public static func reduce(
        contexts: [String],
        summarize: @Sendable (String) async throws -> String
    ) async throws -> [String] {
        var partials: [String] = []
        for context in contexts {
            partials.append(try await summarize(context))
        }
        while partials.count > 1 {
            var reduced: [String] = []
            var start = 0
            while start < partials.count {
                let end = min(partials.count, start + groupSize)
                reduced.append(try await summarize(payload(for: partials[start..<end])))
                start = end
            }
            partials = reduced
        }
        return partials
    }

    /// The reduce prompt for one group: `PARTIAL <n>:` and the summary clipped to
    /// `partialCharacterLimit`, the blocks joined by a blank line.
    public static func payload(for group: ArraySlice<String>) -> String {
        group.enumerated().map { index, summary in
            "PARTIAL \(index + 1):\n\(String(summary.prefix(partialCharacterLimit)))"
        }.joined(separator: "\n\n")
    }
}
