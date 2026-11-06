import Foundation
import WatchKit

/// The Watch's side of its own diagnostics record (#3506): where the file lives and the few places the app writes to
/// it. The format and the rules are `WatchDiagnosticsLog` (host-tested in SessionKit).
///
/// The cost is one small file rewrite (a few kilobytes) at launch, at a failure and when the app comes to the front
/// or goes to the background, and none when nothing changed. No timers, no sensors.
enum WatchDiagnostics {
    static let recorder = WatchDiagnosticsRecorder(fileURL: fileURL)

    private static var fileURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return support.appending(path: "WatchDiagnostics.json")
    }

    /// First thing at launch: records how the last run ended and that this one began, and notes an Objective-C
    /// exception by name if one reaches the top.
    @MainActor
    static func launched() {
        let inFront = WKApplication.shared().applicationState != .background
        recorder.update { $0.launched(at: Date(), inFront: inFront) }
    }

    /// Notes an Objective-C exception by name. Not main-actor: the handler can run on any thread.
    static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            WatchDiagnostics.recorder.update { $0.uncaughtException(name: exception.name.rawValue, at: Date()) }
        }
    }

    static func becameActive() {
        recorder.update { $0.becameActive(at: Date()) }
    }

    static func wentToBackground() {
        recorder.update { $0.wentToBackground() }
    }

    static func failed(_ what: String, error: Error? = nil) {
        let detail = error.map { WatchDiagnosticsLog.errorCode($0) } ?? ""
        recorder.update { $0.failed(what, detail: detail, at: Date()) }
    }

    /// The report to hand to the phone, or nil when it holds nothing new. Call `didSend(_:)` with it once handed over.
    @MainActor
    static func reportIfDue() -> WatchDiagnosticsReport? {
        let log = recorder.load()
        guard log.hasUnsent else { return nil }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let os = WKInterfaceDevice.current().systemVersion
        return log.report(build: build, osVersion: os, at: Date())
    }

    static func didSend(_ report: WatchDiagnosticsReport) {
        guard let last = report.events.last?.number else { return }
        recorder.update { $0.markSent(through: last) }
    }
}
