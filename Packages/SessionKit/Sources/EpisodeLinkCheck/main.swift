// episode-link-check: run each link in an assistant's pasted answer through the app's resolver (#4673).
//
//   swift run episode-link-check answer.txt [more.txt ...]   (or the answer on stdin)
//
// Prints one JSON object per link: the file, what the line claimed, the link kind, the resolver's status and
// failure reason, the episode it resolved to, and EpisodeLinkPaste's verdict. Network: the same public requests
// the app makes when a listener pastes the link (Apple lookup, the episode page, the feed).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SessionKit
import SessionKitFeeds

struct Row: Encodable {
    var file: String
    var url: String
    var kind: EpisodeLinkPaste.LinkKind
    var claimedShow: String?
    var claimedTitle: String?
    var markedShowLink: Bool
    var status: String
    var failureReason: String?
    var resolvedTitle: String?
    var resolvedShow: String?
    var resolvedDurationMs: Int?
    var hasAudio: Bool
    var verdict: EpisodeLinkPaste.Verdict
    var error: String?
}

func check(_ entry: EpisodeLinkPaste.Entry, file: String) async -> Row {
    let request = LinkResolutionRequest(id: UUID().uuidString, inputURL: entry.url, sourceSurface: "paste_back_check", createdAt: Date())
    var row = Row(file: file, url: entry.url, kind: entry.kind, claimedShow: entry.claimedShow, claimedTitle: entry.claimedTitle,
                  markedShowLink: entry.markedShowLink, status: "error", hasAudio: false, verdict: .failed)
    do {
        let result = try await PublicPodcastLinkResolver().resolveAsync(request)
        row.status = result.status.rawValue
        row.failureReason = result.failureReason
        row.resolvedTitle = result.selectedCandidate?.title
        row.resolvedShow = result.selectedCandidate?.showTitle
        row.resolvedDurationMs = result.selectedCandidate?.durationMs
        row.hasAudio = result.selectedCandidate?.audioURL?.isEmpty == false
        row.verdict = EpisodeLinkPaste.verdict(for: entry, result: result)
    } catch {
        row.error = String(describing: error)
    }
    return row
}

let paths = Array(CommandLine.arguments.dropFirst())
var inputs: [(String, String)] = []
if paths.isEmpty {
    inputs.append(("stdin", String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)))
} else {
    for path in paths {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
            exit(2)
        }
        inputs.append(((path as NSString).lastPathComponent, text))
    }
}

let jobs = inputs.flatMap { file, text in EpisodeLinkPaste.entries(in: text).map { (file, $0) } }
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

// A few links at a time: the app resolves one paste at a time, and Apple's lookup throttles bursts.
let rows = await withTaskGroup(of: (Int, Row).self) { group -> [Row] in
    var results = [Row?](repeating: nil, count: jobs.count)
    var next = 0
    func add(_ group: inout TaskGroup<(Int, Row)>) {
        guard next < jobs.count else { return }
        let index = next, job = jobs[index]
        next += 1
        group.addTask { (index, await check(job.1, file: job.0)) }
    }
    for _ in 0..<4 { add(&group) }
    while let (index, row) = await group.next() {
        results[index] = row
        add(&group)
    }
    return results.compactMap { $0 }
}
for row in rows {
    print(String(decoding: try encoder.encode(row), as: UTF8.self))
}
