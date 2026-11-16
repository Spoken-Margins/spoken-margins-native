import Foundation

/// Runs `work` over `inputs` with at most `limit` calls in flight at once (#4388). Followed feeds used to be fetched one
/// at a time, so 41 feeds were 41 round trips in a row; a small cap overlaps the waiting without opening every
/// connection at once.
public enum BoundedConcurrency {
    /// The result for each input, in the order of `inputs`. An input that never started is nil: once the calling task is
    /// cancelled, no new call starts (a call already running sees the cancellation itself). A `limit` below 1 counts as 1.
    public static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        limit: Int,
        _ work: @escaping @Sendable (Input) async -> Output
    ) async -> [Output?] {
        var results = [Output?](repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            func start(into group: inout TaskGroup<(Int, Output)>) {
                guard next < inputs.count, !Task.isCancelled else { return }
                let index = next, input = inputs[next]
                next += 1
                group.addTask { (index, await work(input)) }
            }
            for _ in 0..<max(1, limit) { start(into: &group) }
            while let (index, output) = await group.next() {
                results[index] = output
                start(into: &group)
            }
        }
        return results
    }
}
