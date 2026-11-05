import Foundation
import SessionKit
import SessionKitPersistence

/// Screen navigation and the recording navigation guard (#1011): moved out of `Gate1AppModel.swift`
/// unchanged, to keep that file under its size ceiling (scripts/hot_file_ratchet.py). The `screen`
/// property, its recording guard and the stored navigation state stay in the model.
extension Gate1AppModel {
    var activePlaybackItemId: String? {
        snapshot.sessionId == nil ? nil : snapshot.itemId
    }

    var recordingNavigationIsLocked: Bool {
        isRequestingRecordingPermission || snapshot.isRecording || writtenMarginDraft != nil
    }

    @discardableResult
    func rejectNavigationOrSessionMutationWhileRecording(_ operation: String) -> Bool {
        guard recordingNavigationIsLocked else { return false }
        diagnostics["recordingNavigationGuard"] = "blocked_\(operation)"
        statusMessage = "Finish or cancel this Margin before leaving its listening position."
        return true
    }

    func openHome() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_home") else { return }
        // Every route to a tab comes through here, and a tab change leaves `screen` at .home, so the screen check in
        // `stillWantsOpen` can't see it: a tap's item still reading must not land on the tab the listener chose (#2505).
        backgroundRefresh.dropOpen()
        screen = .home
        // Reflect the known source position without loading every saved item.
        if let index = libraryItems.firstIndex(where: { $0.id == snapshot.itemId }), snapshot.sessionId != nil {
            libraryItems[index].hasContinuationSession = true
            libraryItems[index].continuationProgressPercent = snapshot.sourceProgressPercent
        }
        navigationRefreshTask?.cancel()
        guard let store else { return }
        let revision = libraryPresentationRevision
        let read = navigationLibraryRead
        navigationRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
                let data = try await read(store)
                try Task.checkCancellation()
                guard let self, self.screen == .home,
                      self.libraryPresentationRevision == revision else { return }
                self.publishLibrary(data)
            } catch is CancellationError {
            } catch {
                self?.diagnostics["homeLibraryRefreshError"] = String(describing: error)
            }
        }
    }

    func openMargins() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_margins") else { return }
        openHome()
        requestedExperienceRoot = .margins
    }

    func openLibrary() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_library") else { return }
        openHome()
        requestedExperienceRoot = .library
    }

    func openSettings() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_settings") else { return }
        showSettingsTab()
    }

    /// Settings is the fourth tab (#1254), so any route to it lands on the tab bar's home with that tab selected.
    func showSettingsTab() {
        if !recordingNavigationIsLocked { openHome() }
        requestedExperienceRoot = .settings
    }

    func openHelp() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_help") else { return }
        isHelpPresented = true
    }

    func openPlayback() {
        guard !isRequestingRecordingPermission else { return }
        guard hasActiveSession else { return }
        screen = .playback
        if let itemId = snapshot.itemId, let store {
            activeItemId = itemId
            if selectedItem.id != itemId {
                if let detail = activePlaybackDetail, detail.id == itemId {
                    selectedItem = detail
                } else {
                    navigationRefreshTask?.cancel()
                    navigationRefreshTask = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, let self, self.screen == .playback,
                              self.snapshot.itemId == itemId,
                              let detail = try? await self.loadItemDetailOffMain(id: itemId, store: store) else { return }
                        // The read took time: drop it if the listener moved on while it ran.
                        guard !Task.isCancelled, self.screen == .playback, self.snapshot.itemId == itemId else { return }
                        self.selectedItem = detail
                    }
                }
            }
        }
    }

    func openTimeline(focusMarginID: String? = nil) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_timeline") else { return }
        guard hasActiveSession else { return }
        requestedTimelineFocusMarginID = focusMarginID
        screen = .timeline
    }

    func openOfflineStorage() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_offline_storage") else { return }
        tryRefreshOfflineStorageUsage()
        screen = .offlineStorage
    }

    func refreshOfflineStoragePresentation() {
        tryRefreshOfflineStorageUsage()
    }

    func returnToSettingsFromOfflineStorage() {
        guard !rejectNavigationOrSessionMutationWhileRecording("return_to_settings") else { return }
        showSettingsTab()
    }

    func openExport() {
        openExport(sessionId: nil)
    }

    func openExport(sessionId: String?) {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_export") else { return }
        exportSessionId = sessionId
            ?? (snapshot.itemId == selectedItem.id ? snapshot.sessionId : nil)
            ?? selectedItem.sessions.first?.id
        screen = .export
        refreshExportPreview(reportStatus: false)
    }

    /// Opens an item for code that reads the result on the next line (a share, an import, Play now). A listener's tap
    /// uses `openItemFromTap`, which reads off the main thread.
    func openItem(id: String) {
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        recordDeveloperDiagnostic("item.open.begin", ["item": DeveloperDiagnosticRecording.token(id)])
        defer { recordItemOpenEnd(since: diagnosticStart) }
        guard !rejectNavigationOrSessionMutationWhileRecording("open_item") else { return }
        followedPlayIntent.cancel() // the listener moved on: a pending Play now must not take over (#2124)
        _ = backgroundRefresh.beginOpen() // a tap's open still reading must not land over this one
        do {
            let store = try requireStore()
            showOpenedItem(id: id, detail: try loadItemDetail(id: id, store: store), store: store)
        } catch {
            reportFailure(error, context: "Open item failed")
        }
    }

    /// A listener's tap on an item (#2505). The item is read off the main thread, and the screen the tap came from
    /// stays until it is ready, so opening a large item no longer freezes the tap. A newer open, leaving that screen,
    /// or a recording starting meanwhile drops it.
    func openItemFromTap(id: String) {
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        recordDeveloperDiagnostic("item.open.begin", ["item": DeveloperDiagnosticRecording.token(id)])
        guard !rejectNavigationOrSessionMutationWhileRecording("open_item") else { return }
        followedPlayIntent.cancel() // the listener moved on: a pending Play now must not take over (#2124)
        let store: SQLiteSessionStore
        do {
            store = try requireStore()
        } catch {
            reportFailure(error, context: "Open item failed")
            return
        }
        let generation = backgroundRefresh.beginOpen()
        let from = screen
        backgroundRefresh.holdOpen(Task { [weak self] in
            guard let self else { return }
            defer { self.recordItemOpenEnd(since: diagnosticStart) }
            do {
                let detail = try await self.loadItemDetailOffMain(id: id, store: store)
                guard self.stillWantsOpen(generation, from: from) else { return }
                self.hangTelemetry.labels.scoped("openItemFromTap") { self.showOpenedItem(id: id, detail: detail, store: store) }
            } catch {
                guard self.stillWantsOpen(generation, from: from) else { return }
                self.reportFailure(error, context: "Open item failed")
            }
        })
    }

    /// The listener moved within the tab bar (another tab, a pushed screen, a sheet) while a tap's item was read. The
    /// tab bar's place is the view's own state, so the view reports it; the late item is dropped (#2505).
    func listenerMovedOnFromTap() { backgroundRefresh.dropOpen() }

    /// Waits for the open a tap started. Production code never waits; tests do.
    func settleItemOpen() async { await backgroundRefresh.settledOpen() }

    private func stillWantsOpen(_ generation: Int, from: Gate1Screen) -> Bool {
        !Task.isCancelled && backgroundRefresh.isCurrentOpen(generation) && screen == from && !recordingNavigationIsLocked
    }

    private func showOpenedItem(id: String, detail: ItemDetailState, store: SQLiteSessionStore) {
        activeItemId = id
        selectedItem = detail
        prepareImportedLocalAudioBridges(itemId: id)
        scheduleTextAudioPrewarmIfNeeded(itemId: id); PublisherAudioTextMapper.resume(itemId: id, store: store, transcriber: sourceTranscriptionClient) { [weak self] in self?.diagnostics["publisherAudioTextMap"] = "\(id): \($0)" }; fetchCommunityMapIfNeeded(itemId: id); retryVoiceoverLookupIfNeeded(itemId: id)
        listeningMapJSON = ""
        screen = .item
        discoverFollowOfferIfEligible(itemId: id, store: store)
        offerFollowSuggestionIfEligible(itemId: id, store: store)
        reportSuccess("Opened \(selectedItem.title).")
    }

    private func recordItemOpenEnd(since start: TimeInterval) {
        recordDeveloperDiagnostic("item.open.end", ["durationMs": String(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))])
    }
}
