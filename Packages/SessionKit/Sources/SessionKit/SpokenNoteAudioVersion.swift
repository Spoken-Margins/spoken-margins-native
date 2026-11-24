import Foundation

/// Which recording of a spoken note plays (#4779): the takes as recorded, or the version with long pauses shortened.
/// One choice for the whole app, kept in UserDefaults, As recorded unless the listener changes it.
public enum SpokenNoteAudioVersion: String, CaseIterable, Codable, Equatable, Sendable {
    case asRecorded = "as_recorded"
    case shorterPauses = "shorter_pauses"

    public static let defaultsKey = "spokenNoteAudioVersion"

    public static func stored(in defaults: UserDefaults = .standard) -> SpokenNoteAudioVersion {
        defaults.string(forKey: defaultsKey).flatMap(SpokenNoteAudioVersion.init(rawValue:)) ?? .asRecorded
    }

    public func store(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// The note's two clocks, read from its files: the recording's layout beside the takes, and the version's layout in
/// `clean/`. Margin times are always saved on the recording's clock, whichever version plays (#4779), so every place
/// that turns a playing time into a saved one, or back, asks here. A media URL that isn't a note's version plays on the
/// recording's clock and is passed through unchanged.
public enum SpokenNoteCleanClock {
    /// The map between the recording and its version, when the version is made from exactly the recording's takes and
    /// has an audio file.
    public static func map(inNoteFolder folder: URL, recorded: SpokenNoteWholeAudioLayout) -> SpokenNoteCleanMap? {
        guard let clean = SpokenNoteCleanFiles.readLayout(inNoteFolder: folder), clean.isCurrent(for: recorded.requested),
              clean.result.hasAudio, isRegularCleanFile(SpokenNoteCleanFiles.audioURL(inNoteFolder: folder)) else { return nil }
        return SpokenNoteCleanMap(placements: clean.placements, recorded: recorded, cleanDurationMs: clean.durationMs)
    }

    /// The map for a media URL that names a note's version (`<note folder>/clean/whole-note.m4a`); nil otherwise.
    public static func map(forMediaURL mediaURL: String?) -> SpokenNoteCleanMap? {
        guard SpokenNoteCleanFiles.namesCleanAudio(mediaURL), let mediaURL else { return nil }
        let url = mediaURL.hasPrefix("/") ? URL(fileURLWithPath: mediaURL) : (URL(string: mediaURL) ?? URL(fileURLWithPath: mediaURL))
        let folder = url.deletingLastPathComponent().deletingLastPathComponent()
        return cache.map(for: folder)
    }

    /// A playing time on `mediaURL` as a time on the recording's clock.
    public static func recordedMs(playingMs: Int, mediaURL: String?) -> Int {
        map(forMediaURL: mediaURL)?.recordedMs(fromCleanMs: playingMs) ?? playingMs
    }

    /// A time on the recording's clock as a playing time on `mediaURL`.
    public static func playingMs(recordedMs: Int, mediaURL: String?) -> Int {
        map(forMediaURL: mediaURL)?.cleanMs(fromRecordedMs: recordedMs) ?? recordedMs
    }

    /// Margins with their saved times moved onto the clock of the file at `mediaURL`, for code that compares them with
    /// the playing position or seeks to them (a Margin moment, the Margins that follow it). Saved times stay on the
    /// recording's clock (#4779); this is the one place a list of them is read on the playing clock. Nothing changes,
    /// and no file is read, unless `mediaURL` names a note's Shorter pauses version.
    public static func onPlayingClock(_ margins: [Interjection], mediaURL: String?) -> [Interjection] {
        guard let map = map(forMediaURL: mediaURL) else { return margins }
        return margins.map { margin in
            var moved = margin
            moved.anchor.mediaTimeMs = margin.anchor.mediaTimeMs.map { map.cleanMs(fromRecordedMs: $0) }
            return moved
        }
    }

    /// Maps by note folder, made again when either layout file changes. Small: one entry a note played this launch.
    private static let cache = MapCache()

    private final class MapCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (stamp: String, map: SpokenNoteCleanMap?)] = [:]

        func map(for folder: URL) -> SpokenNoteCleanMap? {
            let stamp = Self.stamp(folder)
            lock.lock()
            if let entry = entries[folder.path], entry.stamp == stamp { lock.unlock(); return entry.map }
            lock.unlock()
            let made = SpokenNoteWholePlayback.recordedLayout(inFolder: folder).flatMap { SpokenNoteCleanClock.map(inNoteFolder: folder, recorded: $0) }
            lock.lock()
            entries[folder.path] = (stamp, made)
            lock.unlock()
            return made
        }

        private static func stamp(_ folder: URL) -> String {
            [folder.appendingPathComponent(SpokenNoteWholePlayback.layoutFileName), SpokenNoteCleanFiles.layoutURL(inNoteFolder: folder)]
                .map { url in
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let size = (attributes?[.size] as? NSNumber)?.intValue ?? -1
                    return "\(date)-\(size)"
                }
                .joined(separator: "|")
        }
    }
}

private func isRegularCleanFile(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
}

/// Where a version change starts the note (#4779): the same moment of the recording, on the other version's clock.
public enum SpokenNoteVersionPlan {
    /// - Parameters:
    ///   - playingMs: where the note is on the file now playing.
    ///   - fromMap: the map of the version now playing; nil when the recording plays.
    ///   - toMap: the map of the version to start; nil to start the recording.
    public static func startMs(playingMs: Int, fromMap: SpokenNoteCleanMap?, toMap: SpokenNoteCleanMap?) -> Int {
        let recorded = fromMap?.recordedMs(fromCleanMs: playingMs) ?? playingMs
        return max(0, toMap?.cleanMs(fromRecordedMs: recorded) ?? recorded)
    }
}

/// A move from one of a note's files to the other with both clocks already read (#4779). `plan` reads the note's layout
/// files, so it is made off the main thread; `startMs` is only arithmetic, so the main actor calls it at the moment of
/// the restart with the place playing then.
public struct SpokenNoteVersionSwitch: Equatable, Sendable {
    public let previousMediaURL: String?
    public let newMediaURL: String?
    let fromMap: SpokenNoteCleanMap?
    let toMap: SpokenNoteCleanMap?

    /// The move from `previousMediaURL` (the file attached before) to `newMediaURL` (the file Play just prepared), or nil
    /// when both name the same version (the session simply carries on). Reads files: never call it on the main thread.
    public static func plan(previousMediaURL: String?, newMediaURL: String?) -> SpokenNoteVersionSwitch? {
        guard SpokenNoteCleanFiles.namesCleanAudio(previousMediaURL) != SpokenNoteCleanFiles.namesCleanAudio(newMediaURL) else { return nil }
        return SpokenNoteVersionSwitch(
            previousMediaURL: previousMediaURL,
            newMediaURL: newMediaURL,
            fromMap: SpokenNoteCleanClock.map(forMediaURL: previousMediaURL),
            toMap: SpokenNoteCleanClock.map(forMediaURL: newMediaURL)
        )
    }

    /// Where the note starts on the new file for `playingMs` on the old one: the same moment of the recording.
    public func startMs(playingMs: Int) -> Int {
        SpokenNoteVersionPlan.startMs(playingMs: playingMs, fromMap: fromMap, toMap: toMap)
    }
}

extension SpokenNoteVersionPlan {
    /// Whether the open session's phase holds a version change: a Margin being recorded, summarised or played, or a
    /// conversation, each run on the session as it is. Playing the note, and a session that has ended or was never
    /// started, hold nothing; a finished session stays open and must not grey the choice out.
    public static func phaseHoldsVersionChange(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .recordingInterjection, .interjectionSummary, .summaryPlayback, .addendumCapture, .aiResponsePlayback, .conversation:
            return true
        case .idle, .itemPlayback, .finished, .abandoned:
            return false
        }
    }

    /// What a version change does with a Margin moment running on the note.
    public enum MarginMomentAction: Equatable, Sendable {
        /// No moment runs: nothing to do.
        case none
        /// A Margin's voice is playing: the change waits until it ends.
        case hold
        /// The moment plays the note or listens for its next Margin: it ends before the restart.
        case end
    }

    /// A moment's targets, lead-in and waiting Margins were put on the playing file's clock when it started, so it
    /// can't go on across a restart on the other file: a Margin voice playing holds the change, and a moment that is
    /// only playing the note or listening (which can last to the note's end) ends with the restart.
    public static func marginMomentAction(isRunning: Bool, isPlayingVoice: Bool) -> MarginMomentAction {
        guard isRunning else { return .none }
        return isPlayingVoice ? .hold : .end
    }

    /// The version an item's media URL plays.
    public static func attachedVersion(mediaURL: String?) -> SpokenNoteAudioVersion {
        SpokenNoteCleanFiles.namesCleanAudio(mediaURL) ? .shorterPauses : .asRecorded
    }
}
