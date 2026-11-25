import Foundation
import SessionKit
import SessionKitSharing
import SwiftUI

@MainActor
struct Build23SenderSharingExperience: View {
    @ObservedObject var coordinator: Build23SharingCoordinator
    @EnvironmentObject private var model: Gate1AppModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var hasBegun = false
    @State private var isSystemSharePresented = false
    @State private var verifiedShareURLForPresentation: URL?
    @State private var isAutoCleanChoicePresented = false
    @State private var showsSharingOptions = false
    /// A first link tapped while voices are made asks for consent at the tap (#4647), not seconds later.
    @State private var isWaitConsentPresented = false
    /// The stage last announced to VoiceOver, so a stage change says its heading once (#3728).
    @State private var announcedStage: VoiceOverAnnouncements.SharingStep = .select
    #if SM_SHARE_LINK_CREATION
    @StateObject private var linkSender = ShareLinkSender()
    /// The server's `links` switch, asked once when the screen opens. Off, Share sends the file as before.
    @State private var isLinkOffered = false
    #endif

    var body: some View {
        withShareLink(screen)
    }

    /// In a build that makes links, Share makes the link (#3750): the consent alert and the link's share sheet hang
    /// on the whole screen, and the server is asked once whether links are on.
    @ViewBuilder
    private func withShareLink(_ content: some View) -> some View {
        #if SM_SHARE_LINK_CREATION
        content
            .modifier(ShareLinkPresentation(sender: linkSender, packageURL: coordinator.verifiedShareFileURL, isSpokenNote: coordinator.sharedItemIsSpokenNote) { packet in
                coordinator.recordSystemShareCompleted(packetURL: packet)
            })
            .onChange(of: linkSender.state) { _, state in
                // The link's share sheet is about to show it: the star counts start again (#4173).
                if case .ready = state { coordinator.recordSystemShareShown() }
            }
            .task { isLinkOffered = await linkSender.isOffered() }
            .onDisappear { linkSender.takedownNoticeWasShown() }
        #else
        content
        #endif
    }

    /// The heading with Cancel, and Export for the same item (#5306). With Export the row is an `AdaptiveStack`: side by
    /// side while all three fit on one line each, otherwise the heading above Export and Cancel, and at accessibility
    /// sizes each on its own line, so no label breaks mid-word and Cancel stays on screen. A reply sheet offers no
    /// Export and keeps its row as it was.
    @ViewBuilder
    private func senderHeader(_ snapshot: Build23SharingSnapshot) -> some View {
        if ShareExportSwitch.offersExport(isReplyBack: snapshot.isReplyBack) {
            AdaptiveStack(spacing: 12) {
                senderHeading
                AdaptiveSpacer()
                AdaptiveStack(spacing: 16) {
                    Button(ShareExportSwitch.exportButtonTitle, systemImage: "doc.text") {
                        switchToExport()
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.exportSessionForShareSwitch() == nil)
                    .accessibilityHint(ShareExportSwitch.exportButtonHint)
                    .accessibilityIdentifier("build23.sender.export")
                    senderCancel
                }
            }
        } else {
            HStack(alignment: .center) {
                senderHeading
                Spacer()
                senderCancel
            }
        }
    }

    private var senderHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(coordinator.senderHeading)
                .font(.headline)
                .foregroundStyle(AppColors.text)
                .accessibilityIdentifier("build23.sender.heading")
            // Replies arrive marked new, so the friend can hear just them (#4785).
            if let caption = coordinator.senderCaption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("build23.sender.caption")
            }
        }
    }

    private var senderCancel: some View {
        Button("Cancel", role: .cancel) {
            coordinator.send(.cancel)
        }
        .accessibilityIdentifier("build23.sender.cancel")
    }

    /// The header's Export (#5306): close this sheet the way Cancel does, then open the Export screen on the same item.
    /// The session is read first, while the sheet still names the one it was sharing from.
    /// Nothing closes when Export could not open: no session to export, or a Margin being recorded.
    private func switchToExport() {
        guard let sessionId = model.exportSessionForShareSwitch(), !model.recordingNavigationIsLocked else { return }
        coordinator.send(.cancel)
        model.openExportFromShareSheet(sessionId: sessionId)
    }

    /// Whether the main Share button makes a link. False in a build without links, while the server says no, and when this
    /// build is below the server's minimum (#4134).
    private var sharesLink: Bool {
        #if SM_SHARE_LINK_CREATION
        isLinkOffered && linkSender.shareLinkAfterwards != .hidden
        #else
        false
        #endif
    }

    private var isMakingLink: Bool {
        #if SM_SHARE_LINK_CREATION
        linkSender.state == .making
        #else
        false
        #endif
    }

    /// "Share link" can't be tapped: a link is being made, or the line on show is a refusal a retry won't pass (#4134).
    private var linkButtonBlocked: Bool {
        #if SM_SHARE_LINK_CREATION
        isMakingLink || !linkSender.shareLinkAfterwards.allowsShareLink
        #else
        false
        #endif
    }

    @ViewBuilder
    private var screen: some View {
        let snapshot = coordinator.snapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                senderHeader(snapshot)
                backToSelectionLink(snapshot)
                if let error = shareError(snapshot) {
                    FailureMessageLabel(error)
                        .accessibilityIdentifier("build23.sender.share.error")
                }
                if Build23SenderPresentation.offersShareWithoutMatching(
                    previewState: snapshot.previewState, includesAcousticEvidence: snapshot.includesAcousticEvidence
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("You can still share these Margins without episode matching. Your recipient's copy places each one by its time instead.")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Share without episode matching", systemImage: "square.and.arrow.up") {
                            coordinator.send(.setIncludesAcousticEvidence(false))
                            shareVerifiedPackage()
                        }
                        .filledActionButton()
                        .accessibilityIdentifier("build23.sender.share.without-matching")
                    }
                }
                if snapshot.stage == .select || snapshot.stage == .review, let notice = snapshot.selectionSummary.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("build23.sender.left-out-notice")
                }
                // Model-written Listening Map text that stays on this phone (#3449, #4635), said before the sender sends.
                if snapshot.stage == .review,
                   let note = MapTextDisclosure.withheldNote(sceneCount: snapshot.withheldMapSceneCount) {
                    Label(note, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("build23.sender.map-text-stays-notice")
                }
                stageContent(snapshot)
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // Review and Share stay pinned at the bottom, within thumb reach, rather than scrolling away (#147).
        .safeAreaInset(edge: .bottom) {
            if snapshot.stage != .share {
                VStack(alignment: .leading, spacing: 8) {
                    // The step the sender can act on sits directly above the button that ends the task (#3839).
                    if let step = snapshot.pinnedStep {
                        Build23PinnedStepLine(step: step)
                    }
                    if snapshot.stage == .review, snapshot.showsList, !isOneMarginShare(snapshot) {
                        // The top card scrolls away; the count stays in reach (#4647).
                        Text(ShareReviewCardWords.barCount(included: snapshot.includedCount, total: snapshot.selectableCount))
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("build23.sender.bar.count")
                    }
                    linkStatusLines
                    if let count = snapshot.sendWaitCount, snapshot.stage == .review {
                        Build23SendWaitRow(count: count) {
                            coordinator.send(.stopSendWait)
                        }
                    } else {
                        primaryAction(snapshot)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                        secondaryAction(snapshot)
                    }
                    fileCaption(snapshot)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(AppColors.bone)
            }
        }
        .background(AppColors.bone.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("build23.sender.experience")
        .onAppear {
            guard !hasBegun else { return }
            hasBegun = true
            coordinator.send(.begin)
            // Asks only when it can be true: never on the reply sheet, never when no included Margin can be cleaned (#3792).
            isAutoCleanChoicePresented = coordinator.snapshot.asksAutoCleanQuestion
        }
        .onCompatibleChange(of: snapshot.previewState) { previewState in
            let stage = coordinator.snapshot.stage
            if previewState == .ready, stage != .select, let requested = coordinator.pendingShare {
                coordinator.pendingShare = nil
                deliver(requested)
                return
            }
            dropStaleShareRequests(stage: stage, previewState: previewState)
        }
        .onCompatibleChange(of: snapshot.stage) { stage in
            dropStaleShareRequests(stage: stage, previewState: coordinator.snapshot.previewState)
            announceStage(stage)
        }
        .alert(ShareCleanupWords.alertTitle, isPresented: $isAutoCleanChoicePresented) {
            Button(ShareCleanupWords.alertAccept) {
                coordinator.send(.setAutoCleanSelectedEnabled(true))
            }
            Button(ShareCleanupWords.alertDecline, role: .cancel) {
                coordinator.send(.setAutoCleanSelectedEnabled(false))
            }
        } message: {
            Text(ShareCleanupWords.alertMessage)
        }
        // A voice the waited share needed didn't come (#4647): ask once, after every wait has ended.
        .alert(
            ShareReviewCardWords.failureTitle(count: snapshot.sendWaitFailedCount ?? 1),
            isPresented: Binding(
                get: { coordinator.sendWaitFailedCount != nil },
                set: { if !$0, coordinator.sendWaitFailedCount != nil { coordinator.send(.sendWaitNotNow) } }
            )
        ) {
            Button(ShareReviewCardWords.shareAnyway) {
                coordinator.send(.sendWaitShareAnyway)
            }
            Button(ShareReviewCardWords.notNow, role: .cancel) {
                coordinator.send(.sendWaitNotNow)
            }
        } message: {
            Text(ShareReviewCardWords.failureMessage(count: snapshot.sendWaitFailedCount ?? 1))
        }
        // A first link while voices are made: the consent words, at the tap (#4647).
        .alert(ShareLinkConsentCopy.title, isPresented: $isWaitConsentPresented) {
            Button(ShareLinkConsentCopy.accept) {
                ServerSendConsent.record(.shareLinks)
                coordinator.send(.beginSendWait(.link))
            }
            Button(ShareLinkConsentCopy.decline, role: .cancel) {}
        } message: {
            Text(ShareLinkConsentCopy.message)
        }
        .trackedSheet(isPresented: $isSystemSharePresented, onDismiss: finishSystemShare) {
            if let packageURL = verifiedShareURLForPresentation {
                SharedSpokenMarginsPackageActivityView(
                    packageURL: packageURL,
                    itemTitle: coordinator.snapshot.itemTitle
                ) { coordinator.recordSystemShareCompleted(packetURL: packageURL) }
            }
        }
    }

    @ViewBuilder
    private func stageContent(_ snapshot: Build23SharingSnapshot) -> some View {
        switch snapshot.stage {
        case .select:
            selectStage(snapshot)
        case .review where snapshot.showsList:
            listStage(snapshot)
        case .review:
            reviewStage(snapshot)
        case .recipientPreview:
            recipientPreviewStage(snapshot)
        case .share:
            shareStage(snapshot)
        }
    }

    @ViewBuilder
    private func primaryAction(_ snapshot: Build23SharingSnapshot) -> some View {
        let includedCount = snapshot.selectionSummary.packetCount
        switch snapshot.stage {
        case .select:
            Button("Review \(includedCount)") {
                advanceToReview(from: snapshot)
            }
            .filledActionButton()
            .disabled(!snapshot.canAdvance)
            .accessibilityIdentifier("build23.sender.select.continue")
        case .review where sharesLink:
            linkShareButton(isWorking: Build23ShareRequestPolicy.showsMakingLink(isMakingLink: isMakingLink, pendingShare: coordinator.pendingShare))
                .disabled(!snapshot.canAdvance || linkButtonBlocked)
                .accessibilityIdentifier("build23.sender.review.share")
        case .review:
            Button("Share \(includedCount)", systemImage: "square.and.arrow.up") {
                shareVerifiedPackage()
            }
            .filledActionButton()
            .disabled(!snapshot.canAdvance)
            .accessibilityIdentifier("build23.sender.review.share")
        case .recipientPreview where sharesLink:
            linkShareButton(isWorking: Build23ShareRequestPolicy.showsMakingLink(isMakingLink: isMakingLink, pendingShare: coordinator.pendingShare))
                .disabled(snapshot.previewState != .ready || linkButtonBlocked)
                .accessibilityIdentifier("build23.sender.preview.share")
        case .recipientPreview:
            Button(
                snapshot.previewState == .building ? "Getting ready…" : "Share \(includedCount)",
                systemImage: snapshot.previewState == .building ? "hourglass" : "square.and.arrow.up"
            ) {
                shareVerifiedPackage()
            }
            .filledActionButton()
            .disabled(snapshot.previewState != .ready)
        case .share:
            EmptyView()
        }
    }

    /// The main Share button when it makes a link (#3750). The file is the second choice, "Send as a file".
    private func linkShareButton(isWorking: Bool) -> some View {
        Button {
            share(.link)
        } label: {
            if isWorking {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Making link…")
                }
            } else {
                Label("Share link", systemImage: "link")
            }
        }
        .filledActionButton()
        .accessibilityHint("Makes a private link to these Margins and opens the share sheet with it")
    }

    @ViewBuilder
    private var linkStatusLines: some View {
        #if SM_SHARE_LINK_CREATION
        let lines = ShareLinkStatusLines(
            state: linkSender.state,
            companionNote: linkSender.companionNote,
            showsTakedownNotice: linkSender.showsTakedownNotice,
            onTakedownNoticeDrawn: { linkSender.takedownNoticeWasDrawn() },
            playCheckLine: linkSender.playCheckLine,
            playCheckLinkID: linkSender.playCheckLinkID
        )
        // Below the minimum build the button is hidden, and the update line shows anyway (#4134).
        if sharesLink || linkSender.shareLinkAfterwards == .hidden, lines.hasLines {
            lines
        }
        #endif
    }

    /// "Back to selection", on its own line under the header on the review and preview steps (#3896). Each step keeps
    /// its own identifier; the action is the same. The preview step draws it only once the preview is ready.
    @ViewBuilder
    private func backToSelectionLink(_ snapshot: Build23SharingSnapshot) -> some View {
        if let identifier = Build23SenderPresentation.topBackToSelectionIdentifier(
            stage: snapshot.stage,
            previewState: snapshot.previewState,
            hasVerifiedPreview: snapshot.verifiedPreview != nil,
            showsList: snapshot.showsList
        ) {
            Build23BackToSelectionButton(
                identifier: identifier,
                title: snapshot.showsList ? ShareReviewCardWords.backToYourMargins : "Back to selection"
            ) {
                coordinator.send(.returnToSelect)
            }
        }
    }

    /// "Send as a file", under the filled "Share link" in the pinned bar (#3896). Only a build that makes links has it.
    @ViewBuilder
    private func secondaryAction(_ snapshot: Build23SharingSnapshot) -> some View {
        switch snapshot.stage {
        case .review where sharesLink:
            Build23SendFileButton(
                isEnabled: snapshot.canAdvance && !isMakingLink,
                identifier: "build23.sender.review.share.file"
            ) {
                share(.file)
            }
        case .recipientPreview where sharesLink:
            if snapshot.previewState == .ready, snapshot.verifiedPreview != nil {
                Build23SendFileButton(
                    isEnabled: coordinator.verifiedShareFileURL != nil && !isMakingLink,
                    identifier: "build23.sender.share.present"
                ) {
                    sendPreviewedFile()
                }
            }
        default:
            EmptyView()
        }
    }

    /// The line under the button that sends the file (#3800): the friend needs the app to open it. With links on it
    /// sits under "Send as a file", where that button is drawn; with links off the main Share button sends the file,
    /// so it sits under that, and says only the first sentence because there is no link to offer.
    @ViewBuilder
    private func fileCaption(_ snapshot: Build23SharingSnapshot) -> some View {
        switch snapshot.stage {
        case .review:
            Build23FileNeedsAppCaption(linksOffered: sharesLink)
        case .recipientPreview where !sharesLink:
            Build23FileNeedsAppCaption(linksOffered: false)
        case .recipientPreview where snapshot.previewState == .ready && snapshot.verifiedPreview != nil:
            Build23FileNeedsAppCaption(linksOffered: true)
        default:
            EmptyView()
        }
    }

    private func selectStage(_ snapshot: Build23SharingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            selectionControls(snapshot)
            filterBar(snapshot)
            selectMarginGrid(snapshot)

            DisclosureGroup("Sharing options", isExpanded: $showsSharingOptions) {
                VStack(alignment: .leading, spacing: 16) {
                    senderDetails(snapshot)
                    Build23TransportConsequenceCard(
                        transport: snapshot.transport,
                        rightsConfirmed: snapshot.confirmsPrivateSharingRights
                    )
                }
                .padding(.top, 12)
            }
            .font(.headline)
            .accessibilityIdentifier("build23.sender.sharing-options")

            if let errorMessage = snapshot.errorMessage, !errorMessage.isEmpty {
                FailureMessageLabel(errorMessage)
                    .font(.subheadline)
                    .accessibilityIdentifier("build23.sender.error")
            }

        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("build23.sender.stage.select")
    }

    /// The top card: the title, the count, the Select buttons, the switch and the run's progress. On the list (#4647) a
    /// one-Margin share hides the count and the Select buttons, and nothing here is disabled by cleanup; while a share
    /// waits for voices every control is inert.
    private func selectionControls(_ snapshot: Build23SharingSnapshot, oneMargin: Bool = false) -> some View {
        let visibleMargins = Build23SenderPresentation.filteredMargins(in: snapshot)
        // A Margin with no place can't be chosen, so it is not counted as one to choose (#4233).
        let selectableCount = snapshot.selectableCount
        let inert = snapshot.isSendWaiting
        return ExperienceSurface(tint: AppColors.softGreen) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(VoiceOverAnnouncements.SharingStep.select.title)
                        .font(.title3.weight(.semibold))
                        .screenTitle()
                        .accessibilityIdentifier(snapshot.showsList ? "build23.sender.stage.list" : "build23.sender.stage.select.title")
                    if snapshot.showsList, let caption = snapshot.reviewCaption {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(AppColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("build23.sender.review.starredCaption")
                    }
                    if !oneMargin {
                        Text(ShareReviewCardWords.barCount(included: snapshot.includedCount, total: selectableCount))
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("build23.sender.count")
                    }
                    if !snapshot.margins.isEmpty, selectableCount == 0 {
                        Text(ShareableMargins.allWithoutPlaceLine)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.text)
                            .accessibilityIdentifier("build23.sender.noPlace.all")
                    }
                    if !oneMargin {
                        Build23WrappingLayout(spacing: 8) {
                            Button("Select all shown") {
                                setVisibleIncluded(true, margins: visibleMargins)
                            }
                            Button("Select none shown") {
                                setVisibleIncluded(false, margins: visibleMargins)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(inert || visibleMargins.isEmpty)
                    }
                }

                Divider()

                Toggle(
                    ShareCleanupWords.switchLabel,
                    isOn: Binding(
                        get: { snapshot.autoCleanSelectedEnabled },
                        set: { coordinator.send(.setAutoCleanSelectedEnabled($0)) }
                    )
                )
                .font(.headline)
                .disabled(inert)
                .accessibilityIdentifier("build23.sender.auto-clean")

                Text(ShareCleanupWords.switchCaption(isOn: snapshot.autoCleanSelectedEnabled))
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)

                if snapshot.isPreparingAll {
                    ProgressView(
                        value: Double(snapshot.preparationCompleted),
                        total: Double(max(snapshot.preparationTotal, 1))
                    )
                    .tint(AppColors.evergreen)
                    AdaptiveStack {
                        Text(ShareCleanupWords.running(completed: snapshot.preparationCompleted, total: snapshot.preparationTotal))
                            .font(.subheadline)
                        AdaptiveSpacer()
                        Button("Cancel", role: .cancel) {
                            coordinator.send(.cancelPreparation)
                        }
                        .disabled(inert)
                    }
                } else if snapshot.preparationTotal > 0 {
                    if snapshot.preparationFailures == 0 {
                        Build23StatusLabel(
                            icon: "checkmark.circle.fill",
                            title: ShareCleanupWords.bulkResult(completed: snapshot.preparationCompleted, failed: 0),
                            tint: AppColors.evergreen
                        )
                    } else {
                        FailureMessageLabel(ShareCleanupWords.bulkResult(completed: snapshot.preparationCompleted, failed: snapshot.preparationFailures))
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    private func senderDetails(_ snapshot: Build23SharingSnapshot) -> some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("What you’re sharing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                Text(snapshot.itemTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColors.text)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Sender and permissions")
                    .font(.headline)
                Text(SharingRightsPresentation.rightsNotice)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                Text(SharingRightsPresentation.recipientCopiesNotice)
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)

                AppTextField(
                    "Name shown to the recipient",
                    text: Binding(
                        get: { snapshot.senderDisplayLabel },
                        set: { coordinator.send(.setSenderDisplayLabel($0)) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .textContentType(.name)
                .accessibilityLabel("Sender name shown to the recipient")
                .accessibilityIdentifier("build23.sender.display-label")

                Toggle(
                    "Include acoustic evidence when available",
                    isOn: Binding(
                        get: { snapshot.includesAcousticEvidence },
                        set: { coordinator.send(.setIncludesAcousticEvidence($0)) }
                    )
                )
                .accessibilityHint("Controls whether supported listening evidence travels with your Margins")
                .accessibilityIdentifier("build23.sender.include-acoustic-evidence")

                if Build23SenderPresentation.showsLinklessRightsControl(for: snapshot.transport) {
                    Toggle(
                        "I have the right to privately embed this linkless material",
                        isOn: Binding(
                            get: { snapshot.confirmsPrivateSharingRights },
                            set: { coordinator.send(.setPrivateSharingRightsConfirmed($0)) }
                        )
                    )
                    .accessibilityHint("When disabled, Margins can still be sent without including it; the recipient supplies the source")
                    .accessibilityIdentifier("build23.sender.confirm-rights")
                }
            }
        }
    }

    private func filterBar(_ snapshot: Build23SharingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Show Margins")
                .font(.headline)
            Build23WrappingLayout(spacing: 8) {
                ForEach(ShareMarginDraftFilter.allCases) { filter in
                    Button {
                        applyFilter(filter)
                    } label: {
                        ExperienceFilterChip(isActive: snapshot.filter == filter) {
                            Label(
                                filter == .all ? "All" : "Starred",
                                systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "star.fill"
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(snapshot.isSendWaiting)
                    .accessibilityValue(snapshot.filter == filter ? "Selected" : "Not selected")
                    .accessibilityIdentifier("build23.sender.filter.\(filter.rawValue)")
                }
            }
        }
    }

    @ViewBuilder
    private func selectMarginGrid(_ snapshot: Build23SharingSnapshot) -> some View {
        let visibleMargins = Build23SenderPresentation.filteredMargins(in: snapshot)

        if visibleMargins.isEmpty {
            marginList(visibleMargins, snapshot: snapshot)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(visibleMargins) { margin in
                    Build23MarginSelectionRow(
                        margin: margin,
                        isEnabled: true,
                        onSetIncluded: { setIncluded($0, marginID: margin.id) }
                    )
                }
            }
        }
    }

    private func marginList(
        _ margins: [Build23SharingMarginSnapshot],
        snapshot: Build23SharingSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if margins.isEmpty {
                ExperienceSurface {
                    Build23StatusLabel(
                        icon: snapshot.filter == .starred ? "star.slash" : "text.badge.xmark",
                        title: snapshot.filter == .starred
                            ? "No starred Margins. Switch to All to choose from every Margin."
                            : "There are no Margins available to share."
                    )
                }
            } else {
                ForEach(margins) { margin in
                    Build23MarginSelectionRow(
                        margin: margin,
                        isEnabled: true,
                        onSetIncluded: { setIncluded($0, marginID: margin.id) }
                    )
                }
            }
        }
    }

    private func marginEditors(_ margins: [Build23SharingMarginSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let margin = margins.first {
                Build23MarginEditor(margin: margin) { action in
                    coordinator.send(action)
                }
            } else {
                ExperienceSurface {
                    Build23StatusLabel(
                        icon: "hand.tap",
                        title: "Select a visible Margin to open its detailed editor."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func reviewComposition(_ snapshot: Build23SharingSnapshot) -> some View {
        let includedMargins = snapshot.margins.filter(\.isIncluded)
        let expandedMargins = Build23SenderPresentation.reviewExpandedMargins(in: snapshot)
        let selectedEditorID = expandedMargins.first?.id

        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 20) {
                reviewMarginList(includedMargins, selectedEditorID: selectedEditorID, togglesEditor: snapshot.isReplyBack)
                    .frame(maxWidth: 340)
                marginEditors(expandedMargins)
                    .frame(maxWidth: .infinity)
            }
        } else if snapshot.isReplyBack {
            replyReceipt(includedMargins, selectedEditorID: selectedEditorID)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                reviewMarginNavigator(includedMargins, selectedEditorID: selectedEditorID)
                marginEditors(expandedMargins)
            }
        }
    }

    private func reviewMarginNavigator(
        _ margins: [Build23SharingMarginSnapshot],
        selectedEditorID: String?
    ) -> some View {
        let selectedIndex = margins.firstIndex(where: { $0.id == selectedEditorID }) ?? 0
        return HStack(spacing: 10) {
            Button("Previous", systemImage: "chevron.left") {
                coordinator.send(.selectMargin(margins[max(0, selectedIndex - 1)].id))
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Previous Margin")
            .disabled(margins.isEmpty || selectedIndex == 0)

            Menu {
                ForEach(Array(margins.enumerated()), id: \.element.id) { index, margin in
                    Button("Margin \(index + 1): \(margin.reviewedText)") {
                        coordinator.send(.selectMargin(margin.id))
                    }
                }
            } label: {
                HStack {
                    Text(margins.isEmpty ? "No Margins" : "Margin \(selectedIndex + 1) of \(margins.count)")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(AppColors.softGreen, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(margins.isEmpty)

            Button("Next", systemImage: "chevron.right") {
                coordinator.send(.selectMargin(margins[min(margins.count - 1, selectedIndex + 1)].id))
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Next Margin")
            .disabled(margins.isEmpty || selectedIndex + 1 >= margins.count)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("build23.sender.review.navigator")
    }

    private func reviewMarginList(
        _ margins: [Build23SharingMarginSnapshot],
        selectedEditorID: String?,
        togglesEditor: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Included Margins")
                .font(.headline)
                .accessibilityIdentifier("build23.sender.review.margin-list")
            ForEach(margins) { margin in
                Build23ReviewSelectionRow(
                    margin: margin,
                    isSelected: selectedEditorID == margin.id,
                    onSelect: { selectReviewRow(margin.id, selectedEditorID: selectedEditorID, togglesEditor: togglesEditor) }
                )
            }
        }
    }

    /// The reply review (#3792): one row per Margin going, with no editor open. A tap opens the editor under its row; a
    /// second tap closes it. There is no navigator: with the editor closed there is nothing to move between.
    private func replyReceipt(
        _ margins: [Build23SharingMarginSnapshot],
        selectedEditorID: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(margins) { margin in
                Build23ReviewSelectionRow(
                    margin: margin,
                    isSelected: selectedEditorID == margin.id,
                    onSelect: { selectReviewRow(margin.id, selectedEditorID: selectedEditorID, togglesEditor: true) }
                )
                if selectedEditorID == margin.id {
                    Build23MarginEditor(margin: margin) { action in
                        coordinator.send(action)
                    }
                }
            }
        }
    }

    private func selectReviewRow(_ marginID: String, selectedEditorID: String?, togglesEditor: Bool) {
        coordinator.send(.selectMargin(togglesEditor && selectedEditorID == marginID ? nil : marginID))
    }

    /// One Margin to share ("Share this Margin"): there is nothing to choose, so the count, the Select buttons and the
    /// chips are hidden (#4647).
    private func isOneMarginShare(_ snapshot: Build23SharingSnapshot) -> Bool {
        snapshot.margins.count == 1
    }

    /// The Share Margins list (#4647): a sheet that isn't a reply shows its Margins in one column, words first, and the
    /// sender switches, reads, edits and shares from here. There is no Next, no Back and no navigator.
    private func listStage(_ snapshot: Build23SharingSnapshot) -> some View {
        let visibleMargins = Build23SenderPresentation.filteredMargins(in: snapshot)
        let oneMargin = isOneMarginShare(snapshot)
        let inert = snapshot.isSendWaiting
        return VStack(alignment: .leading, spacing: 20) {
            selectionControls(snapshot, oneMargin: oneMargin)
            if !oneMargin {
                filterBar(snapshot)
            }

            if visibleMargins.isEmpty {
                marginList(visibleMargins, snapshot: snapshot)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleMargins) { margin in
                        Build23MarginListCard(
                            margin: margin,
                            isEditing: snapshot.selectedMarginID == margin.id,
                            isInert: inert,
                            send: { coordinator.send($0) },
                            onEdit: { coordinator.send(.selectMargin(margin.id)) },
                            onDone: { coordinator.send(.selectMargin(nil)) }
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Build23PreviewRow {
                    coordinator.send(.buildRecipientPreview)
                }
                .disabled(!snapshot.canAdvance || snapshot.readiness.isWaiting || inert)
                // The preview row and "Listen without ums" are the only controls that wait for a voice.
                if snapshot.readiness.isWaiting {
                    Text(ShareReviewCardWords.previewWaiting)
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("build23.sender.preview.waiting")
                }
            }

            DisclosureGroup("Sharing options", isExpanded: $showsSharingOptions) {
                VStack(alignment: .leading, spacing: 16) {
                    senderDetails(snapshot)
                        .disabled(inert)
                    Build23TransportConsequenceCard(
                        transport: snapshot.transport,
                        rightsConfirmed: snapshot.confirmsPrivateSharingRights
                    )
                    Text("\(snapshot.itemTitle) · From \(snapshot.senderDisplayLabel)")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)
            }
            .font(.headline)
            .accessibilityIdentifier("build23.sender.sharing-options")
        }
        // One column, at most 700 pt and centred, at every width (#4647).
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("build23.sender.list")
    }

    private func reviewStage(_ snapshot: Build23SharingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(VoiceOverAnnouncements.SharingStep.review.title)
                .font(.headline)
                .foregroundStyle(AppColors.text)
                .screenTitle()
                .accessibilityIdentifier("build23.sender.stage.review")

            // Directly under the heading, so it sits above the phone's navigator and the iPad's "Included Margins" list.
            if let caption = snapshot.reviewCaption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("build23.sender.review.starredCaption")
            }

            reviewComposition(snapshot)

            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 16) {
                    Build23TransportConsequenceCard(
                        transport: snapshot.transport,
                        rightsConfirmed: snapshot.confirmsPrivateSharingRights
                    )
                    Text("\(snapshot.itemTitle) · From \(snapshot.senderDisplayLabel)")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .padding(.top, 10)
            }
            .font(.headline)

            if let errorMessage = snapshot.errorMessage, !errorMessage.isEmpty {
                FailureMessageLabel(errorMessage)
                    .font(.subheadline)
            }

            Build23PreviewRow {
                coordinator.send(.buildRecipientPreview)
            }
            // A packet never carries a voice still being made (#4647): the preview waits for it, as Share does.
            .disabled(!snapshot.canAdvance || snapshot.readiness.isWaiting || snapshot.isSendWaiting)
        }
        .onAppear(perform: normalizeReviewSelection)
    }

    private func recipientPreviewStage(_ snapshot: Build23SharingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(VoiceOverAnnouncements.SharingStep.recipientPreview.title)
                .font(.headline)
                .foregroundStyle(AppColors.text)
                .screenTitle()
                .accessibilityIdentifier("build23.sender.stage.recipient-preview")
            switch snapshot.previewState {
            case .building:
                ExperienceSurface(tint: AppColors.softGreen) {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView()
                            .tint(AppColors.evergreen)
                        Build23StatusLabel(
                            icon: "doc.badge.gearshape",
                            title: "Getting your Margins ready to share…",
                            tint: AppColors.evergreen
                        )
                    }
                }
                .accessibilityIdentifier("build23.sender.preview.building")

            case .ready:
                if let verifiedPreview = snapshot.verifiedPreview {
                    Build23VerifiedShareActions(
                        isFileShareEnabled: coordinator.verifiedShareFileURL != nil && !isMakingLink,
                        fileIsSecondChoice: sharesLink,
                        onShareFile: sendPreviewedFile
                    )

                    Build23VerifiedRecipientPreviewPanel(
                        preview: verifiedPreview,
                        withheldMapSceneCount: snapshot.withheldMapSceneCount
                    )
                } else {
                    unavailablePreview(
                        title: "The preview is not available.",
                        detail: "Go back to review and preview again."
                    )
                }

            case .stale:
                unavailablePreview(
                    title: "The preview is out of date.",
                    detail: "You changed something. Preview again before sharing."
                )

            case let .failed(message):
                unavailablePreview(
                    title: "Your Margins could not be made ready to share.",
                    detail: message,
                    isFailure: true
                )

            case .notBuilt:
                unavailablePreview(
                    title: "There is no preview yet.",
                    detail: "Go back to review and preview first."
                )
            }
        }
    }

    /// A stale or unbuilt preview is a notice; Margins that could not be made ready are a failure (#308).
    private func unavailablePreview(title: String, detail: String, isFailure: Bool = false) -> some View {
        ExperienceSurface(tint: AppColors.ochre.opacity(0.12)) {
            VStack(alignment: .leading, spacing: 10) {
                if isFailure {
                    FailureMessageLabel(title)
                        .font(.subheadline)
                } else {
                    Build23StatusLabel(icon: "exclamationmark.triangle.fill", title: title, tint: AppColors.plum)
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                Button(coordinator.snapshot.showsList ? ShareReviewCardWords.backToYourMargins : "Back to selection",
                       systemImage: "arrow.left") {
                    coordinator.send(.returnToSelect)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func shareStage(_ snapshot: Build23SharingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(VoiceOverAnnouncements.SharingStep.share.title)
                .font(.headline)
                .foregroundStyle(AppColors.text)
                .screenTitle()
                .accessibilityIdentifier("build23.sender.stage.share")
            if coordinator.verifiedShareFileURL != nil, snapshot.canShareVerifiedFile {
                ExperienceSurface(tint: AppColors.softGreen) {
                    Build23StatusLabel(
                        icon: "square.and.arrow.up.circle.fill",
                        title: isSystemSharePresented ? "System share sheet open" : "Your Margins are ready",
                        tint: AppColors.evergreen
                    )
                }

                if !isSystemSharePresented {
                    AdaptiveStack {
                        Button("Return to recipient preview", systemImage: "arrow.left") {
                            coordinator.send(.returnFromSystemShare)
                        }
                        .buttonStyle(.bordered)
                        AdaptiveSpacer()
                        Button("Open system share sheet", systemImage: "square.and.arrow.up") {
                            presentVerifiedSystemShare()
                        }
                        .filledActionButton()
                        .accessibilityIdentifier("build23.sender.share.reopen")
                    }
                }
            } else {
                unavailablePreview(
                    title: "The file to share is no longer available.",
                    detail: "Go back to selection and preview again."
                )
            }
        }
    }

    private func setIncluded(_ included: Bool, marginID: String) {
        coordinator.send(.setIncluded(id: marginID, included: included))
        if included {
            coordinator.send(.selectMargin(marginID))
        }
        normalizeReviewSelection()
    }

    private func setVisibleIncluded(_ included: Bool, margins: [Build23SharingMarginSnapshot]) {
        coordinator.send(.setVisibleIncluded(ids: margins.map(\.id), included: included))
        normalizeReviewSelection()
    }

    private func advanceToReview(from snapshot: Build23SharingSnapshot) {
        let includedMargins = snapshot.margins.filter(\.isIncluded)
        if snapshot.isReplyBack {
            // The reply review opens as a receipt, with every editor closed (#3792).
            coordinator.send(.selectMargin(nil))
            coordinator.send(.advanceToReview)
            return
        }
        guard !includedMargins.isEmpty else {
            coordinator.send(.advanceToReview)
            return
        }
        if let selectedMarginID = snapshot.selectedMarginID,
           includedMargins.contains(where: { $0.id == selectedMarginID }) {
            coordinator.send(.advanceToReview)
            return
        }
        coordinator.send(.selectMargin(includedMargins[0].id))
        coordinator.send(.advanceToReview)
    }

    private func normalizeReviewSelection() {
        let snapshot = coordinator.snapshot
        // On the list only a card's editor button and Done set the selection (#4647).
        guard !snapshot.showsList || snapshot.stage == .select else { return }
        let includedMargins = snapshot.margins.filter(\.isIncluded)
        if let selectedMarginID = snapshot.selectedMarginID,
           includedMargins.contains(where: { $0.id == selectedMarginID }) {
            return
        }
        // A reply review keeps its editors closed until a row is tapped (#3792).
        coordinator.send(.selectMargin(snapshot.isReplyBack ? nil : includedMargins.first?.id))
    }

    private func applyFilter(_ filter: ShareMarginDraftFilter) {
        coordinator.send(.setFilter(filter))
        // On the list a chip never opens an editor; an editor whose card the chip hides closes (#4647).
        if coordinator.snapshot.showsList {
            let refreshed = coordinator.snapshot
            if let selected = refreshed.selectedMarginID,
               !Build23SenderPresentation.filteredMargins(in: refreshed).contains(where: { $0.id == selected }) {
                coordinator.send(.selectMargin(nil))
            }
            return
        }
        let refreshed = coordinator.snapshot
        let visibleMargins = Build23SenderPresentation.filteredMargins(in: refreshed)
        if let selectedMarginID = refreshed.selectedMarginID,
           visibleMargins.contains(where: { $0.id == selectedMarginID }) {
            return
        }
        coordinator.send(.selectMargin(visibleMargins.first?.id))
    }

    /// A send tap on the preview stage, where the packet is already made: log the selection, then show the system sheet.
    /// "Open system share sheet" reopens the same send, so it calls `presentVerifiedSystemShare` alone (#4173).
    private func sendPreviewedFile() {
        coordinator.recordShareSelection()
        presentVerifiedSystemShare()
    }

    private func presentVerifiedSystemShare() {
        coordinator.send(.presentSystemShare)
        guard let verifiedURL = coordinator.verifiedShareFileURL else { return }
        coordinator.recordSystemShareShown()
        verifiedShareURLForPresentation = verifiedURL
        isSystemSharePresented = true
    }

    /// Share the way the main button does: a link when this build makes them, the server allows it and no refusal on
    /// show has taken "Share link" away (#4134), else the file.
    private func shareVerifiedPackage() {
        share(linkAllowedNow ? .link : .file)
    }

    /// Whether a share asked for now may make a link. Every path that picks the link reads this, so a refusal that
    /// disabled "Share link" can't leave another Share button doing nothing (#4134 audit).
    private var linkAllowedNow: Bool {
        #if SM_SHARE_LINK_CREATION
        linkSender.shareLinkAfterwards.makesLink(offered: sharesLink)
        #else
        false
        #endif
    }

    /// Makes the packet if it isn't ready, then sends it the way the listener asked.
    private func share(_ kind: Build23PendingShare) {
        let snapshot = coordinator.snapshot
        // A second tap while a share waits does nothing: one wait, one export (#4647).
        guard !snapshot.isSendWaiting else { return }
        coordinator.recordShareSelection() // one line per tap; not in deliver, so a tap never logs twice (#4173)
        // A voice the share needs is still being made: wait for it, never send without it (#4647). A first link asks
        // for consent here, at the tap, so the sender answers while the voices are made.
        if snapshot.stage == .review, snapshot.readiness.isWaiting {
            if kind == .link, !ServerSendConsent.hasConsented(to: .shareLinks) {
                isWaitConsentPresented = true
            } else {
                coordinator.send(.beginSendWait(kind))
            }
            return
        }
        if coordinator.verifiedShareFileURL != nil {
            deliver(kind)
            return
        }
        coordinator.pendingShare = kind
        coordinator.send(.buildRecipientPreview)
        // Export can fail synchronously, before SwiftUI observes .building.
        if case .failed = coordinator.previewState { coordinator.pendingShare = nil }
    }

    /// The stage is replaced in place and focus can stay on the bottom button, so say where the sheet is now (#3728).
    /// `onCompatibleChange` hands over only the new value, so the previous stage is kept in `announcedStage`.
    private func announceStage(_ stage: Build23SharingStage) {
        let step = Self.step(for: stage, showsList: coordinator.snapshot.showsList)
        if let text = VoiceOverAnnouncements.sharingStage(from: announcedStage, to: step) {
            AccessibilityNotification.Announcement(text).post()
        }
        announcedStage = step
    }

    /// The list is the Choose step for VoiceOver (#4647): back from the preview it says "Choose Margins", and nothing is
    /// announced when the sheet opens on it.
    static func step(for stage: Build23SharingStage, showsList: Bool) -> VoiceOverAnnouncements.SharingStep {
        switch stage {
        case .select: .select
        case .review: showsList ? .select : .review
        case .recipientPreview: .recipientPreview
        case .share: .share
        }
    }

    /// A share asked for, or a link being made, for a packet the screen no longer shows is dropped (#3751 audit).
    private func dropStaleShareRequests(stage: Build23SharingStage, previewState: Build23SharingPreviewState) {
        // A share waiting for voices has no packet yet: it is the wait's to keep or drop (#4647).
        if coordinator.sendWait == nil,
           !Build23ShareRequestPolicy.keepsPendingShare(stage: stage, previewState: previewState) {
            coordinator.pendingShare = nil
        }
        #if SM_SHARE_LINK_CREATION
        if !Build23ShareRequestPolicy.keepsLink(stage: stage, previewState: previewState),
           linkSender.state != .idle || linkSender.playCheckLine != nil {
            linkSender.reset()
        }
        #endif
    }

    private func deliver(_ kind: Build23PendingShare) {
        switch kind {
        case .file:
            presentVerifiedSystemShare()
        case .link:
            #if SM_SHARE_LINK_CREATION
            // A refusal that arrived while the packet was being made took "Share link" away: send the file, never nothing.
            guard linkAllowedNow else {
                presentVerifiedSystemShare()
                return
            }
            guard let packageURL = coordinator.verifiedShareFileURL else { return }
            linkSender.makeLink(packageURL: packageURL, isSpokenNote: coordinator.sharedItemIsSpokenNote)
            #else
            presentVerifiedSystemShare()
            #endif
        }
    }

    private func shareError(_ snapshot: Build23SharingSnapshot) -> String? {
        if case .failed(let message) = snapshot.previewState { return message }
        if snapshot.previewState == .stale { return ShareReviewCardWords.staleSelection }
        return snapshot.errorMessage
    }

    private func finishSystemShare() {
        verifiedShareURLForPresentation = nil
        coordinator.send(.returnFromSystemShare)
    }
}

/// How the listener asked to send while the packet was still being made (#3750).
enum Build23PendingShare: Equatable {
    case file
    case link
}

/// When a share the listener asked for still matches what the screen shows (#3751 audit). Going back to the
/// selection, or any change that discards the packet, drops it, so no share sheet opens for Margins they removed.
enum Build23ShareRequestPolicy {
    /// A link being made, or made and not yet shared, is for the packet on screen only while that packet is ready and
    /// the listener is past the selection.
    static func keepsLink(stage: Build23SharingStage, previewState: Build23SharingPreviewState) -> Bool {
        stage != .select && previewState == .ready
    }

    /// A share asked for before the packet existed waits while it builds and is delivered once it's ready.
    static func keepsPendingShare(stage: Build23SharingStage, previewState: Build23SharingPreviewState) -> Bool {
        guard stage != .select else { return false }
        switch previewState {
        case .building, .ready: return true
        case .notBuilt, .stale, .failed: return false
        }
    }

    /// "Making link…" only while a link is made or asked for; a file asked for, or a plain preview, is not a link.
    static func showsMakingLink(isMakingLink: Bool, pendingShare: Build23PendingShare?) -> Bool {
        isMakingLink || pendingShare == .link
    }
}
