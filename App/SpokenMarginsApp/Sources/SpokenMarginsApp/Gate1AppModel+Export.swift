import Foundation
import SessionKit
import SessionKitPersistence
#if canImport(UIKit)
import UIKit
#endif

/// Session export, batch export and copying. Moved out of `Gate1AppModel.swift` unchanged (#983).
extension Gate1AppModel {
    var displayedExportPreview: String {
        guard exportPreview.count > Self.exportPreviewCharacterLimit else { return exportPreview }
        return String(exportPreview.prefix(Self.exportPreviewCharacterLimit))
            + "\n\n… Preview truncated. Copy or Share uses the complete export."
    }

    var exportPreviewIsTruncated: Bool {
        exportPreview.count > Self.exportPreviewCharacterLimit
    }

    var exportPreviewSizeDescription: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(exportPreview.utf8.count),
            countStyle: .file
        )
    }

    @discardableResult
    func buildExport() -> Task<Void, Never>? {
        refreshExportPreview(reportStatus: true)
    }

    @discardableResult
    func exportOptionsChanged() -> Task<Void, Never>? {
        persistExportSettings()
        return refreshExportPreview(reportStatus: false)
    }

    /// Builds the Export screen's preview with its store reads off the main thread (#2505): a podcast's transcript
    /// timeline and Listening Map run to megabytes, and every switch on the screen asked for them again. The share
    /// candidates stay a quick read here. A preview that arrives after the listener picked another session, option
    /// or format is dropped, so an older, slower build never replaces a newer one. The old preview goes at
    /// once, before the new build starts: Share and Copy read it, and until the new build lands they would send an
    /// export the listener has already changed (text they turned off, another format, another session). With the
    /// preview empty the Export button is hidden, Copy is disabled and the screen says "No export yet." (the audit
    /// of #3049). `exportFileURL` stays until the build lands only so that it can delete that file in its turn; the
    /// screen offers it only while a preview exists. The returned task is for tests.
    @discardableResult
    func refreshExportPreview(reportStatus: Bool) -> Task<Void, Never>? {
        exportShareCandidates = []
        exportPreview = ""
        guard let exportSessionId else {
            exportFileURL = nil
            return nil
        }
        var exportEngine: SessionEngine?
        run { engine in
            let store = try requireStore()
            exportShareCandidates = try store.loadInterjections(sessionId: exportSessionId)
                .filter { $0.status == "active" && $0.targetType == .item }
            exportEngine = engine
        }
        guard let engine = exportEngine else { return nil }
        let options = currentExportOptions(), format = exportFormat
        return Task { [weak self] in
            let built: Result<SessionExport, Error>
            do { built = .success(try await engine.buildExportReadingOffMain(options: options)) } catch { built = .failure(error) }
            guard let self, currentExportOptions() == options, exportFormat == format else { return }
            hangTelemetry.labels.scoped("exportPreview.publish") {
                do {
                    let export = try built.get()
                    exportPreview = try renderExport(export)
                    exportFileURL = format == "markdown"
                        ? try prepareIndividualMarkdownExportFile(markdown: exportPreview, export: export)
                        : nil
                    if reportStatus {
                        reportSuccess("Built session export.")
                    }
                } catch {
                    reportFailure(error)
                }
            }
        }
    }

    func copyPlainTextExport() {
        guard !exportPreview.isEmpty else {
            reportFailure("No export text is available yet.")
            return
        }
        #if canImport(UIKit)
        UIPasteboard.general.string = exportPreview
        recordSessionExported()
        reportConfirmation("Copied \(exportFormat == "json" ? "JSON" : "Markdown") export.")
        #else
        reportFailure("Clipboard is unavailable on this platform.")
        #endif
    }

    /// Sets only the Export Sessions folder. It must not touch the notes folder or its destination ID,
    /// or the notes feature copies every Margin into the folder picked for an export (#930).
    func configureBatchExportFolder(url: URL) {
        do {
            try SavedFolderSetting.sessionExport.save(folder: url)
            batchExportFolderName = url.lastPathComponent
            batchExportResult = nil
            reportSuccess("Export folder set to \(url.lastPathComponent).")
        } catch {
            reportFailure(error, context: "Export folder setup failed")
        }
    }

    func reportBatchExportFolderFailure(_ error: Error) {
        reportFailure(error, context: "Export folder selection failed")
    }

    /// Builds one Markdown file per selected session in a temporary folder and hands them to the system share
    /// sheet (#1528). Nothing is written to a remembered folder, and nothing is called "shared" until the
    /// sheet reports a completed share.
    ///
    /// Each session's store reads and the file writes run off the main actor (#2510, #2256): only the shaping of
    /// one export and the final hand-off to the sheet happen here, so the tap returns at once. The button is
    /// disabled while the files are built (`isPreparingBatchShare`). Leaving the screen first drops the result.
    @discardableResult
    func prepareSelectedSessionsForSharing() -> Task<Void, Never>? {
        guard batchExportShare == nil, !isPreparingBatchShare else { return nil }
        guard !selectedBatchExportSessionIds.isEmpty else {
            reportFailure("Choose at least one session to export.")
            return nil
        }
        let engine: SessionEngine
        do {
            if self.engine == nil {
                let store = try requireStore()
                installEngine(try makeEngine(store: store))
            }
            guard let installed = self.engine else {
                reportFailure("Session export is unavailable.")
                return nil
            }
            engine = installed
        } catch {
            reportFailure(error, context: "Batch export failed")
            return nil
        }
        persistExportSettings()
        let sources = batchExportRows.filter { selectedBatchExportSessionIds.contains($0.id) }.map {
            SessionShareFiles.Source(sessionId: $0.id, itemTitle: $0.itemTitle,
                                     sessionDate: $0.session.createdAt ?? $0.session.updatedAt)
        }
        // The options are read once, before the first suspension, so a toggle changed mid-build can't mix into this share.
        let options = currentExportOptions(sessionId: nil)
        let startedOn = screen
        isPreparingBatchShare = true
        let buildID = UUID()
        let task = Task { @MainActor [weak self] in
            let files = await SessionShareFiles.buildOffMain(sources, root: SessionShareFiles.shareRoot()) { source in
                var sessionOptions = options
                sessionOptions.sessionId = source.sessionId
                return SessionExportMarkdownRenderer.render(try await engine.buildExportReadingOffMain(options: sessionOptions))
            }
            guard let self else {
                Self.discardOffMain(files)
                return
            }
            // Export Sessions was opened again meanwhile (`openBatchExport` cleared this build): its files are not wanted.
            guard batchExportPrepare?.id == buildID else {
                Self.discardOffMain(files)
                return
            }
            hangTelemetry.labels.scoped("batchExport.publish") {
                batchExportPrepare = nil
                isPreparingBatchShare = false
                // The listener left Export Sessions while the files were built: nothing is waiting for the sheet.
                guard screen == startedOn else {
                    Self.discardOffMain(files)
                    return
                }
                batchExportResult = files.failures.isEmpty ? nil
                    : BatchSessionExportResult(sharedFileNames: [], failures: files.failures, activityType: nil)
                diagnostics["batchExportLastResult"] = "prepared=\(files.fileURLs.count);failed=\(files.failures.count)"
                guard !files.fileURLs.isEmpty else {
                    reportFailure("No sessions could be prepared. Review the export result for details.")
                    return
                }
                batchExportShare = files
            }
        }
        batchExportPrepare = (buildID, task)
        return task
    }

    /// Removes a share's folder away from the main actor; nothing waits for it.
    private nonisolated static func discardOffMain(_ files: SessionShareFiles) {
        Task.detached(priority: .utility) { files.discard() }
    }

    /// The share sheet reported its outcome (`completed` is false when the listener cancelled). Removes the
    /// temporary files either way; only a completed share is reported and marks the onboarding step.
    func batchShareSheetFinished(completed: Bool, activityType: String?) {
        guard let files = batchExportShare else { return }
        batchExportShare = nil
        files.discard()
        guard completed else {
            diagnostics["batchExportLastResult"] = "share_cancelled;prepared=\(files.fileURLs.count)"
            return
        }
        batchExportResult = BatchSessionExportResult(sharedFileNames: files.fileURLs.map(\.lastPathComponent),
                                                     failures: files.failures, activityType: activityType)
        markOnboardingSteps([.exportedSession])
        diagnostics["batchExportLastResult"] = "shared=\(files.fileURLs.count);failed=\(files.failures.count)"
        reportConfirmation(SessionShareFiles.sharedSummary(count: files.fileURLs.count, activityType: activityType))
    }

    /// The sheet closed. iOS may report the outcome just after the close, so give it a moment before
    /// treating the sheet as cancelled.
    func batchShareSheetDismissed() {
        // Only the share that was open when the sheet closed: a newer share must not be cleared by this one.
        guard let closing = batchExportShare?.directory else { return }
        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard batchExportShare?.directory == closing else { return }
            batchShareSheetFinished(completed: false, activityType: nil)
        }
    }

    func copyTargetInterjections(targetType: String, targetId: String, format: String = "markdown") {
        run { engine in
            let export = try engine.buildExport(options: ExportOptions(
                sessionId: snapshot.sessionId,
                includeFullText: false,
                includeReference: true,
                includeListeningMap: false,
                includeInterjections: true,
                // Timeline-level note copying is intentionally compact. Full AI
                // responses belong to the configurable Export screen; this path
                // carries only the selected notes and their bounded anchors.
                includeTurns: false,
                scope: "target",
                targetType: targetType,
                targetId: targetId
            ))
            guard !export.interjections.isEmpty else {
                reportFailure("No Margins are available for that target.")
                return
            }
            let text = try renderExport(export, format: format)
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportConfirmation("Copied target Margins.")
            #else
            exportPreview = text
            reportSuccess("Built target Margin export.")
            #endif
        }
    }

    func copyInterjectionWithContext(_ interjection: Interjection, format: String = "markdown") {
        run { engine in
            let export = try engine.buildExport(options: ExportOptions(
                sessionId: interjection.sessionId,
                includeFullText: false,
                includeReference: true,
                includeListeningMap: false,
                includeInterjections: true,
                includeTurns: false,
                scope: "selected_interjections",
                interjectionIds: [interjection.id]
            ))
            let text = try renderExport(export, format: format)
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            reportConfirmation("Copied Margin with its context.")
            #else
            exportPreview = text
            reportSuccess("Built Margin export.")
            #endif
        }
    }

    private func persistExportSettings() {
        UserDefaults.standard.set(exportFormat, forKey: "exportFormat")
        UserDefaults.standard.set(exportScope, forKey: "exportScope")
        UserDefaults.standard.set(exportIncludesSourceText, forKey: "exportIncludesSourceText")
        UserDefaults.standard.set(exportIncludesReference, forKey: "exportIncludesReference")
        UserDefaults.standard.set(exportIncludesListeningMap, forKey: "exportIncludesListeningMap")
        UserDefaults.standard.set(exportIncludesInterjections, forKey: "exportIncludesInterjections")
        UserDefaults.standard.set(exportIncludesTurns, forKey: "exportIncludesTurns")
    }

    private func currentExportOptions() -> ExportOptions {
        currentExportOptions(sessionId: exportSessionId)
    }

    private func currentExportOptions(sessionId: String?) -> ExportOptions {
        ExportOptions(
            sessionId: sessionId,
            includeFullText: exportIncludesSourceText,
            includeReference: exportIncludesReference,
            includeListeningMap: exportIncludesListeningMap,
            includeInterjections: exportIncludesInterjections,
            includeTurns: exportIncludesTurns,
            scope: exportScope
        )
    }

    private func renderExport(_ export: SessionExport, format: String? = nil) throws -> String {
        if (format ?? exportFormat) == "json" {
            let data = try encoder.encode(export)
            return String(data: data, encoding: .utf8) ?? ""
        }
        return SessionExportMarkdownRenderer.render(export)
    }

    private func prepareIndividualMarkdownExportFile(markdown: String, export: SessionExport) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpokenMarginsSessionShare", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let exportFileURL, exportFileURL.deletingLastPathComponent() == directory {
            try? FileManager.default.removeItem(at: exportFileURL)
        }
        let session = try store?.loadSession(id: export.session.id)
        return try SessionMarkdownFileWriter().write(
            markdown: markdown,
            itemTitle: export.item.title,
            sessionDate: session?.createdAt ?? session?.updatedAt,
            sessionId: export.session.id,
            to: directory
        )
    }
}
