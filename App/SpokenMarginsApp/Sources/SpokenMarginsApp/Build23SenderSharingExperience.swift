import Foundation
import SwiftUI

@MainActor
struct Build23SenderSharingExperience: View {
    @ObservedObject var coordinator: Build23SharingCoordinator

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var hasBegun = false
    @State private var isSystemSharePresented = false
    @State private var verifiedShareURLForPresentation: URL?

    var body: some View {
        let snapshot = coordinator.snapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    Text("Share Margins")
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        coordinator.send(.cancel)
                    }
                    .accessibilityIdentifier("build23.sender.cancel")
                }

                Build23SharingStageProgress(currentStage: snapshot.stage)

                stageContent(snapshot)
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(AppColors.bone.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("build23.sender.experience")
        .onAppear {
            guard !hasBegun else { return }
            hasBegun = true
            coordinator.send(.begin)
        }
        .sheet(isPresented: $isSystemSharePresented, onDismiss: finishSystemShare) {
            if let packageURL = verifiedShareURLForPresentation {
                SharedSpokenMarginsPackageActivityView(packageURL: packageURL)
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

    private func selectStage(_ snapshot: Build23SharingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ExperienceEditorialHeader(
                eyebrow: "1 · Select",
                title: "Choose exactly what crosses the boundary",
                detail: "Review each Margin, its voice representation, and the context the recipient will use to place it."
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("build23.sender.stage.select")

            senderDetails(snapshot)
            Build23TransportConsequenceCard(
                transport: snapshot.transport,
                rightsConfirmed: snapshot.confirmsPrivateSharingRights
            )

            ExperienceSurface(tint: AppColors.ochre.opacity(0.12)) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Starred is the default shortlist", systemImage: "star.fill")
                        .font(.headline)
                        .foregroundStyle(AppColors.ochre)
                    Text("A star only controls which Margins are easy to find. It never adds a Margin to the package; only the Include switch does that.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            .accessibilityIdentifier("build23.sender.starred-explanation")

            filterBar(snapshot)
            selectMarginGrid(snapshot)

            if let errorMessage = snapshot.errorMessage, !errorMessage.isEmpty {
                Build23StatusLabel(icon: "exclamationmark.triangle.fill", title: errorMessage, tint: AppColors.plum)
                    .accessibilityIdentifier("build23.sender.error")
            }

            HStack {
                Spacer()
                Button("Continue to review", systemImage: "arrow.right") {
                    advanceToReview(from: snapshot)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
                .disabled(!snapshot.canAdvance || snapshot.isPreparingAll)
                .accessibilityHint(snapshot.canAdvance ? "Moves to package review" : "Include at least one eligible Margin first")
                .accessibilityIdentifier("build23.sender.select.continue")
            }
        }
    }

    private func senderDetails(_ snapshot: Build23SharingSnapshot) -> some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Item being shared")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                Text(snapshot.itemTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppColors.text)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Sender and permissions")
                    .font(.headline)

                TextField(
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
                .accessibilityHint("Controls whether supported listening evidence travels with the package")
                .accessibilityIdentifier("build23.sender.include-acoustic-evidence")

                if Build23SenderPresentation.showsLinklessRightsControl(for: snapshot.transport) {
                    Toggle(
                        "I have the right to privately embed this linkless material",
                        isOn: Binding(
                            get: { snapshot.confirmsPrivateSharingRights },
                            set: { coordinator.send(.setPrivateSharingRightsConfirmed($0)) }
                        )
                    )
                    .accessibilityHint("When disabled, Margins can still be sent without embedding the item; the recipient supplies the source")
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
                        isSelected: snapshot.selectedMarginID == margin.id,
                        onSelect: { coordinator.send(.selectMargin(margin.id)) },
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
                        isSelected: snapshot.selectedMarginID == margin.id,
                        onSelect: { coordinator.send(.selectMargin(margin.id)) },
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
                reviewMarginList(includedMargins, selectedEditorID: selectedEditorID)
                marginEditors(expandedMargins)
            }
        }
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
            ExperienceEditorialHeader(
                eyebrow: "2 · Review",
                title: "Confirm the package before it is written",
                detail: "This is the sender-side draft. The next step writes the package and reads it back before showing the recipient view."
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("build23.sender.stage.review")

            Build23TransportConsequenceCard(
                transport: snapshot.transport,
                rightsConfirmed: snapshot.confirmsPrivateSharingRights
            )

            ExperienceSurface {
                VStack(alignment: .leading, spacing: 8) {
                    Text(snapshot.itemTitle)
                        .font(.title3.weight(.semibold))
                    Label("From \(snapshot.senderDisplayLabel)", systemImage: "person.crop.circle")
                        .font(.subheadline)
                    Label(
                        snapshot.includesAcousticEvidence ? "Acoustic evidence included when available" : "Acoustic evidence excluded",
                        systemImage: snapshot.includesAcousticEvidence ? "waveform.path.ecg" : "waveform.path.ecg.rectangle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                }
            }

            reviewComposition(snapshot)

            Build23BatchPreparationCard(
                isPreparing: snapshot.isPreparingAll,
                completed: snapshot.preparationCompleted,
                total: snapshot.preparationTotal,
                failures: snapshot.preparationFailures,
                canPrepare: snapshot.margins.contains(where: { $0.isIncluded && $0.canPrepareCleanup }),
                onPrepare: { coordinator.send(.prepareAllIncluded) },
                onCancel: { coordinator.send(.cancelPreparation) }
            )

            if let errorMessage = snapshot.errorMessage, !errorMessage.isEmpty {
                Build23StatusLabel(icon: "exclamationmark.triangle.fill", title: errorMessage, tint: AppColors.plum)
            }

            HStack(spacing: 12) {
                Button("Back to selection", systemImage: "arrow.left") {
                    coordinator.send(.returnToSelect)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("build23.sender.review.back")

                Spacer()

                Button("Build recipient preview", systemImage: "checkmark.seal") {
                    coordinator.send(.buildRecipientPreview)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.evergreen)
                .disabled(!snapshot.canAdvance)
                .accessibilityHint("Writes and verifies the package before showing the recipient view")
                .accessibilityIdentifier("build23.sender.preview.build")
            }
        }
        .onAppear(perform: normalizeReviewSelection)
    }

    private func recipientPreviewStage(_ snapshot: Build23SharingSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ExperienceEditorialHeader(
                eyebrow: "3 · Recipient Preview",
                title: "See only what the verified package contains",
                detail: "This projection was read back from the written package rather than reconstructed from the sender draft."
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("build23.sender.stage.recipient-preview")

            switch snapshot.previewState {
            case .building:
                ExperienceSurface(tint: AppColors.softGreen) {
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView()
                            .tint(AppColors.evergreen)
                        Build23StatusLabel(
                            icon: "doc.badge.gearshape",
                            title: "Writing, reading back, and verifying the recipient package…",
                            tint: AppColors.evergreen
                        )
                    }
                }
                .accessibilityIdentifier("build23.sender.preview.building")

            case .ready:
                if let verifiedPreview = snapshot.verifiedPreview {
                    Build23VerifiedRecipientPreviewPanel(preview: verifiedPreview)

                    HStack(spacing: 12) {
                        Button("Edit selection", systemImage: "arrow.left") {
                            coordinator.send(.returnToSelect)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("build23.sender.preview.edit")

                        Spacer()

                        Button("Share verified package", systemImage: "square.and.arrow.up") {
                            presentVerifiedSystemShare()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.evergreen)
                        .disabled(!snapshot.canShareVerifiedFile || coordinator.verifiedShareFileURL == nil)
                        .accessibilityHint("Opens the system share sheet with the verified package file")
                        .accessibilityIdentifier("build23.sender.share.present")
                    }
                } else {
                    unavailablePreview(
                        title: "The verified projection is unavailable.",
                        detail: "Return to review and build the recipient preview again."
                    )
                }

            case .stale:
                unavailablePreview(
                    title: "The recipient preview is stale.",
                    detail: "A package-affecting choice changed. Build and verify a fresh preview before sharing."
                )

            case let .failed(message):
                unavailablePreview(
                    title: "The package could not be verified.",
                    detail: message
                )

            case .notBuilt:
                unavailablePreview(
                    title: "No verified recipient preview is available.",
                    detail: "Return to review and build the package first."
                )
            }
        }
    }

    private func unavailablePreview(title: String, detail: String) -> some View {
        ExperienceSurface(tint: AppColors.ochre.opacity(0.12)) {
            VStack(alignment: .leading, spacing: 10) {
                Build23StatusLabel(icon: "exclamationmark.triangle.fill", title: title, tint: AppColors.plum)
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
            ExperienceEditorialHeader(
                eyebrow: "4 · Share",
                title: "The verified file is ready for the system share sheet",
                detail: "Sharing never substitutes a draft URL or an unverified package."
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("build23.sender.stage.share")

            if coordinator.verifiedShareFileURL != nil, snapshot.canShareVerifiedFile {
                ExperienceSurface(tint: AppColors.softGreen) {
                    Build23StatusLabel(
                        icon: "square.and.arrow.up.circle.fill",
                        title: isSystemSharePresented ? "System share sheet open" : "Verified package ready",
                        tint: AppColors.evergreen
                    )
                }

                if !isSystemSharePresented {
                    HStack {
                        Button("Return to recipient preview", systemImage: "arrow.left") {
                            coordinator.send(.returnFromSystemShare)
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("Open system share sheet", systemImage: "square.and.arrow.up") {
                            presentVerifiedSystemShare()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.evergreen)
                        .accessibilityIdentifier("build23.sender.share.reopen")
                    }
                }
            } else {
                unavailablePreview(
                    title: "The verified share file is no longer available.",
                    detail: "Return to selection and build a fresh recipient preview."
                )
            }
        }
    }

    private func setIncluded(_ included: Bool, marginID: String) {
        coordinator.send(.setIncluded(id: marginID, included: included))
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

    private func finishSystemShare() {
        verifiedShareURLForPresentation = nil
        coordinator.send(.returnFromSystemShare)
    }
}
