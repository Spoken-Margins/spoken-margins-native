import Foundation
import SessionKit
import SessionKitAudio

/// The event "first Margin heard" and the one-time migration behind it (#4711). Nothing reads either yet; #4713, #4714
/// and #4672 do. The rules are `FirstRunHistory` and `OnboardingProgress.marginHeard`, host-tested in SessionKit.
extension Gate1AppModel {
    static let firstRunEntryKey = "firstRunEntryV1"
    static let heardFirstMarginMigrationKey = "heardFirstMarginMigrationV1"

    /// Runs once per install, at the launch's first read of the Library and before any seeding: a fresh install is
    /// empty only at that moment.
    func runHeardFirstMarginMigration(libraryWasEmptyAtLaunch: Bool) {
        let defaults = UserDefaults.standard
        let ranBefore = FirstRunHistory.hasRunBefore(
            storedWelcomeSampleVersion: defaults.integer(forKey: Self.welcomeSampleSeedVersionKey),
            storedSteps: defaults.stringArray(forKey: Self.onboardingStepsKey),
            termsAcceptedVersion: SpokenMarginsTerms.acceptedVersion(in: defaults),
            welcomeTombstoned: false // #4714 adds the tombstone
        )
        let migration = FirstRunHistory.migration(
            alreadyRan: defaults.bool(forKey: Self.heardFirstMarginMigrationKey),
            libraryWasEmptyAtLaunch: libraryWasEmptyAtLaunch,
            hasRunBefore: ranBefore
        )
        switch migration {
        case .nothing:
            return
        case .markHeard:
            markOnboardingSteps([.heardFirstMargin])
            diagnostics["firstRunMigration"] = "mark_heard"
        case .freshInstall:
            defaults.set(FirstRunEntry.coldInstall.rawValue, forKey: Self.firstRunEntryKey)
            diagnostics["firstRunMigration"] = "fresh_install"
        }
        defaults.set(true, forKey: Self.heardFirstMarginMigrationKey)
    }

    /// How this install's first run began, while it is still stored.
    var firstRunEntry: FirstRunEntry? {
        UserDefaults.standard.string(forKey: Self.firstRunEntryKey).flatMap(FirstRunEntry.init(rawValue:))
    }

    /// Reports a hearing to the rule and, the first time it fires, records the entry in Diagnostics.
    func noteMarginHeard(_ hearing: MarginHearing) {
        var fired = false
        changeOnboardingProgress { progress in
            let change = progress.marginHeard(hearing)
            fired = change.contains(.steps)
            return change
        }
        if fired { diagnostics["firstMarginHeard"] = firstRunEntry?.rawValue ?? "unknown" }
    }

    /// The conductor's audio-session, unavailable and voice-ended callbacks, moved out of `startMarginMoment` (hot-file ratchet).
    func configureMarginMomentCallbacks(_ conductor: MarginMomentConductor, itemId: String) {
        conductor.prepareAudioSession = { [weak self] in try self?.prepareMarginMomentVoice() }
        conductor.onVoiceEnded = { [weak self] margin, reachedEnd in
            self?.marginMomentVoiceEnded(margin, itemId: itemId, reachedEnd: reachedEnd)
        }
        conductor.onVoiceUnavailable = { [weak self] (marginId: String, reason: String) in
            self?.diagnostics["marginMoment.voiceUnavailable"] = "\(marginId):\(reason)"
            self?.reportWarning("That Margin's recording couldn't play, so listening continues.")
        }
    }

    /// The Margin-moment player stopped a voice. Whose Margin it was comes from the store: an own spoken Margin of the
    /// item, never the card's label. Its one row is read off the main thread (#2256); only the hearing is noted here.
    func marginMomentVoiceEnded(_ margin: MarginMomentAnchor, itemId: String, reachedEnd: Bool) {
        hearItLandVoiceEnded(margin.marginId)
        guard let store else { return }
        Task { [weak self] in
            let heard = try? await Self.offMain { MarginHearing.spokenVoiceEnded(marginIdentity: margin.marginId, itemId: itemId, reachedEnd: reachedEnd, repository: store) }
            if let heard { self?.noteMarginHeard(heard) }
        }
    }
}
