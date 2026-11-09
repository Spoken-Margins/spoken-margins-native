import Foundation
import SessionKit
import SessionKitSharing
import SwiftUI

@MainActor
struct Build23SenderSharingExperience: View {
    @ObservedObject var coordinator: Build23SharingCoordinator

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var hasBegun = false
    @State private var isSystemSharePresented = false
    @State private var verifiedShareURLForPresentation: URL?
    @State private var isAutoCleanChoicePresented = false
    /// What the listener asked for while the packet was still being made; delivered once it is ready.
    @State private var pendingShare: Build23PendingShare?
    @State private var showsSharingOptions = false
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
            .modifier(ShareLinkPresentation(sender: linkSender, packageURL: coordinator.verifiedShareFileURL) { packet in
                coordinator.recordSystemShareCompleted(packetURL: packet)
            })
            .task { isLinkOffered = await linkSender.isOffered() }
        #else
        content
        #endif
    }

    /// Whether the main Share button makes a link. False in a build without links, and while the server says no.
    private var sharesLink: Bool {
        #if SM_SHARE_LINK_CREATION
        isLinkOffered
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

    @ViewBuilder
    private var screen: some View {
        let snapshot = coordinator.snapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    Text(coordinator.senderHeading)
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                        .accessibilityIdentifier("build23.sender.heading")
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        coordinator.send(.cancel)
                    }
                    .accessibilityIdentifier("build23.sender.cancel")
                }
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
                    linkStatusLines
                    primaryAction(snapshot)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
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
            isAutoCleanChoicePresented = coordinator.snapshot.needsAutoCleanDecision
        }
        .onCompatibleChange(of: snapshot.previewState) { previewState in
            let stage = coordinator.snapshot.stage
            if previewState == .ready, stage != .select, let requested = pendingShare {
                pendingShare = nil
                deliver(requested)
                return
            }
            dropStaleShareRequests(stage: stage, previewState: previewState)
        }
        .onCompatibleChange(of: snapshot.stage) { stage in
            dropStaleShareRequests(stage: stage, previewState: coordinator.snapshot.previewState)
            announceStage(stage)
        }
        .alert("Clean selected Margins automatically?", isPresented: $isAutoCleanChoicePresented) {
            Button("Clean selected") {
                coordinator.send(.setAutoCleanSelectedEnabled(true))
            }
            Button("Not now", role: .cancel) {
                coordinator.send(.setAutoCleanSelectedEnabled(false))
            }
        } message: {
            Text("Spoken Margins can remove filler words and tighten pauses for the Margins you include. You can review every change, undo it, or turn this off later.")
        }
        .sheet(isPresented: $isSystemSharePresented, onDismiss: finishSystemShare) {
            if let packageURL = verifiedShareURLForPresentation {
                SharedSpokenMarginsPackageActivityView(packageURL: packageURL) { coordinator.recordSystemShareCompleted(packetURL: packageURL) }
            }
        }
    }

    @ViewBuilder
    private func stageContent(_ snapshot: Build23SharingSnapshot) -> some View {
        switch snapshot.stage {
        case .select:
            selectStage(snapshot)
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
            .disabled(!snapshot.canAdvance || snapshot.isPreparingAll)
            .accessibilityIdentifier("build23.sender.select.continue")
        case .review where sharesLink:
            linkShareButton(isWorking: Build23ShareRequestPolicy.showsMakingLink(isMakingLink: isMakingLink, pendingShare: pendingShare))
                .disabled(!snapshot.canAdvance || isMakingLink)
                .accessibilityIdentifier("build23.sender.review.share")
        case .review:
            Button("Share \(includedCount)", systemImage: "square.and.arrow.up") {
                shareVerifiedPackage()
            }
            .filledActionButton()
            .disabled(!snapshot.canAdvance)
            .accessibilityIdentifier("build23.sender.review.share")
        case .recipientPreview where sharesLink:
            linkShareButton(isWorking: Build23ShareRequestPolicy.showsMakingLink(isMakingLink: isMakingLink, pendingShare: pendingShare))
                .disabled(snapshot.previewState != .ready || isMakingLink)
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
        let lines = ShareLinkStatusLines(state: linkSender.state, companionNote: linkSender.companionNote)
        if sharesLink, lines.hasLines {
            lines
        }
        #endif
    }

    /// "Send as a file", the second choice beside a Share button that makes a link.
    private func sendFileButton(enabled: Bool, identifier: String) -> some View {
        Button("Send as a file", systemImage: "doc") {
            share(.file)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
        .accessibilityHint("Opens the share sheet with your Margins as a file")
        .accessibilityIdentifier(identifier)
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

    private func selectionControls(_ snapshot: Build23SharingSnapshot) -> some View {
        let visibleMargins = Build23SenderPresentation.filteredMargins(in: snapshot)
        let includedCount = snapshot.margins.filter(\.isIncluded).count
        return ExperienceSurface(tint: AppColors.softGreen) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(VoiceOverAnnouncements.SharingStep.select.title)
                        .font(.title3.weight(.semibold))
                        .screenTitle()
                    Text("\(includedCount) of \(snapshot.margins.count) selected")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                    Build23WrappingLayout(spacing: 8) {
                        Button("Select all shown") {
                            setVisibleIncluded(true, margins: visibleMargins)
                        }
                        Button("Select none shown") {
                            setVisibleIncluded(false, margins: visibleMargins)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(snapshot.isPreparingAll || visibleMargins.isEmpty)
                }

                Divider()

                Toggle(
                    "Clean selected automatically",
                    isOn: Binding(
                        get: { snapshot.autoCleanSelectedEnabled },
                        set: { coordinator.send(.setAutoCleanSelectedEnabled($0)) }
                    )
                )
                .font(.headline)
                .accessibilityIdentifier("build23.sender.auto-clean")

                Text(snapshot.autoCleanSelectedEnabled
                    ? "On for this and future shares. Turn it off to undo cleanup applied automatically to this draft."
                    : "Off. You can still clean individual Margins during review.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)

                if snapshot.isPreparingAll {
                    ProgressView(
                        value: Double(snapshot.preparationCompleted),
                        total: Double(max(snapshot.preparationTotal, 1))
                    )
                    .tint(AppColors.evergreen)
                    AdaptiveStack {
                        Text("Cleaning \(snapshot.preparationCompleted) of \(snapshot.preparationTotal)")
                            .font(.subheadline)
                        AdaptiveSpacer()
                        Button("Cancel", role: .cancel) {
                            coordinator.send(.cancelPreparation)
                        }
                    }
                } else if snapshot.preparationTotal > 0 {
                    if snapshot.preparationFailures == 0 {
                        Build23StatusLabel(
                            icon: "checkmark.circle.fill",
                            title: "Cleaned \(snapshot.preparationCompleted) selected Margins",
                            tint: AppColors.evergreen
                        )
                    } else {
                        FailureMessageLabel("Cleaned \(snapshot.preparationCompleted - snapshot.preparationFailures); \(snapshot.preparationFailures) kept their available Original or Text version.")
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
                        isEnabled: !snapshot.isPreparingAll,
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
                        isEnabled: !snapshot.isPreparingAll,
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
                reviewMarginList(includedMargins, selectedEditorID: selectedEditorID)
                    .frame(maxWidth: 340)
                marginEditors(expandedMargins)
                    .frame(maxWidth: .infinity)
            }
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
        selectedEditorID: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Included Margins")
                .font(.headline)
                .accessibilityIdentifier("build23.sender.review.margin-list")
            ForEach(margins) { margin in
                Build23ReviewSelectionRow(
                    margin: margin,
                    isSelected: selectedEditorID == margin.id,
                    onSelect: { coordinator.send(.selectMargin(margin.id)) }
                )
            }
        }
    }

    private func reviewStage(_ snapshot: Build23SharingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            reviewComposition(snapshot)

            Text(VoiceOverAnnouncements.SharingStep.review.title)
                .font(.headline)
                .foregroundStyle(AppColors.text)
                .screenTitle()
                .accessibilityIdentifier("build23.sender.stage.review")

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

            AdaptiveStack(spacing: 12) {
                Button("Back to selection", systemImage: "arrow.left") {
                    coordinator.send(.returnToSelect)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("build23.sender.review.back")

                if sharesLink {
                    sendFileButton(enabled: snapshot.canAdvance && !isMakingLink, identifier: "build23.sender.review.share.file")
                }

                Button("Preview what your friend gets", systemImage: "doc.text.magnifyingglass") {
                    coordinator.send(.buildRecipientPreview)
                }
                .buttonStyle(.bordered)
                .disabled(!snapshot.canAdvance)
                .accessibilityHint("Optionally shows what your friend will get")
                .accessibilityIdentifier("build23.sender.preview.build")
            }
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
                        onEdit: { coordinator.send(.returnToSelect) },
                        onShareFile: presentVerifiedSystemShare
                    )

                    Build23VerifiedRecipientPreviewPanel(preview: verifiedPreview)
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
                Button("Back to selection", systemImage: "arrow.left") {
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
        let includedMargins = snapshot.margins.filter(\.isIncluded)
        if let selectedMarginID = snapshot.selectedMarginID,
           includedMargins.contains(where: { $0.id == selectedMarginID }) {
            return
        }
        coordinator.send(.selectMargin(includedMargins.first?.id))
    }

    private func applyFilter(_ filter: ShareMarginDraftFilter) {
        coordinator.send(.setFilter(filter))
        let refreshed = coordinator.snapshot
        let visibleMargins = Build23SenderPresentation.filteredMargins(in: refreshed)
        if let selectedMarginID = refreshed.selectedMarginID,
           visibleMargins.contains(where: { $0.id == selectedMarginID }) {
            return
        }
        coordinator.send(.selectMargin(visibleMargins.first?.id))
    }

    private func presentVerifiedSystemShare() {
        coordinator.send(.presentSystemShare)
        guard let verifiedURL = coordinator.verifiedShareFileURL else { return }
        verifiedShareURLForPresentation = verifiedURL
        isSystemSharePresented = true
    }

    /// Share the way the main button does: a link when this build makes them and the server allows it, else the file.
    private func shareVerifiedPackage() {
        share(sharesLink ? .link : .file)
    }

    /// Makes the packet if it isn't ready, then sends it the way the listener asked.
    private func share(_ kind: Build23PendingShare) {
        if coordinator.verifiedShareFileURL != nil {
            deliver(kind)
            return
        }
        pendingShare = kind
        coordinator.send(.buildRecipientPreview)
        // Export can fail synchronously, before SwiftUI observes .building.
        if case .failed = coordinator.previewState { pendingShare = nil }
    }

    /// The stage is replaced in place and focus can stay on the bottom button, so say where the sheet is now (#3728).
    /// `onCompatibleChange` hands over only the new value, so the previous stage is kept in `announcedStage`.
    private func announceStage(_ stage: Build23SharingStage) {
        let step = Self.step(for: stage)
        if let text = VoiceOverAnnouncements.sharingStage(from: announcedStage, to: step) {
            AccessibilityNotification.Announcement(text).post()
        }
        announcedStage = step
    }

    private static func step(for stage: Build23SharingStage) -> VoiceOverAnnouncements.SharingStep {
        switch stage {
        case .select: .select
        case .review: .review
        case .recipientPreview: .recipientPreview
        case .share: .share
        }
    }

    /// A share asked for, or a link being made, for a packet the screen no longer shows is dropped (#3751 audit).
    private func dropStaleShareRequests(stage: Build23SharingStage, previewState: Build23SharingPreviewState) {
        if !Build23ShareRequestPolicy.keepsPendingShare(stage: stage, previewState: previewState) {
            pendingShare = nil
        }
        #if SM_SHARE_LINK_CREATION
        if !Build23ShareRequestPolicy.keepsLink(stage: stage, previewState: previewState), linkSender.state != .idle {
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
            guard let packageURL = coordinator.verifiedShareFileURL else { return }
            linkSender.makeLink(packageURL: packageURL)
            #else
            presentVerifiedSystemShare()
            #endif
        }
    }

    private func shareError(_ snapshot: Build23SharingSnapshot) -> String? {
        if case .failed(let message) = snapshot.previewState { return message }
        if snapshot.previewState == .stale { return "Your selection changed. Review it and share again." }
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
