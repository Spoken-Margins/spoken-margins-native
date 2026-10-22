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
        screen = .settings
    }

    func openHelp() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_help") else { return }
        isHelpPresented = true
    }

    func openAISettingsFromSummaryPrompt() {
        guard !rejectNavigationOrSessionMutationWhileRecording("open_ai_settings") else { return }
        isAISetupNeededPresented = false
        screen = .settings
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
                              let detail = try? self.loadItemDetail(id: itemId, store: store) else { return }
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
        screen = .settings
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

    func openItem(id: String) {
        let diagnosticStart = ProcessInfo.processInfo.systemUptime
        recordDeveloperDiagnostic("item.open.begin", ["item": DeveloperDiagnosticRecording.token(id)])
        defer { recordDeveloperDiagnostic("item.open.end", ["durationMs": String(Int((ProcessInfo.processInfo.systemUptime - diagnosticStart) * 1000))]) }
        guard !rejectNavigationOrSessionMutationWhileRecording("open_item") else { return }
        followedPlayIntent.cancel() // the listener moved on: a pending Play now must not take over (#2124)
        do {
            let store = try requireStore()
            activeItemId = id
            selectedItem = try loadItemDetail(id: id, store: store)
            prepareImportedLocalAudioBridges(itemId: id)
            scheduleTextAudioPrewarmIfNeeded(itemId: id); PublisherAudioTextMapper.resume(itemId: id, store: store, transcriber: sourceTranscriptionClient) { [weak self] in self?.diagnostics["publisherAudioTextMap"] = "\(id): \($0)" }; fetchCommunityMapIfNeeded(itemId: id); retryVoiceoverLookupIfNeeded(itemId: id)
            listeningMapJSON = ""
            screen = .item
            discoverFollowOfferIfEligible(itemId: id, store: store)
            offerFollowSuggestionIfEligible(itemId: id, store: store)
            reportSuccess("Opened \(selectedItem.title).")
        } catch {
            reportFailure(error, context: "Open item failed")
        }
    }
}
