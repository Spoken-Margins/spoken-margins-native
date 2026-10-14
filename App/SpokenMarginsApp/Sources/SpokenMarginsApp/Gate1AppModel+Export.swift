import Foundation
import SessionKit
import SessionKitPersistence
#if canImport(UIKit)
import UIKit
#endif

/// Session export, batch export and copying. Moved out of `Gate1AppModel.swift` unchanged (#983).
extension Gate1AppModel {
    func buildExport() {
        refreshExportPreview(reportStatus: true)
    }

    func exportOptionsChanged() {
        persistExportSettings()
        refreshExportPreview(reportStatus: false)
    }

    func refreshExportPreview(reportStatus: Bool) {
        exportShareCandidates = []
        guard let exportSessionId else {
            exportPreview = ""
            exportFileURL = nil
            return
        }
        run { engine in
            let store = try requireStore()
            exportShareCandidates = try store.loadInterjections(sessionId: exportSessionId)
                .filter { $0.status == "active" && $0.targetType == .item }
            let export = try engine.buildExport(options: currentExportOptions())
            exportPreview = try renderExport(export)
            exportFileURL = exportFormat == "markdown"
                ? try prepareIndividualMarkdownExportFile(markdown: exportPreview, export: export)
                : nil
            screen = .export
            if reportStatus {
                reportSuccess("Built session export.")
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

    func exportSelectedSessionsToFolder() {
        guard !selectedBatchExportSessionIds.isEmpty else {
            reportFailure("Choose at least one session to export.")
            return
        }
        guard let folderURL = resolvedFolderURL(.sessionExport) else {
            reportFailure("Choose an export folder first.")
            return
        }
        do {
            if engine == nil {
                let store = try requireStore()
                installEngine(try makeEngine(store: store))
            }
            guard let engine else {
                reportFailure("Session export is unavailable.")
                return
            }

            persistExportSettings()
            isWritingBatchExport = true
            defer { isWritingBatchExport = false }

            let didAccess = folderURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    folderURL.stopAccessingSecurityScopedResource()
                }
            }

            let writer = SessionMarkdownFileWriter()
            let selectedRows = batchExportRows.filter { selectedBatchExportSessionIds.contains($0.id) }
            var exportedFileNames: [String] = []
            var failures: [String] = []
            for row in selectedRows {
                do {
                    let export = try engine.buildExport(options: currentExportOptions(sessionId: row.id))
                    let markdown = SessionExportMarkdownRenderer.render(export)
                    let fileURL = try writer.write(
                        markdown: markdown,
                        itemTitle: row.itemTitle,
                        sessionDate: row.session.createdAt ?? row.session.updatedAt,
                        sessionId: row.id,
                        to: folderURL
                    )
                    exportedFileNames.append(fileURL.lastPathComponent)
                } catch {
                    failures.append("\(row.itemTitle): \(error.localizedDescription)")
                }
            }

            batchExportResult = BatchSessionExportResult(
                exportedFileNames: exportedFileNames,
                failures: failures,
                destinationName: folderURL.lastPathComponent
            )
            if !exportedFileNames.isEmpty {
                markOnboardingSteps([.exportedSession])
            }
            diagnostics["batchExportLastResult"] = "exported=\(exportedFileNames.count);failed=\(failures.count)"
            if failures.isEmpty {
                reportConfirmation("Exported \(exportedFileNames.count) Markdown file\(exportedFileNames.count == 1 ? "" : "s") to \(folderURL.lastPathComponent).")
            } else if exportedFileNames.isEmpty {
                reportFailure("No sessions were exported. Review the export result for details.")
            } else {
                reportFailure("Exported \(exportedFileNames.count) session\(exportedFileNames.count == 1 ? "" : "s"); \(failures.count) failed.")
            }
        } catch {
            isWritingBatchExport = false
            reportFailure(error, context: "Batch export failed")
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
            reportConfirmation("Copied Margin with its anchors.")
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
