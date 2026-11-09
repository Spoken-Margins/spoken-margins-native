import SwiftUI
import SessionKit

enum Build23ImportedLayerPresentation {
    static let provenanceSymbolName = "person.crop.circle"

    /// How the friend's Margins play, in the friend's words (`FriendArrivalWords`).
    static func playModeLabel(_ mode: ImportedCommentaryRevealMode) -> String {
        FriendArrivalWords.playModeLabel(mode)
    }

    static func marginResolutionLabel(_ resolution: AnchorResolutionEvidenceClass) -> String {
        switch resolution {
        case .exactEdition:
            return "Exact edition"
        case .articleTextVerified:
            return "Article text verified"
        case .transcriptVerified:
            return "Transcript verified"
        case .acousticVerified:
            return "Audio verified"
        case .fused:
            return "Combined evidence"
        case .mapInterpolated:
            return "Listening map estimate"
        case .timestampFallback:
            return "Approximate timestamp"
        case .recipientConfirmed:
            return "Recipient confirmed"
        case .ambiguous:
            return "Could fit more than one place"
        case .absentFromRecipientEdition:
            return "Not found in this edition"
        case .unresolved:
            return "Unresolved"
        @unknown default:
            return "Unresolved"
        }
    }

    static func provenanceAccessibilityLabel(for layer: Build23ImportedLayerSnapshot) -> String {
        FriendArrivalWords.layerAccessibilityLabel(
            senderLabel: layer.senderLabel, isEnabled: layer.isEnabled, isMuted: layer.isMuted,
            mode: layer.revealMode, placementProblem: FriendArrivalWords.placementProblem(layer.sourceResolution)
        )
    }
}

@MainActor
struct Build23ImportedMarginPresentation: View {
    @ObservedObject var coordinator: Build23SharingCoordinator

    var showsMargins = true

    var body: some View {
        Build23ImportedLayerList(layers: coordinator.importedLayers, coordinator: coordinator, showsMargins: showsMargins)
            .equatable()
    }
}

private struct Build23ImportedLayerList: View, Equatable {
    let layers: [Build23ImportedLayerSnapshot]
    let coordinator: Build23SharingCoordinator
    let showsMargins: Bool
    /// The card whose "Hide this sender" was tapped, until the listener confirms or cancels (#2846).
    @State private var pendingHide: Build23ImportedLayerSnapshot?
    /// The layer and Margin ids of the Margin the listener is being asked to hide (#2846).
    @State private var pendingHideMargin: HideMarginRequest?

    private struct HideMarginRequest: Identifiable, Equatable {
        let layerID: String
        let marginID: String
        var id: String { marginID }
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layers == rhs.layers && lhs.coordinator === rhs.coordinator && lhs.showsMargins == rhs.showsMargins
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(FriendArrivalWords.sectionTitle(senderLabels: layers.map(\.senderLabel)))
                .font(.title3.weight(.bold))
                .screenTitle()
                .foregroundStyle(AppColors.text)

            if layers.isEmpty {
                emptyState
            } else {
                // A plain stack: nothing on the item screen is lazy; a lazy stack there froze the screen on scroll (#3781).
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(layers) { layer in
                        layerCard(layer)
                    }
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func layerCard(_ layer: Build23ImportedLayerSnapshot) -> some View {
        ExperienceSurface(tint: AppColors.plum.opacity(0.08)) {
            VStack(alignment: .leading, spacing: 16) {
                provenanceHeader(layer)
                if showsMargins { marginRail(layer) }

                // The honest note and the controls a listener may still want sit behind one plain title (#3247).
                DisclosureGroup(FriendArrivalWords.aboutTitle) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(FriendArrivalWords.aboutNote)
                            .font(.footnote)
                            .foregroundStyle(AppColors.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        layerStateControls(layer)
                        // A file with no Listening Map proposals says nothing: "0 Listening Map suggestions" is engineering words
                        // to a friend whose file never held one (#3247, "what passes silently stays silent").
                        if layer.listeningMapProposalCount > 0 {
                            Label(proposalCountLabel(layer.listeningMapProposalCount), systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.subheadline)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.text)
            }
        }
    }

    private func provenanceHeader(_ layer: Build23ImportedLayerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(FriendArrivalWords.fromLine(senderLabel: layer.senderLabel))
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                }
            } icon: {
                Image(systemName: Build23ImportedLayerPresentation.provenanceSymbolName)
                    .foregroundStyle(AppColors.plum)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(
                Build23ImportedLayerPresentation.provenanceAccessibilityLabel(for: layer)
            ))
            .accessibilityIdentifier("build23.imported.layer.\(layer.id).provenance")

            Text(layer.itemTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.text)

            // A passing check says nothing; only a problem with placing the Margins shows (#3247).
            if let problem = FriendArrivalWords.placementProblem(layer.sourceResolution) {
                stateLabel(problem, systemImage: "scope")
            }
        }
    }

    private func layerStateControls(_ layer: Build23ImportedLayerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "\(FriendArrivalWords.possessiveMargins(senderLabel: layer.senderLabel)) on",
                isOn: Binding(
                    get: { layer.isEnabled },
                    set: { coordinator.send(.setLayerEnabled(id: layer.id, enabled: $0)) }
                )
            )
            .tint(AppColors.evergreen)

            Toggle(
                "Mute \(FriendArrivalWords.possessiveMargins(senderLabel: layer.senderLabel))",
                isOn: Binding(
                    get: { layer.isMuted },
                    set: { coordinator.send(.setLayerMuted(id: layer.id, muted: $0)) }
                )
            )
            .tint(AppColors.evergreen)

            AdaptiveStack(alignment: .firstTextBaseline, spacing: 12) {
                Label(FriendArrivalWords.playModeTitle, systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.text)

                AdaptiveSpacer(minLength: 12)

                Picker(
                    FriendArrivalWords.playModeTitle,
                    selection: Binding(
                        get: { layer.revealMode.rawValue },
                        set: { rawValue in
                            guard let mode = ImportedCommentaryRevealMode(rawValue: rawValue) else {
                                return
                            }
                            coordinator.send(.setLayerRevealMode(id: layer.id, mode: mode))
                        }
                    )
                ) {
                    ForEach(ImportedCommentaryRevealMode.allCases, id: \.rawValue) { mode in
                        Text(Build23ImportedLayerPresentation.playModeLabel(mode))
                            .tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityValue(Text(
                    Build23ImportedLayerPresentation.playModeLabel(layer.revealMode)
                ))
                .accessibilityIdentifier("build23.imported.layer.\(layer.id).reveal-mode")
            }

            // Opens the share page, where the report form is; no account is needed and the page needs no key (#2846).
            if let reportURL = layer.reportURL {
                Link(destination: reportURL) {
                    Label("Report this link", systemImage: "flag")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityHint("Opens the share page in your browser, where you can report this link.")
                .accessibilityIdentifier("build23.imported.layer.\(layer.id).report")
            }

            // Only for Margins whose packet named a sender; an older packet has none, so there is nothing to hide by (#2846).
            if layer.senderId != nil {
                Button(role: .destructive) {
                    pendingHide = layer
                } label: {
                    Label("Hide this sender", systemImage: "eye.slash")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityHint("Hides every Margin from this sender on this phone. You can show them again in Settings.")
                .accessibilityIdentifier("build23.imported.layer.\(layer.id).hide-sender")
                .confirmationDialog(
                    "Hide this sender?",
                    isPresented: Binding(get: { pendingHide?.id == layer.id }, set: { if !$0 { pendingHide = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("Hide this sender", role: .destructive) {
                        coordinator.send(.hideSender(layerID: layer.id))
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(FriendArrivalWords.hideSenderMessage)
                }
            }
        }
    }

    @ViewBuilder
    private func marginRail(_ layer: Build23ImportedLayerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Margin placement")
                .font(.headline)
                .foregroundStyle(AppColors.text)

            if layer.margins.isEmpty {
                Text("No Margins here")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            } else {
                ForEach(layer.margins) { margin in
                    marginCard(margin, layerID: layer.id)
                }
            }
        }
    }

    private func marginCard(_ margin: Build23ImportedMarginSnapshot, layerID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(margin.reviewedText)
                .font(.body)
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)

            Label(margin.positionDescription, systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Margin placement. \(margin.positionDescription)")

            if let label = resolutionLabel(margin) {
                Label(label, systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityLabel(Text("Placement resolution. \(label)"))
            }

            if margin.canListen {
                Button {
                    coordinator.send(.listenToMargin(layerID: layerID, marginID: margin.id))
                } label: {
                    Label("Listen", systemImage: "play.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("build23.imported.margin.\(margin.id).listen")
            }

            Button(role: .destructive) {
                pendingHideMargin = HideMarginRequest(layerID: layerID, marginID: margin.id)
            } label: {
                Label("Hide this Margin", systemImage: "eye.slash")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityHint("Hides this one Margin on this phone. You can show it again in Settings.")
            .accessibilityIdentifier("build23.imported.margin.\(margin.id).hide")
            .confirmationDialog(
                "Hide this Margin?",
                isPresented: Binding(
                    get: { pendingHideMargin?.marginID == margin.id },
                    set: { if !$0 { pendingHideMargin = nil } }),
                titleVisibility: .visible
            ) {
                Button("Hide this Margin", role: .destructive) {
                    coordinator.send(.hideMargin(layerID: layerID, marginID: margin.id))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(FriendArrivalWords.hideMarginMessage)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.panel)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppColors.border, lineWidth: 1)
        }
    }

    /// How the place was found, as a second line under the position. A Margin that wasn't placed has nothing to add
    /// to "Couldn't place this one" (#1974), so it gets no second line; one still being placed says so.
    private func resolutionLabel(_ margin: Build23ImportedMarginSnapshot) -> String? {
        if let placementLabel = margin.placementLabel { return placementLabel }
        switch margin.resolution {
        case .unresolved, .absentFromRecipientEdition, .ambiguous: return nil
        default: return Build23ImportedLayerPresentation.marginResolutionLabel(margin.resolution)
        }
    }

    private func stateLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(AppColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func proposalCountLabel(_ count: Int) -> String {
        if count == 1 {
            return "1 Listening Map suggestion"
        }
        return "\(count) Listening Map suggestions"
    }

    private var emptyState: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 8) {
                Label("No Margins from friends yet", systemImage: "square.3.layers.3d")
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                Text("Margins from friends will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }
}
