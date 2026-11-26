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

    /// True while the pending-handoff drain runs, including the extra round a Retry or a link opened mid-drain asks for (#2136).
    var isImportingPendingSourceLinkHandoffs: Bool { pendingHandoffDrainGate.isRunning }

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
            diagnostics["sourceLinkImportInbox"] = "unavailable:\(SafeErrorText.describe(error))"
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
            diagnostics["browserTextImportInbox"] = "unavailable:\(SafeErrorText.describe(error))"
        }
        importInbox = entries
    }

    /// "See why" on a failure banner: the Settings tab, showing the Import Inbox page (#4781). It refuses while a
    /// Margin is being recorded or written, and then leaves no request behind for a later visit to Settings.
    func openImportInbox() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_import_inbox") else { return }
        requestedSettingsPage = .importInbox
        showSettingsTab()
    }

    /// The page "See why" asked Settings to show, once: reading it clears it.
    func takeSettingsPageRequest() -> SettingsPage? {
        // Every Settings visit asks; setting nil over nil would still publish to every screen's feed (#4028).
        guard let page = requestedSettingsPage else { return nil }
        requestedSettingsPage = nil
        return page
    }

    /// True when the retry was queued, so the Inbox page can hold that entry's Retry while its import runs.
    @discardableResult
    func retryImportInboxEntry(_ entry: ImportInboxEntry) -> Bool {
        do {
            switch entry.kind {
            case .sourceLink:
                try resolvedSourceLinkHandoffStore().retryFailed(payloadID: entry.payloadID)
            case .browserText:
                try resolvedBrowserTextHandoffStore().retryFailed(payloadID: entry.payloadID)
            }
            // The entry leaves the list now, so if it fails the same way again it comes back as a change and the
            // Inbox page turns its Retry back on (#4781).
            refreshImportInbox()
            importPendingSourceLinkHandoffs()
            reportConfirmation("Import retry queued.")
            return true
        } catch {
            reportFailure(error, context: "Import retry failed")
            return false
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
        // A request made while a drain runs (Retry, a link opened) makes it go round once more; before, it was
        // dropped and the "queued" banner was false (#2136).
        guard pendingHandoffDrainGate.request() else { return }
        repeat {
            await drainPendingHandoffsOnce()
        } while pendingHandoffDrainGate.finishPass() != nil
        refreshImportInbox() // before the link lists, so a failed share shows in the inbox while a long arrival runs
        // Link lists the Shortcuts action saved (#4683). After the share pass has released its gate, so a long list never
        // holds up a Safari share.
        await drainLinkListHandoffs()
    }

    private func drainPendingHandoffsOnce() async {
        do {
            try await consumePendingSpokenMarginsPackageHandoffs(
                from: SpokenMarginsPackageHandoffStore.appGroup()
            )
        } catch {
            diagnostics["pendingSpokenMarginsPackageImport"] = "unavailable:\(SafeErrorText.describe(error))"
        }
        var addedItemIds: [String] = []
        var failedSharedArticles = 0
        var transcriptRefusals: [TranscriptImportMessage] = []
        // The failure goes last, so a success banner for another share in the same drain can't cover it.
        defer {
            reportPendingHandoffsAdded(itemIds: addedItemIds)
            announceFailedSharedArticles(count: failedSharedArticles)
            reportTranscriptHandoffRefusals(transcriptRefusals)
        }

        do {
            let handoffStore = try resolvedSourceLinkHandoffStore()
            // What the share extension did with the last share (#5338): the route, what each representation yielded and
            // the handoff id, which matches the `pending…Payload:<id>` result below. Read on every drain, so it is in an
            // export made after a relaunch too.
            let root = handoffStore.rootDirectory
            let lastShare = try await Self.offMain { ShareExtensionShareRecord.load(fromAppGroupRoot: root) }
            if let lastShare { diagnostics["lastShareExtension"] = lastShare.diagnosticValue }
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
            diagnostics["pendingSourceLinkImport"] = "unavailable:\(SafeErrorText.describe(error))"
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
                    // A shared .txt that reads as a meeting transcript becomes a transcript item (#2997).
                    // A store that can't be written to is not an answer: the payload stays for the next drain, as a shared
                    // transcript file does, instead of going to the Import Inbox.
                    let route: SharedTextFileRoute
                    do { route = try await routeSharedTextFile(handoff) } catch {
                        diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "kept:\(SafeErrorText.describe(error))"
                        continue
                    }
                    switch route {
                    case .transcript(let itemId): addedItemIds.append(itemId)
                    case .refused(let message): transcriptRefusals.append(message)
                    case .ordinary:
                        // The item write keeps its label; the Library read after it runs off the main thread (#2256).
                        let imported = try hangTelemetry.labels.scoped("pendingBrowserTextImport") {
                            try browserTextImportEngine().importBrowserTextInBackground(Self.sanitizedBrowserTextHandoff(handoff))
                        }
                        addedItemIds.append(try await finishBackgroundBrowserTextImportOffMain(imported, handoff: handoff))
                    }
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
                        diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "quarantined:\(SafeErrorText.describe(error))"
                        failedSharedArticles += 1
                    } catch {
                        diagnostics["pendingBrowserTextPayload:\(payloadID)"] = "quarantine_failed:\(SafeErrorText.describe(error))"
                    }
                }
            }
        } catch {
            diagnostics["pendingBrowserTextImport"] = "unavailable:\(SafeErrorText.describe(error))"
        }

        // Transcript files the share extension copied unread (.vtt, .srt, .docx), imported through the one transcript rule.
        let transcripts = await drainTranscriptHandoffs()
        addedItemIds.append(contentsOf: transcripts.addedItemIds)
        transcriptRefusals.append(contentsOf: transcripts.refusals)
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
        reportFailure(
            "\(lead): \(reason) Retry or remove it in Settings, Import Inbox.",
            action: UserFeedbackEvent.Action(
                title: "See why",
                accessibilityLabel: "See why the shared \(failures.count == 1 ? "link" : "links") couldn't be imported",
                identifier: "feedback.sharedLinkFailed.seeWhy",
                perform: { [weak self] in self?.openImportInbox() }
            )
        )
    }
}
