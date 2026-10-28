import Foundation
import SessionKit

/// Import inbox presentation and ordered handoff drain. Moved out of `Gate1AppModel.swift` unchanged (#956).
extension Gate1AppModel {
    /// The handoff stores the extensions write to; tests inject their own (moved out of `Gate1AppModel.swift` for #1546).
    func resolvedSourceLinkHandoffStore() throws -> SourceLinkHandoffStore {
        if let sourceLinkHandoffStore {
            return sourceLinkHandoffStore
        }
        return try SourceLinkHandoffStore.appGroup()
    }

    func resolvedBrowserTextHandoffStore() throws -> Gate5BrowserTextHandoffStore {
        if let browserTextHandoffStore {
            return browserTextHandoffStore
        }
        return try Gate5BrowserTextHandoffStore.appGroup()
    }

    func refreshImportInbox() {
        var entries: [ImportInboxEntry] = []
        do {
            for failed in try resolvedSourceLinkHandoffStore().failedHandoffs() {
                entries.append(ImportInboxEntry(
                    id: "source:\(failed.id)",
                    payloadID: failed.id,
                    kind: .sourceLink,
                    title: "Podcast or audio link",
                    source: failed.handoff.inputURL,
                    reason: ImportInboxReason.plain(failed.reason)
                ))
            }
        } catch {
            diagnostics["sourceLinkImportInbox"] = "unavailable:\(error.localizedDescription)"
        }
        do {
            for failed in try resolvedBrowserTextHandoffStore().failedHandoffs() {
                entries.append(ImportInboxEntry(
                    id: "text:\(failed.id)",
                    payloadID: failed.id,
                    kind: .browserText,
                    title: failed.handoff.source.title,
                    source: failed.handoff.source.url,
                    reason: ImportInboxReason.plain(failed.reason)
                ))
            }
        } catch {
            diagnostics["browserTextImportInbox"] = "unavailable:\(error.localizedDescription)"
        }
        importInbox = entries
    }

    func retryImportInboxEntry(_ entry: ImportInboxEntry) {
        do {
            switch entry.kind {
            case .sourceLink:
                try resolvedSourceLinkHandoffStore().retryFailed(payloadID: entry.payloadID)
            case .browserText:
                try resolvedBrowserTextHandoffStore().retryFailed(payloadID: entry.payloadID)
            }
            importPendingSourceLinkHandoffs()
            reportConfirmation("Import retry queued.")
        } catch {
            reportFailure(error, context: "Import retry failed")
        }
    }

    func deleteImportInboxEntry(_ entry: ImportInboxEntry) {
        do {
            switch entry.kind {
            case .sourceLink:
                try resolvedSourceLinkHandoffStore().deleteFailed(payloadID: entry.payloadID)
            case .browserText:
                try resolvedBrowserTextHandoffStore().deleteFailed(payloadID: entry.payloadID)
            }
            refreshImportInbox()
            reportSuccess("Removed failed import.")
        } catch {
            reportFailure(error, context: "Import removal failed")
        }
    }

    func importPendingSourceLinkHandoffs() {
        Task { @MainActor in
            await importPendingHandoffsAsync()
        }
    }

    /// A `spokenmargins://source-link?payloadId=` open: checks the payload is still there off the main thread (the
    /// share extension wrote it into the shared folder), then lets the drain import it (#2510).
    func queueSourceLinkPayload(url: URL, payloadID: String) {
        Task { @MainActor in
            do {
                let handoffStore = try resolvedSourceLinkHandoffStore()
                _ = try await Self.offMain { try SourceLinkHandoffURL.handoff(from: url, store: handoffStore) }
                diagnostics["lastSourceLinkPayloadCleanup"] = "queued:\(payloadID)"
                hangTelemetry.labels.scoped("sourceLinkPayload.queue") { importPendingSourceLinkHandoffs() }
            } catch SourceLinkHandoffStoreError.missingPayload(let payloadID) {
                diagnostics["lastSourceLinkPayloadCleanup"] = "already_consumed:\(payloadID)"
            } catch {
                reportFailure(error, context: "Source link import failed")
            }
        }
    }

    /// A browser-text open with a payload id: reads and deletes the payload file off the main thread and imports
    /// the page on it (#2510).
    func importBrowserTextPayload(payloadID: String) {
        // Claimed now, before the first suspension, so a drain that starts at the same foreground skips it and
        // the share still opens its item (#1437).
        guard browserTextPayloadsInFlight.insert(payloadID).inserted else { return }
        Task { @MainActor in
            defer { browserTextPayloadsInFlight.remove(payloadID) }
            do {
                let handoffStore = try resolvedBrowserTextHandoffStore()
                let handoff = try await Self.offMain { try handoffStore.handoff(payloadID: payloadID) }
                // With something in Now Playing the import still shows its item and never touches playback (#1437).
                let hadSession = hasActiveSession
                let imported = hangTelemetry.labels.scoped("browserTextPayload.import") { importClippedPage(handoff) }
                if imported {
                    try? await Self.offMain { try handoffStore.deletePayload(payloadID: payloadID) }
                    if hadSession { diagnostics["lastBrowserTextPayloadCleanup"] = "imported_without_session_replacement" }
                }
            } catch Gate5BrowserTextHandoffStoreError.missingPayload(let payloadID) {
                diagnostics["lastBrowserTextPayloadCleanup"] = "already_consumed:\(payloadID)"
            } catch {
                reportFailure(error, context: "Browser text import failed")
            }
        }
    }

    /// Runs a handoff-folder read or write off the main thread; the folder is shared with the share extension, so
    /// any of these can wait on it (#2510).
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private func importPendingHandoffsAsync() async {
        guard !isImportingPendingSourceLinkHandoffs else { return }
        isImportingPendingSourceLinkHandoffs = true
        defer {
            isImportingPendingSourceLinkHandoffs = false
            refreshImportInbox()
        }

        do {
            try await consumePendingSpokenMarginsPackageHandoffs(
                from: SpokenMarginsPackageHandoffStore.appGroup()
            )
        } catch {
            diagnostics["pendingSpokenMarginsPackageImport"] = "unavailable:\(error.localizedDescription)"
        }
        var addedItemIds: [String] = []
        var failedSharedArticles = 0
        // The failure goes last, so a success banner for another share in the same drain can't cover it.
        defer {
            reportPendingHandoffsAdded(itemIds: addedItemIds)
            announceFailedSharedArticles(count: failedSharedArticles)
        }

        do {
            let handoffStore = try resolvedSourceLinkHandoffStore()
            let payloadIDs = try await Self.offMain { try handoffStore.pendingPayloadIDs() }
            diagnostics["pendingSourceLinkPayloads"] = "\(payloadIDs.count)"
            // A connection failure leaves the link pending for the next activation or the network's
            // return; anything else is quarantined and the listener is told (#1546).
            let report = await PendingHandoffDrain.run(
                payloadIDs: payloadIDs,
                importPayload: { payloadID in
                    let handoff = try await Self.offMain { try handoffStore.handoff(payloadID: payloadID) }
                    if let itemId = try await self.importSourceLinkInBackground(handoff) { addedItemIds.append(itemId) }
                },
                deletePayload: { id in try await Self.offMain { try handoffStore.deletePayload(payloadID: id) } },
                quarantine: { id, reason in try await Self.offMain { try handoffStore.quarantine(payloadID: id, reason: reason) } },
                storeOutcome: Self.sourceLinkStoreOutcome,
                record: { self.diagnostics["pendingSourceLinkPayload:\($0)"] = $1.diagnosticValue }
            )
            noteSourceLinkDrain(report)
        } catch {
            diagnostics["pendingSourceLinkImport"] = "unavailable:\(error.localizedDescription)"
        }

        do {
            let handoffStore = try resolvedBrowserTextHandoffStore()
            let payloadIDs = try await Self.offMain { try handoffStore.pendingPayloadIDs() }
            diagnostics["pendingBrowserTextPayloads"] = "\(payloadIDs.count)"
            for payloadID in payloadIDs {
                guard browserTextPayloadsInFlight.insert(payloadID).inserted else { continue }
                defer { browserTextPayloadsInFlight.remove(payloadID) }
                do {
                    let handoff = try await Self.offMain { try handoffStore.handoff(payloadID: payloadID) }
                    addedItemIds.append(try hangTelemetry.labels.scoped("pendingBrowserTextImport") {
                        try importBrowserTextInBackground(handoff)
                    })
                    try await Self.offMain { try handoffStore.deletePayload(payloadID: payloadID) }
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "imported"
                } catch Gate5BrowserTextHandoffStoreError.invalidPayload {
                    try? await Self.offMain { try handoffStore.deletePayload(payloadID: payloadID) }
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "deleted_invalid_payload"
                } catch Gate5BrowserTextHandoffStoreError.missingPayload {
                    diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "missing"
                } catch {
                    // Announced only once it sits in the Import Inbox: a payload that can't be quarantined stays
                    // pending, and announcing it would repeat the banner on every drain with nothing behind "See why".
                    do {
                        try await Self.offMain { try handoffStore.quarantine(payloadID: payloadID, reason: error.localizedDescription) }
                        diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "quarantined:\(error.localizedDescription)"
                        failedSharedArticles += 1
                    } catch {
                        diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "quarantine_failed:\(error.localizedDescription)"
                    }
                }
            }
        } catch {
            diagnostics["pendingBrowserTextImport"] = "unavailable:\(error.localizedDescription)"
        }
    }

    private nonisolated static func sourceLinkStoreOutcome(_ error: any Error) -> PendingHandoffOutcome? {
        switch error as? SourceLinkHandoffStoreError {
        case .invalidPayload: return .deletedInvalidPayload
        case .missingPayload: return .missing
        case .appGroupUnavailable, nil: return nil
        }
    }

    /// Shows the waiting count, retries when the network returns, and says when a link failed for good.
    private func noteSourceLinkDrain(_ report: PendingHandoffDrain.Report) {
        sourceLinksWaitingForNetwork = report.waitingCount
        diagnostics["pendingSourceLinkPayloadsWaitingForNetwork"] = "\(report.waitingCount)"
        pendingHandoffNetworkRetry.update(waitingCount: report.waitingCount, connectivity: connectivity) { [weak self] in
            self?.importPendingSourceLinkHandoffs()
        }
        let failures = report.announcedFailures
        guard let first = failures.first else { return }
        let lead = failures.count == 1 ? "A shared link couldn't be imported" : "\(failures.count) shared links couldn't be imported"
        let reason = first.hasSuffix(".") ? first : first + "."
        reportFailure("\(lead): \(reason) Retry or remove it in Settings, Import Inbox.")
    }
}
