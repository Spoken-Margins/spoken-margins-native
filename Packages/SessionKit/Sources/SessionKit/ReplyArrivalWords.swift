import Foundation

/// Banner C after a pickup found answers (`docs/design/reply-mailbox.md`, screen C).
public struct ReplyArrivalBanner: Equatable, Sendable {
    public enum Destination: Equatable, Sendable {
        /// One friend on one item: **Open** shows that item's screen (`showImportedItem`) and starts nothing.
        case item(id: String)
        /// Several friends, or one friend on several items: **Open** goes to the Following tab.
        case following
    }

    public let text: String
    public let openTitle: String
    public let destination: Destination
}

/// The words of the reply-box screens on the phone (#4675): banner C, the friend card's About part (D) and the Report
/// this answer sheet (E). New strings say "answer"; the existing "reply" strings are untouched.
public enum ReplyArrivalWords {
    // MARK: C. Arrival banner

    public static let openTitle = "Open"

    /// Nil when nothing new arrived. A friend is told apart by the name they typed; every answer with no name counts
    /// as one friend, "A friend" (`FollowingFriends.unnamedFriendName`), as the Following tab groups them.
    public static func banner(for arrivals: [ReplyArrival]) -> ReplyArrivalBanner? {
        let fresh = arrivals.filter { $0.newMarginCount > 0 }
        guard let first = fresh.first else { return nil }
        let friends = Set(fresh.map { friendKey($0.senderLabel) })
        if friends.count > 1 {
            return ReplyArrivalBanner(
                text: "New answers from \(friends.count) friends", openTitle: openTitle, destination: .following
            )
        }
        let name = friendName(first.senderLabel)
        let items = Set(fresh.map(\.itemId))
        if items.count > 1 {
            return ReplyArrivalBanner(
                text: "\(fresh.count) new answers from \(name)", openTitle: openTitle, destination: .following
            )
        }
        let title = first.itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = title.isEmpty ? "\(name) answered you" : "\(name) answered you on \(title)"
        return ReplyArrivalBanner(text: text, openTitle: openTitle, destination: .item(id: first.itemId))
    }

    /// The name the friend typed, or "A friend".
    public static func friendName(_ label: String?) -> String {
        SharedPacketArrival.senderName(label) ?? FollowingFriends.unnamedFriendName
    }

    private static func friendKey(_ label: String?) -> String {
        SharedPacketArrival.senderName(label)?
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) ?? ""
    }

    // MARK: D. The friend card, for an answer that came through a reply box

    public static let reportAnswer = "Report this answer"
    public static let stopAnswers = "Stop answers through this link"
    public static let stopConfirmTitle = "Stop answers through this link?"
    public static let stopConfirmButton = "Stop Answers"
    public static let cancel = "Cancel"
    public static let stopDone = "Answers through this link are stopped."
    public static let stopFailed = "Couldn't stop answers. Check your connection and try again."
    /// The row once stopped, shown disabled.
    public static let stoppedRow = "Answers through this link are stopped"
    /// The About line: the name is a label, not proof.
    public static let namesAreTyped = "Names on answers are typed by whoever sends them."

    /// "<Name> can still listen. New answers through this link won't reach you."
    public static func stopConfirmMessage(senderLabel: String?) -> String {
        "\(friendName(senderLabel)) can still listen. New answers through this link won't reach you."
    }

    // MARK: E. Report this answer

    public static let reportTitle = reportAnswer
    public static let reportSend = "Send Report"
    public static let reportCategorySection = "What is wrong?"
    public static let reportReasonSection = "What happened?"
    public static let reportReasonPlaceholder = "Optional"
    public static let reportAlsoStop = "Also stop answers through this link"
    /// The footer when the server says a second report within 7 days needs a written reason.
    public static let reportReasonOutstanding = "Please say what happened, then send again."
    public static let reportFailed = "Couldn't send the report. Check your connection and try again."
    public static let reportBoxEnded = "Hidden on this phone. The link has ended, so nothing of it is left on our server."
    public static let reportCloseFailedSuffix = "Couldn't stop answers. Try again from the card."

    /// "Report sent. Reference <ref>.", with the close failure added when the toggle's close failed.
    public static func reportSent(reference: String?, closeFailed: Bool) -> String {
        let ref = reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sent = ref.isEmpty ? "Report sent." : "Report sent. Reference \(ref)."
        return closeFailed ? "\(sent) \(reportCloseFailedSuffix)" : sent
    }
}

/// The six report categories, in the web form's words and order (`research/B4/server/internal/links/preview.go`).
public enum ReplyReportCategory: String, CaseIterable, Equatable, Sendable, Identifiable {
    case intimateImages = "intimate_images"
    case abuseMaterial = "abuse_material"
    case harassment = "harassment"
    case hatefulConduct = "hateful_conduct"
    case copyright = "copyright"
    case other = "other"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .intimateImages: "Intimate content shared without consent"
        case .abuseMaterial: "Child sexual abuse material"
        case .harassment: "Harassment or defamation"
        case .hatefulConduct: "Hateful conduct"
        case .copyright: "Copyright"
        case .other: "Other"
        }
    }

    /// Only an abuse-material report carries the box's full link, key included, so the hold keeps a key.
    public var sendsFullLink: Bool { self == .abuseMaterial }
}
