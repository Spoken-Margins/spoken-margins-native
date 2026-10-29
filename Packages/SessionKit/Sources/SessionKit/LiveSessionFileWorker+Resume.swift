import Foundation

/// Resume from the phone (#2883): the Lock Screen card, the Live row and the session screen all reopen an ended
/// session by the Watch's rules (`LiveSessionWatchSessions.resume`: ten minutes from the tap on End, refused once
/// another named session has started), and the Watch hears of it on the next board.
extension LiveSessionFileWorker {
    /// A Resume the listener asked for, at the moment they asked. A request from the Lock Screen waits in the App
    /// Group until the app reads it, so the window is judged at `at`, not at the later time the app gets to it.
    public struct ResumeRequest: Equatable, Sendable {
        public var sessionId: String
        public var at: Date

        public init(sessionId: String, at: Date) {
            self.sessionId = sessionId
            self.at = at
        }
    }

    public struct ResumeResult: Equatable, Sendable {
        /// The sessions that run again, as stored.
        public var resumed: [LiveSession] = []
        /// Sessions whose Resume is not allowed any more (the window passed, another session started, or it was saved
        /// or discarded): whatever offered Resume for them should go.
        public var refused: [String] = []

        public init(resumed: [LiveSession] = [], refused: [String] = []) {
            self.resumed = resumed
            self.refused = refused
        }
    }

    /// Reopens one session. Nil when Resume is not allowed.
    public func resume(id: String, at: Date = Date()) -> LiveSession? {
        applyResumes([ResumeRequest(sessionId: id, at: at)]).resumed.first
    }

    /// Applies Resumes in the order they were asked. Asking again for a session that already runs changes nothing.
    public func applyResumes(_ requests: [ResumeRequest]) -> ResumeResult {
        var result = ResumeResult()
        for request in requests.sorted(by: { ($0.at, $0.sessionId) < ($1.at, $1.sessionId) }) {
            let all = sessions()
            if let resumed = LiveSessionWatchSessions.resume(id: request.sessionId, at: request.at, sessions: all) {
                if let before = all[resumed.id] { noteUnseen(from: before, to: resumed) }
                unseenLifecycle[resumed.id] = Lifecycle(resumed)
                try? persist([resumed])
                result.resumed.removeAll { $0.id == resumed.id }
                result.resumed.append(resumed)
                result.refused.removeAll { $0 == resumed.id }
            } else if !(all[request.sessionId].map(LiveSessionWatchSessions.isRunningNamed) ?? false),
                      !result.refused.contains(request.sessionId) {
                result.refused.append(request.sessionId)
            }
        }
        return result
    }
}
