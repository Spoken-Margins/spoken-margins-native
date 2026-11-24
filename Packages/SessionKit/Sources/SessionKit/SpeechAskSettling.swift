import Foundation

/// #4715: when held transcription work leaves the speech ask's books. Pure, so the order is host-tested; the app's
/// `SpeechAskController` carries it out.
public enum SpeechAskSettling {
    /// The waiting list once the retries of `settled` were scheduled (or found no longer due, a Margin deleted while it
    /// waited). Only those leave it: a Margin added while the retries were read stays for the next settle, and a list
    /// nothing retried (no Library open yet) is kept whole, so Allow never drops a Margin it did not transcribe.
    public static func waiting(_ list: SpeechAskWaitingList, afterSettling settled: [String]) -> SpeechAskWaitingList {
        let done = Set(settled)
        return SpeechAskWaitingList(stored: list.ids.filter { !done.contains($0) })
    }

    /// Whether held work is settled the moment it is reported. A hold met while iOS was undecided can be reported after
    /// the listener answered (the gate's report hops to the main actor), when that answer has already been settled: it
    /// is settled at once then, retried on Allow and dropped on a no, rather than left until the app next comes forward.
    public static func settlesOnReport(access: SpeechRecognitionAccessState) -> Bool {
        access != .notDetermined
    }
}
