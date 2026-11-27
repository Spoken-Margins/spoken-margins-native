import Foundation

/// When the phone may look for answers in its reply boxes (#4675, `docs/design/reply-mailbox.md` screen C, timing).
///
/// Only two things hold a check back: the Terms sheet is on screen (a banner must not land over it), and the listener
/// has not agreed to links that take answers (a box is made only after that agreement, so before it there is nothing
/// to collect). The on-device voice Terms are not a condition: they are only the bundled voice's licence. A sender who
/// shares a podcast never sees them, and one who picks "Use iOS Voice" declines them, and both make links whose answers
/// must still arrive (Test Desk real-use run on #5397, 2026-11-26).
public enum ReplyBoxCheckGate {
    public static func mayCheck(termsSheetShowing: Bool, agreedToLinksWithAnswers: Bool) -> Bool {
        !termsSheetShowing && agreedToLinksWithAnswers
    }
}
