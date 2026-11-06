import Foundation
import SessionKit
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif

extension WrittenMarginVoice {
    /// Whether a voice on this phone can read all of a note: the answer `voice(forNote:)` gives at render time, without
    /// rendering or guessing a language. `hasVoice` is asked about the languages in `coverage` only. A Latin-only note
    /// goes to the default voice, which is taken to be there, so it costs no voice lookup at all.
    public static func canRead(note words: String, hasVoice: (String) -> Bool) -> Bool {
        canRead(scripts: nonLatinScripts(in: WrittenMarginSpeech.speakable(words)), hasVoice: hasVoice)
    }

    static func canRead(scripts: Set<Script>, hasVoice: (String) -> Bool) -> Bool {
        scripts.isEmpty || coverage.contains { scripts.isSubset(of: $0.scripts) && hasVoice($0.language) }
    }
}

/// Which notes this phone's voices can read, answered from memory, because rows ask as they draw (#3402). The count of new
/// Margins and the offer use it through `WrittenMarginSpeech.hasVoice`, so a note no voice here can read is not offered
/// and doesn't wait as new. Nothing is stored: a voice downloaded later makes the note new and offered again.
///
/// The voices are looked up once off the main thread, and only when a note in a non-Latin script first asks: a Library of
/// English notes never touches the voice API. Until the lookup lands the answer is yes, which is what the app did before
/// this; `onChange` then brings the screens up to date. They are looked up again when iOS says the voices changed, and
/// on each return to the foreground, since a download in Settings can finish while the app is suspended.
public final class WrittenMarginVoiceCoverage: @unchecked Sendable {
    public static let shared = WrittenMarginVoiceCoverage(findVoices: WrittenMarginVoiceCoverage.installedLanguages)

    private let findVoices: @Sendable () -> Set<String>
    private let lock = NSLock()
    private var installed: Set<String>? // nil until a note in a non-Latin script has asked
    private var isLooking = false
    private var onChange: (@Sendable () -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let scripts = NSCache<NSString, Scripts>() // NSCache is thread-safe

    private final class Scripts {
        let value: Set<WrittenMarginVoice.Script>
        init(_ value: Set<WrittenMarginVoice.Script>) { self.value = value }
    }

    init(findVoices: @escaping @Sendable () -> Set<String>) {
        self.findVoices = findVoices
    }

    /// Makes this the phone's answer to `WrittenMarginSpeech.hasVoice`. `onChange` runs, on no particular thread, when a
    /// lookup changes what the screens were told.
    public func install(onChange: @escaping @Sendable () -> Void) {
        telling(onChange)
        WrittenMarginSpeech.useVoiceCheck { [self] in canRead($0) }
        #if canImport(UIKit)
        let names = [AVSpeechSynthesizer.availableVoicesDidChangeNotification, UIApplication.didBecomeActiveNotification]
        let added = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.lookAgainIfAsked() }
        }
        lock.withLock { observers += added }
        #endif
    }

    func telling(_ onChange: @escaping @Sendable () -> Void) {
        lock.withLock { self.onChange = onChange }
    }

    /// The answer for a note. Never blocks: a look-up in memory, once its scripts are known.
    func canRead(_ words: String) -> Bool {
        let needed = scripts(of: words)
        guard !needed.isEmpty else { return true }
        // A script no voice language covers has its answer without asking which voices are here.
        guard WrittenMarginVoice.canRead(scripts: needed, hasVoice: { _ in true }) else { return false }
        let known = lock.withLock { () -> Set<String>? in
            if installed == nil, !isLooking {
                isLooking = true
                DispatchQueue.global(qos: .utility).async { [self] in lookUp() }
            }
            return installed
        }
        guard let known else { return true }
        return WrittenMarginVoice.canRead(scripts: needed, hasVoice: known.contains)
    }

    private func scripts(of words: String) -> Set<WrittenMarginVoice.Script> {
        let key = words as NSString
        if let known = scripts.object(forKey: key) { return known.value }
        let found = WrittenMarginVoice.nonLatinScripts(in: WrittenMarginSpeech.speakable(words))
        scripts.setObject(Scripts(found), forKey: key)
        return found
    }

    private func lookAgainIfAsked() {
        let due = lock.withLock { () -> Bool in
            guard installed != nil, !isLooking else { return false }
            isLooking = true
            return true
        }
        if due { DispatchQueue.global(qos: .utility).async { [self] in lookUp() } }
    }

    /// Runs the lookup here and now. Called off the main thread, and directly by a test.
    func lookUp() {
        let found = findVoices()
        let (changed, notify) = lock.withLock { () -> (Bool, (@Sendable () -> Void)?) in
            // Before the first lookup the screens were told every language has a voice.
            let told = installed ?? Set(WrittenMarginVoice.coverage.map(\.language))
            installed = found
            isLooking = false
            return (told != found, onChange)
        }
        if changed { notify?() }
    }

    /// The languages in `WrittenMarginVoice.coverage` that have a voice here, found the way the render finds one
    /// (`WrittenMarginReader.installedVoice`); `WrittenMarginVoiceCoverageTests` holds the two together.
    static func installedLanguages() -> Set<String> {
        #if canImport(AVFoundation)
        Set(WrittenMarginVoice.coverage.map(\.language).filter { code in
            let wanted = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][code] ?? code
            if AVSpeechSynthesisVoice(language: wanted) != nil { return true }
            let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
            return AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix(base) }
        })
        #else
        []
        #endif
    }
}
