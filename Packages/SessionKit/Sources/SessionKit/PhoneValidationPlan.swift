import Foundation

/// A daily phone pass covers the entire open backlog in the selected binary, not an install delta.
/// The writer proposes checks; this type audits coverage and groups them by the same concrete source.
public struct PhoneValidationPlan: Codable, Sendable {
    public struct Check: Codable, Sendable {
        public var issues: [Int]
        public var source: String
        public var setup: String
        public var controls: [String]
        public var action: String
        public var expected: String
        public var minutes: Int
    }

    public struct Blocked: Codable, Sendable {
        public var issue: Int
        public var reason: String
    }

    public var checks: [Check]
    public var blocked: [Blocked]

    public struct Request: Codable, Sendable {
        public var build: String
        public var required: [Int]
        public var previousStillOpen: [Int]
        public var controls: [String]
        public var proposal: PhoneValidationPlan
    }

    public enum Invalid: Error, Equatable {
        case coverage
        case check
    }

    public static func audit(_ request: Request) throws -> PhoneValidationPlan {
        let plan = request.proposal
        let required = Set(request.required)
        let checked = Set(plan.checks.flatMap(\.issues))
        let blocked = Set(plan.blocked.map(\.issue))
        // Every eligible issue is accounted for, including those on yesterday's pass. A blocked
        // check is explicit and cannot be reported as PASS. Unknown issues cannot slip into results.
        guard Set(request.previousStillOpen).isSubset(of: required),
              checked.union(blocked) == required, checked.isDisjoint(with: blocked),
              plan.blocked.count == blocked.count else { throw Invalid.coverage }
        let controls = Set(request.controls)
        for check in plan.checks {
            guard !check.issues.isEmpty, !check.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !check.setup.isEmpty, !check.action.isEmpty, !check.expected.isEmpty,
                  (1...30).contains(check.minutes), !check.controls.isEmpty,
                  check.controls.allSatisfy({ controls.contains($0) && check.action.contains("**\($0)**") })
            else { throw Invalid.check }
        }
        guard plan.blocked.allSatisfy({ !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw Invalid.check }
        return plan
    }

    public var minutes: Int { 2 + checks.reduce(0) { $0 + $1.minutes } }

    public func markdown(build: String, planID: String) -> String {
        var lines = ["# Phone pass \(planID)", "", "Build: `\(build)`. About \(minutes) minutes, including install.", "",
                     "1. Plug in and unlock your iPhone. Double-click **Install Spoken Margins on iPhone** on the Mac Desktop.",
                     "2. Open Spoken Margins. If available, Settings > Version must end with `\(build.prefix(7))`.",
                     "   Keep your Library and recordings. Use the sources below; do not delete or reset anything.", ""]
        let sources = checks.map(\.source).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for (index, source) in sources.enumerated() {
            let group = checks.filter { $0.source == source }
            lines += ["\(index + 3). **\(source)**", "   \(group[0].setup)"]
            for check in group {
                // Keep extra prerequisites if two checks on the same source require different setup.
                if check.setup != group[0].setup { lines.append("   - Setup: \(check.setup)") }
                let numbers = check.issues.map { "#\($0)" }.joined(separator: ", ")
                lines += ["   - \(check.action)", "     Expect: \(check.expected) (\(numbers))."]
            }
            lines.append("")
        }
        if !blocked.isEmpty {
            lines += ["Waiting for a runnable check (coordinator must resolve these):", ""]
            lines += blocked.map { "- #\($0.issue): \($0.reason)" }
            lines.append("")
        }
        lines += ["Paste this in one reply. Replace each TODO with PASS, FAIL plus what happened, or SKIP.",
                  "Only mark an issue PASS if every check naming it passed.", "", "```text", "Phone pass \(planID); build \(build)"]
        lines += Set(checks.flatMap(\.issues)).sorted().map { "#\($0): TODO" }
        lines += ["```", "", "Issues: " + Set(checks.flatMap(\.issues) + blocked.map(\.issue)).sorted()
            .map { "#\($0)" }.joined(separator: ", "), ""]
        return lines.joined(separator: "\n")
    }
}
