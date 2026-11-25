import Foundation

/// The sender's background check that a friend's browser can play a share link (#4454).
///
/// The app loads the exact link in a hidden web view; the web app answers with one message (`Message`, the same
/// words as `Web/src/app/play-check.ts`). This file is everything about that answer that needs no web view: how a
/// message is read, what each state says under Share link, when a check may start, how long it may run, and which
/// link is checked next. Nothing here starts a request, plays audio or stores anything; the check lives in memory only.
public enum ShareLinkPlayCheck {
    /// How long a check may run, counted from the moment its web view starts loading (Default taken: waiting behind
    /// another check does not spend it, since a check that waits for a slot would otherwise start already late).
    public static let timeLimit: TimeInterval = 25

    // MARK: - What the web page says

    /// Why a friend's browser can't play the link. The raw values are the web page's own (`Web/src/app/logic/playability.ts`).
    public enum Reason: String, CaseIterable, Sendable {
        case article
        case noEpisodeAudio = "no-episode-audio"
        case paidPost = "paid-post"
        case noPostVoice = "no-post-voice"
        case audioRefused = "audio-refused"
        case audioFormat = "audio-format"
        case linkBroken = "link-broken"
        case linksOff = "links-off"
    }

    /// One message from the page, read from the body a web view hands the app (`[String: Any]` from JSON).
    public enum Message: Equatable, Sendable {
        /// The page is running the check. A web app that predates the check never sends it.
        case started
        case plays
        case cannot(Reason)
        /// The page opened the link but can't settle the audio without a publisher read it doesn't make (a Substack post's voice).
        case unverifiedPostVoice
        case linkDidNotOpen(Reason)
        /// The link did not open for a reason that isn't the link's: the phone is offline, or the server had a problem.
        case couldNotReach(offline: Bool)

        /// Reads a message, or nil for anything the app doesn't know (a newer web app's words are ignored, never guessed at).
        public init?(body: Any) {
            guard let dictionary = body as? [String: Any], let type = dictionary["type"] as? String else { return nil }
            switch type {
            case "started":
                self = .started
            case "verdict":
                switch dictionary["verdict"] as? String {
                case "plays":
                    self = .plays
                case "cannot":
                    guard let raw = dictionary["reason"] as? String, let reason = Reason(rawValue: raw),
                          reason != .linkBroken, reason != .linksOff else { return nil }
                    self = .cannot(reason)
                case "unverified":
                    guard dictionary["why"] as? String == "post-voice" else { return nil }
                    self = .unverifiedPostVoice
                default:
                    return nil
                }
            case "failed":
                switch dictionary["reason"] as? String {
                case "link-broken": self = .linkDidNotOpen(.linkBroken)
                case "links-off": self = .linkDidNotOpen(.linksOff)
                case "offline": self = .couldNotReach(offline: true)
                case "server": self = .couldNotReach(offline: false)
                default: return nil
                }
            default:
                return nil
            }
        }
    }

    // MARK: - Outcomes and the words for them

    /// Why a check could not run or finish. It is never a warning about the link.
    public enum NotChecked: Equatable, Sendable {
        case offline
        case lowDataMode
        /// A timeout, the web view's process ending, a server problem, or the app going to the background.
        case didNotFinish
        /// The link opens, but whether it plays can't be known without reading the publisher (a Substack post's voice).
        case postVoiceNotLookedUp
    }

    public enum Outcome: Equatable, Sendable {
        case checking
        case plays
        case problem(Reason)
        case notChecked(NotChecked)
        /// Nothing to say: the web app never said the check had started (it predates the check), so the line goes away.
        case gone

        public var isFinal: Bool {
            switch self {
            case .checking: false
            default: true
            }
        }

        /// Whether asking again could give a different answer: the phone was offline, Low Data Mode was on, or the
        /// check ran out of time or was cut off. A verdict, a missing probe and an unsettled post voice stay as they are.
        public var isWorthRetrying: Bool {
            switch self {
            case .notChecked(.offline), .notChecked(.lowDataMode), .notChecked(.didNotFinish): true
            default: false
            }
        }
    }

    public enum LineKind: Equatable, Sendable {
        case checking, checked, warning, notChecked
    }

    /// What is drawn under Share link. A problem has a heading and a remedy; every other line has only a heading.
    public struct Line: Equatable, Sendable {
        public let kind: LineKind
        public let heading: String
        public let remedy: String?

        /// What VoiceOver reads: the whole line is one element, and a problem says "Warning." first.
        public var accessibilityLabel: String {
            let words = [heading, remedy].compactMap { $0 }.joined(separator: " ")
            return kind == .warning ? "Warning. \(words)" : words
        }

        /// Only a problem is announced, and only once the share sheet has closed.
        public var isAnnounced: Bool { kind == .warning }
    }

    public static let checkingHeading = "Checking it plays in a browser…"
    public static let playsHeading = "Checked: it plays in a browser."

    /// Heading and remedy for a problem. "Send as a file" is the button already on the screen; no new button is added.
    public static func words(for reason: Reason) -> (heading: String, remedy: String) {
        switch reason {
        case .article:
            // The friend's browser lists the Margins and plays each one after the words before it (#5265).
            ("Your friend's browser plays your Margins on their own, not in place.",
             "Each one plays after the words just before it. To hear them in place, they need Spoken Margins on iPhone.")
        case .noEpisodeAudio:
            ("Your friend's browser plays your Margins without the episode.",
             "It has no public audio link. If the show has a public feed, add the episode from there and share again.")
        case .paidPost:
            ("Your friend's browser can't play this paid post.",
             "Only paid subscribers can hear it.")
        case .noPostVoice:
            ("Your friend's browser can't find audio for this post.",
             "They'll see your Margins' words. To hear it read aloud, they need Spoken Margins on iPhone.")
        case .audioRefused:
            ("Your friend's browser can't reach this episode's audio.",
             "The podcast's server turned the request away. Try again later, or add the episode again from the show.")
        case .audioFormat:
            ("Your friend's browser can't play this episode's audio format.",
             "To hear it in place, they need Spoken Margins on iPhone.")
        case .linkBroken:
            ("This link didn't open in a browser.",
             "Make a new link, or tap Send as a file.")
        case .linksOff:
            ("Links are switched off for now, so this link won't open.",
             "Tap Send as a file instead.")
        }
    }

    public static func notCheckedHeading(_ reason: NotChecked) -> String {
        switch reason {
        case .offline: "Not checked: you're offline."
        case .lowDataMode: "Not checked: Low Data Mode is on."
        case .didNotFinish: "Not checked: the check didn't finish."
        case .postVoiceNotLookedUp: "The link opens. Not checked: whether this post has audio."
        }
    }

    /// The line for an outcome, or nil when there is nothing to say.
    public static func line(for outcome: Outcome) -> Line? {
        switch outcome {
        case .checking:
            Line(kind: .checking, heading: checkingHeading, remedy: nil)
        case .plays:
            Line(kind: .checked, heading: playsHeading, remedy: nil)
        case .problem(let reason):
            Line(kind: .warning, heading: words(for: reason).heading, remedy: words(for: reason).remedy)
        case .notChecked(let reason):
            Line(kind: .notChecked, heading: notCheckedHeading(reason), remedy: nil)
        case .gone:
            nil
        }
    }

    /// The app's warning banner, for a problem found after the sender's screen has closed. A pass, or a check that
    /// couldn't run, says nothing there.
    public static func bannerText(for outcome: Outcome, title: String) -> String? {
        guard case .problem(let reason) = outcome else { return nil }
        return "Your link for \u{201C}\(title)\u{201D}: \(words(for: reason).heading)"
    }

    // MARK: - Starting

    /// What the phone knows before a check starts.
    public struct Network: Equatable, Sendable {
        public var isOnline: Bool
        public var isLowDataMode: Bool

        public init(isOnline: Bool, isLowDataMode: Bool) {
            self.isOnline = isOnline
            self.isLowDataMode = isLowDataMode
        }
    }

    /// Offline and Low Data Mode skip the check, with a line that says why.
    public static func skipReason(for network: Network) -> NotChecked? {
        if !network.isOnline { return .offline }
        if network.isLowDataMode { return .lowDataMode }
        return nil
    }

    // MARK: - One check

    /// What happens to a running check besides a message from the page.
    public enum Event: Equatable, Sendable {
        case message(Message)
        case timedOut
        /// The web view's content process ended.
        case processEnded
        /// The app went to the background (the phone locked, or the sender switched app). The check does no background work.
        case enteredBackground
    }

    /// The state of one link's check. The first final outcome stands; nothing later changes it.
    public struct Session: Equatable, Sendable {
        public private(set) var outcome: Outcome = .checking
        public private(set) var hasStarted = false

        public init() {}

        /// A session that never starts: offline, or Low Data Mode.
        public init(skippedFor network: Network) {
            if let reason = ShareLinkPlayCheck.skipReason(for: network) { outcome = .notChecked(reason) }
        }

        public mutating func apply(_ event: Event) {
            guard !outcome.isFinal else { return }
            switch event {
            case .message(let message):
                apply(message)
            case .timedOut:
                // A page that never said it started is a web app that predates the check: no line, not a failure.
                outcome = hasStarted ? .notChecked(.didNotFinish) : .gone
            case .processEnded, .enteredBackground:
                outcome = .notChecked(.didNotFinish)
            }
        }

        private mutating func apply(_ message: Message) {
            switch message {
            case .started:
                hasStarted = true
            case .plays:
                outcome = .plays
            case .cannot(let reason), .linkDidNotOpen(let reason):
                outcome = .problem(reason)
            case .unverifiedPostVoice:
                outcome = .notChecked(.postVoiceNotLookedUp)
            case .couldNotReach(let offline):
                outcome = .notChecked(offline ? .offline : .didNotFinish)
            }
        }
    }

    // MARK: - Which link is checked

    /// One check runs at a time. A newer link waits behind the running check and replaces any older link still
    /// waiting, so the line always describes the link the screen shows now. Results stay in memory for the session,
    /// keyed by link id, so sharing the same link again checks nothing again. Only a result that could change is
    /// asked for again (`Outcome.isWorthRetrying`): an offline phone that comes back online checks the link then.
    public struct Queue: Equatable, Sendable {
        public private(set) var running: String?
        public private(set) var waiting: String?
        public private(set) var sessions: [String: Session] = [:]

        public init() {}

        public enum Request: Equatable, Sendable {
            /// Start this link's check now.
            case start
            /// It waits behind the running check. `replaced` is an older link that was waiting and will not be checked.
            case wait(replaced: String?)
            /// This link already has a result, or is already running or waiting.
            case alreadyKnown
        }

        public mutating func request(linkID: String, network: Network) -> Request {
            if running == linkID || waiting == linkID { return .alreadyKnown }
            if let known = sessions[linkID], !known.outcome.isWorthRetrying { return .alreadyKnown }
            if ShareLinkPlayCheck.skipReason(for: network) != nil {
                sessions[linkID] = Session(skippedFor: network)
                return .alreadyKnown
            }
            sessions[linkID] = Session()
            guard running != nil else {
                running = linkID
                return .start
            }
            let replaced = waiting
            if let replaced { sessions[replaced] = nil }
            waiting = linkID
            return .wait(replaced: replaced)
        }

        /// The outcome for a link, or nil when it was never asked for or was replaced while waiting.
        public func outcome(for linkID: String) -> Outcome? { sessions[linkID]?.outcome }

        /// Applies an event to the running check. Returns the link whose check should start next, when this event
        /// ended the running one.
        @discardableResult
        public mutating func apply(_ event: Event, to linkID: String) -> String? {
            // Only the running check takes events: a waiting link has no web view yet, so a stray event can't end it early.
            guard running == linkID else { return nil }
            sessions[linkID]?.apply(event)
            guard sessions[linkID]?.outcome.isFinal == true else { return nil }
            running = waiting
            waiting = nil
            return running
        }

        /// A waiting check has no web view yet, so going to the background ends it the same way as a running one.
        @discardableResult
        public mutating func enteredBackground() -> String? {
            if let waiting { sessions[waiting]?.apply(.enteredBackground) }
            waiting = nil
            guard let running else { return nil }
            return apply(.enteredBackground, to: running)
        }
    }
}
