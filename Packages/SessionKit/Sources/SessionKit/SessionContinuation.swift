import Foundation

public enum SessionContinuation {
    public static func isResumableSession(_ session: Session) -> Bool {
        session.status == "in_progress" && session.phase != .abandoned
    }

    public static func preferredContinuationSession(in sessions: [Session]) -> Session? {
        sessions.sorted { lhs, rhs in
            let left = lhs.updatedAt ?? lhs.createdAt ?? .distantPast
            let right = rhs.updatedAt ?? rhs.createdAt ?? .distantPast
            return left == right ? lhs.id < rhs.id : left > right
        }.first { session in
            isResumableSession(session)
                || (session.status == "finished" && session.completionPercent >= 100)
        }
    }
}
