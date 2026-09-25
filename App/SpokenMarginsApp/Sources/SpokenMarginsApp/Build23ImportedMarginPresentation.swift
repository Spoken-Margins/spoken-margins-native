import SwiftUI
import SessionKit

enum SharedMarginLayerTint {
    static let colors: [Color] = [AppColors.plum, AppColors.green, AppColors.ochre, .indigo, .teal]

    static func color(at index: Int) -> Color { colors[index % colors.count] }
}

enum Build23ImportedLayerPresentation {
    static let provenanceSymbolName = "person.crop.circle"

    static func revealModeLabel(_ mode: ImportedCommentaryRevealMode) -> String {
        switch mode {
        case .fresh:
            return "Fresh"
        case .companion:
            return "Companion"
        case .guided:
            return "Guided"
        @unknown default:
            return "Companion"
        }
    }

    static func integrityLabel(_ status: ImportedCommentaryIntegrityStatus) -> String {
        switch status {
        case .integrityCheckedUnsigned:
            return "Integrity checked · sender not cryptographically verified"
        @unknown default:
            return "Integrity status unavailable"
        }
    }

    static func sourceResolutionLabel(_ status: ImportedSourceResolutionStatus) -> String {
        switch status {
        case .pending:
            return "Matching positions in your episode"
        case .resolved:
            return "Resolved"
        case .contextOnly:
            return "Context only"
        case .ambiguous:
            return "Ambiguous"
        case .wrongSource:
            return "Wrong source"
        case .unavailable:
            return "Unavailable"
        @unknown default:
            return "Unavailable"
        }
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
            return "Ambiguous"
        case .absentFromRecipientEdition:
            return "Position not matched in this edition"
        case .unresolved:
            return "Unresolved"
        @unknown default:
            return "Unresolved"
        }
    }

    static func provenanceAccessibilityLabel(for layer: Build23ImportedLayerSnapshot) -> String {
        let enabledLabel = layer.isEnabled ? "Layer enabled" : "Layer disabled"
        let mutedLabel = layer.isMuted ? "Layer muted" : "Layer not muted"
        let proposalLabel = layer.listeningMapProposalCount == 1
            ? "1 listening map proposal"
            : "\(layer.listeningMapProposalCount) listening map proposals"

        return [
            "Imported Margins, separate shared layer",
            "Sender label \(layer.senderLabel)",
            integrityLabel(layer.integrity),
            "Source resolution \(sourceResolutionLabel(layer.sourceResolution))",
            enabledLabel,
            mutedLabel,
            "Reveal mode \(revealModeLabel(layer.revealMode))",
            proposalLabel
        ].joined(separator: ". ")
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

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layers == rhs.layers && lhs.coordinator === rhs.coordinator && lhs.showsMargins == rhs.showsMargins
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shared Margins")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppColors.text)

            if layers.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 16) {
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
        let tint = SharedMarginLayerTint.color(at: layers.firstIndex(where: { $0.id == layer.id }) ?? 0)
        return ExperienceSurface(tint: tint.opacity(0.09)) {
            VStack(alignment: .leading, spacing: 16) {
                provenanceHeader(layer, tint: tint)
                if showsMargins { marginRail(layer, tint: tint) }

                DisclosureGroup("Layer options") {
                    VStack(alignment: .leading, spacing: 12) {
                        layerStateControls(layer)
                        Label(proposalCountLabel(layer.listeningMapProposalCount), systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.text)
            }
        }
    }

    private func provenanceHeader(_ layer: Build23ImportedLayerSnapshot, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shared by \(layer.senderLabel)")
                        .font(.headline)
                        .foregroundStyle(AppColors.text)
                    Text("Separate imported layer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
            } icon: {
                Image(systemName: Build23ImportedLayerPresentation.provenanceSymbolName)
                    .foregroundStyle(tint)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(
                Build23ImportedLayerPresentation.provenanceAccessibilityLabel(for: layer)
            ))
            .accessibilityIdentifier("build23.imported.layer.\(layer.id).provenance")

            Text(layer.itemTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.text)

            VStack(alignment: .leading, spacing: 8) {
                stateLabel(
                    Build23ImportedLayerPresentation.integrityLabel(layer.integrity),
                    systemImage: "checkmark.shield"
                )
                stateLabel(
                    "Source resolution: \(Build23ImportedLayerPresentation.sourceResolutionLabel(layer.sourceResolution))",
                    systemImage: "scope"
                )
            }
        }
    }

    private func layerStateControls(_ layer: Build23ImportedLayerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "Layer enabled",
                isOn: Binding(
                    get: { layer.isEnabled },
                    set: { coordinator.send(.setLayerEnabled(id: layer.id, enabled: $0)) }
                )
            )
            .tint(AppColors.evergreen)

            Toggle(
                "Layer muted",
                isOn: Binding(
                    get: { layer.isMuted },
                    set: { coordinator.send(.setLayerMuted(id: layer.id, muted: $0)) }
                )
            )
            .tint(AppColors.evergreen)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label("Reveal mode", systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.text)

                Spacer(minLength: 12)

                Picker(
                    "Reveal mode",
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
                        Text(Build23ImportedLayerPresentation.revealModeLabel(mode))
                            .tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityValue(Text(
                    Build23ImportedLayerPresentation.revealModeLabel(layer.revealMode)
                ))
                .accessibilityIdentifier("build23.imported.layer.\(layer.id).reveal-mode")
            }
        }
    }

    @ViewBuilder
    private func marginRail(_ layer: Build23ImportedLayerSnapshot, tint: Color) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            Text("Margin placement")
                .font(.headline)
                .foregroundStyle(AppColors.text)

            if layer.margins.isEmpty {
                Text("No Margins in this layer")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            } else {
                ForEach(layer.margins) { margin in
                    marginCard(margin, layerID: layer.id, tint: tint)
                }
            }
        }
    }

    private func marginCard(_ margin: Build23ImportedMarginSnapshot, layerID: String, tint: Color) -> some View {
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

            Label(
                Build23ImportedLayerPresentation.marginResolutionLabel(margin.resolution),
                systemImage: "scope"
            )
            .font(.caption)
            .foregroundStyle(AppColors.secondaryText)
            .accessibilityLabel(
                Text("Placement resolution. \(Build23ImportedLayerPresentation.marginResolutionLabel(margin.resolution))")
            )

            if margin.hasVoice {
                Button {
                    coordinator.send(.listenToMargin(layerID: layerID, marginID: margin.id))
                } label: {
                    Label("Listen", systemImage: "play.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("build23.imported.margin.\(margin.id).listen")
            }
            if margin.canReviewPosition {
                Button {
                    coordinator.send(.listenAroundPosition(layerID: layerID, marginID: margin.id))
                } label: {
                    Label(margin.listenAroundLabel, systemImage: "waveform.path")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("build23.imported.margin.\(margin.id).listen-around")

                if margin.canConfirmPosition {
                    Text("After listening, confirm the position shown in your episode. This is your choice, not audio verification.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                    Button {
                        coordinator.send(.confirmPosition(layerID: layerID, marginID: margin.id))
                    } label: {
                        Label("Confirm current source position", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("build23.imported.margin.\(margin.id).confirm-position")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.45), lineWidth: 1)
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
            return "1 listening map proposal"
        }
        return "\(count) listening map proposals"
    }

    private var emptyState: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 8) {
                Label("No imported layers", systemImage: "square.3.layers.3d")
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                Text("Imported shared Margins will appear here as separate layers.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }
}
