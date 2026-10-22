import SwiftUI
import SessionKit

/// Which layers feed "Where people reacted" (#476). Every enabled layer is chosen until the listener
/// unchecks it, so a layer imported later is chosen too. Nothing here is stored: it resets on reopening.
struct ReactionsSelection: Equatable {
    static let ownId = "__you__"

    struct Choice: Identifiable, Equatable {
        let id: String
        let label: String
        let marginCount: Int
    }

    var unchecked: Set<String> = []

    func isChosen(_ id: String) -> Bool { !unchecked.contains(id) }

    mutating func set(_ id: String, chosen: Bool) {
        if chosen { unchecked.remove(id) } else { unchecked.insert(id) }
    }

    /// The people whose Margins can be picked: each enabled layer that has Margins, then the listener.
    static func choices(for item: ItemDetailState) -> [Choice] {
        var choices = item.importedCommentaryLayers
            .filter { $0.itemId == item.id && $0.isEnabled && $0.deletedAt == nil }
            .compactMap { layer -> Choice? in
                let count = item.importedCommentaryInterjections[layer.id, default: []].count
                return count == 0 ? nil : Choice(id: layer.id, label: MarginLayerSynthesis.label(layer.displayLabel), marginCount: count)
            }
        let own = item.interjections.filter { $0.itemId == item.id && $0.status == "active" }.count
        if own > 0 { choices.append(Choice(id: ownId, label: "Your Margins", marginCount: own)) }
        return choices
    }

    /// What the list and the model both read, so the two can never disagree about a layer.
    func input(for item: ItemDetailState) -> MarginLayerSynthesis.Input {
        MarginLayerSynthesis.input(
            itemId: item.id,
            layers: item.importedCommentaryLayers,
            interjections: item.importedCommentaryInterjections.values.flatMap { $0 },
            chosenLayerIds: Set(item.importedCommentaryLayers.map(\.id)).subtracting(unchecked),
            ownMargins: item.interjections,
            includeOwnMargins: isChosen(Self.ownId)
        )
    }
}

enum ReactionSummaryError: LocalizedError, Equatable {
    case nothingToSummarize
    case nothingCited

    var errorDescription: String? {
        switch self {
        case .nothingToSummarize: return "There are no placed Margins to summarize."
        case .nothingCited: return "The on-device model didn't tie its summary to the Margins, so nothing was kept. Try again."
        }
    }
}

/// Runs the on-device model on the chosen Margins and keeps only what cites them (#476).
struct ReactionSummaryGenerator: Sendable {
    static let modelId = "apple-foundation-models.on-device"

    let client: any LocalFoundationModelClient
    let store: ReactionSummaryStore

    func generate(input: MarginLayerSynthesis.Input, now: Date = Date()) async throws -> StoredReactionSummary {
        let availability = client.availability()
        guard availability.isAvailable else { throw LocalFoundationModelError.unavailable(availability.description) }
        guard !input.placed.isEmpty else { throw ReactionSummaryError.nothingToSummarize }
        let reply = try await client.summarizeReactions(prompt: MarginLayerSynthesis.prompt(for: input))
        let checked = try MarginLayerSynthesis.check(
            MarginLayerSynthesis.parseClaims(reply),
            against: input,
            modelId: Self.modelId,
            promptVersion: MarginLayerSynthesis.promptVersion
        )
        let summary = StoredReactionSummary(itemId: input.itemId, generatedAt: now, input: input, checked: checked)
        guard !summary.claims.isEmpty else { throw ReactionSummaryError.nothingCited }
        try store.save(summary)
        return summary
    }
}

@MainActor
final class ReactionsViewModel: ObservableObject {
    @Published var selection = ReactionsSelection()
    @Published private(set) var summary: StoredReactionSummary?
    @Published private(set) var isSummarizing = false
    @Published private(set) var errorMessage: String?

    private var generator: ReactionSummaryGenerator?
    private var task: Task<Void, Never>?

    func configure(model: Gate1AppModel) {
        guard generator == nil,
              let directory = try? model.applicationSupportDirectory().appendingPathComponent("ReactionSummaries", isDirectory: true)
        else { return }
        let store = ReactionSummaryStore(directory: directory)
        generator = ReactionSummaryGenerator(client: model.localFoundationModelClient, store: store)
        // A summary holds words drawn from other people's Margins, so it goes when its item or any
        // Margin it cites is deleted.
        for stored in store.all() where model.store != nil && (try? model.store?.loadItem(id: stored.itemId)) == nil {
            store.delete(itemId: stored.itemId)
        }
        let item = model.selectedItem
        let live = Set(item.interjections.filter { $0.status == "active" }.map(\.id))
            .union(item.importedCommentaryLayers.filter { $0.deletedAt == nil }
                .flatMap { item.importedCommentaryInterjections[$0.id, default: []].map(\.id) })
        if let stored = store.load(itemId: item.id), stored.isOrphaned(liveMarginIds: live) {
            store.delete(itemId: item.id)
        }
        summary = store.load(itemId: item.id)
    }

    func summarize(input: MarginLayerSynthesis.Input) {
        guard let generator, !isSummarizing else { return }
        isSummarizing = true
        errorMessage = nil
        task = Task { @MainActor [weak self] in
            do {
                let summary = try await generator.generate(input: input)
                self?.summary = summary
            } catch is CancellationError {
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isSummarizing = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// "Where people reacted" (#476): the places several people left Margins, in source order, and an
/// optional summary written on this iPhone that cites the Margins it comes from.
struct ExperienceReactionsScreen: View {
    private struct PlayTarget: Equatable {
        let layerId: String?
        let marginId: String
    }

    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reactions = ReactionsViewModel()
    @State private var pendingPlay: PlayTarget?

    private var input: MarginLayerSynthesis.Input { reactions.selection.input(for: model.selectedItem) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    layerPicker
                    summarySection
                    hotSpotsSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.bone)
            .accessibilityIdentifier("reactions.screen")
            .navigationTitle("Where people reacted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("reactions.done.button")
                }
            }
            .task { reactions.configure(model: model) }
            .onDisappear {
                reactions.cancel()
                // Leave this sheet first, then play, as the Margin detail does.
                if let target = pendingPlay {
                    pendingPlay = nil
                    play(target)
                }
            }
        }
        .tint(AppColors.evergreen)
    }

    // MARK: Layers

    private var layerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Whose Margins", detail: "Uncheck someone to leave their Margins out of the list and the summary")
            ExperienceSurface {
                VStack(spacing: 0) {
                    ForEach(Array(ReactionsSelection.choices(for: model.selectedItem).enumerated()), id: \.element.id) { index, choice in
                        if index > 0 { Divider() }
                        Toggle(isOn: Binding(
                            get: { reactions.selection.isChosen(choice.id) },
                            set: { reactions.selection.set(choice.id, chosen: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.label).font(.headline).foregroundStyle(AppColors.text)
                                Text("\(choice.marginCount) Margin\(choice.marginCount == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        .frame(minHeight: 52)
                        .accessibilityIdentifier("reactions.layer.\(choice.id)")
                    }
                }
            }
        }
    }

    // MARK: Summary

    @ViewBuilder
    private var summarySection: some View {
        if model.localFoundationModelAvailability.isAvailable || reactions.summary != nil {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("Summary", detail: "Written on this iPhone, nothing leaves it")
                if model.localFoundationModelAvailability.isAvailable {
                    HStack(spacing: 10) {
                        Button {
                            reactions.summarize(input: input)
                        } label: {
                            Label(reactions.summary == nil ? "Summarize" : "Summarize again", systemImage: "sparkles")
                                .frame(minHeight: 40)
                                .expandedHitArea(vertical: 2)
                        }
                        .buttonStyle(.bordered)
                        .disabled(reactions.isSummarizing || input.placed.isEmpty)
                        .accessibilityIdentifier("reactions.summarize.button")
                        if reactions.isSummarizing { ProgressView() }
                    }
                }
                if let message = reactions.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(AppColors.coral)
                        .accessibilityIdentifier("reactions.summary.error")
                }
                if let summary = reactions.summary { summaryBlock(summary) }
            }
        }
    }

    private func summaryBlock(_ summary: StoredReactionSummary) -> some View {
        ExperienceSurface(tint: AppColors.evergreen.opacity(0.12)) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Generated on this iPhone", systemImage: "iphone")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("reactions.summary.label")
                if summary.isStale(for: input) {
                    Text("Written from a different choice of Margins. Summarize again to match the list.")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                ForEach(Array(summary.claims.enumerated()), id: \.offset) { _, claim in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(claim.text)
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(AppColors.text)
                            .fixedSize(horizontal: false, vertical: true)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(claim.citationIds, id: \.self) { id in
                                if let citation = summary.citations.first(where: { $0.citationId == id }) {
                                    Button { request(PlayTarget(layerId: citation.layerId, marginId: citation.marginId)) } label: {
                                        Label(citationLabel(citation), systemImage: "play.fill")
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("reactions.citation.\(citation.marginId)")
                                }
                            }
                        }
                    }
                }
                Text("Apple's on-device model wrote this from the Margins above. Check it against the Margins it cites.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("reactions.summary")
    }

    private func citationLabel(_ citation: StoredReactionSummary.Citation) -> String {
        guard let time = citation.anchorTimeMs else { return citation.senderLabel }
        return "\(citation.senderLabel) \(MarginLayerSynthesis.clock(time))"
    }

    // MARK: Hot spots

    @ViewBuilder
    private var hotSpotsSection: some View {
        let current = input
        let spots = MarginLayerSynthesis.hotSpots(current)
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Hot spots", detail: "In the order they come up. Tap one to hear that moment.")
            if spots.isEmpty {
                ExperienceSurface {
                    Text("No placed Margins from the people you've chosen.")
                        .foregroundStyle(AppColors.secondaryText)
                }
            } else {
                ExperienceSurface {
                    VStack(spacing: 0) {
                        ForEach(Array(spots.enumerated()), id: \.offset) { index, spot in
                            if index > 0 { Divider() }
                            hotSpotRow(spot, index: index)
                        }
                    }
                }
            }
            if !current.notPlaced.isEmpty {
                Text("\(current.notPlaced.count) Margin\(current.notPlaced.count == 1 ? " isn't" : "s aren't") placed in your copy yet, so \(current.notPlaced.count == 1 ? "it isn't" : "they aren't") listed here.")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
        }
    }

    private func hotSpotRow(_ spot: MarginLayerSynthesis.HotSpot, index: Int) -> some View {
        Button {
            if let entry = playableEntry(in: spot) { request(PlayTarget(layerId: entry.layerId, marginId: entry.marginId)) }
        } label: {
            GutterRow(gutterWidth: 52, alignment: .top, spacing: 12) {
                Text(MarginLayerSynthesis.clock(spot.startMs))
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppColors.evergreen)
            } content: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(names(spot.senderLabels))
                            .font(.headline)
                            .foregroundStyle(AppColors.text)
                            .multilineTextAlignment(.leading)
                        ForEach(Array(spot.entries.prefix(3).enumerated()), id: \.offset) { _, entry in
                            Text("\(entry.senderLabel): \(entry.approvedTranscript)")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        if spot.entries.count > 3 {
                            Text("and \(spot.entries.count - 3) more")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "play.fill").foregroundStyle(AppColors.evergreen)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(MarginLayerSynthesis.clock(spot.startMs)), \(names(spot.senderLabels)). Play this moment.")
        .accessibilityIdentifier("reactions.hotSpot.\(index)")
    }

    /// The first Margin in the spot that has a voice to play; a sender's written Margin has none.
    private func playableEntry(in spot: MarginLayerSynthesis.HotSpot) -> MarginLayerSynthesis.Entry? {
        let voiced = spot.entries.first { entry in
            guard let layerId = entry.layerId else { return true }
            return model.selectedItem.importedCommentaryInterjections[layerId]?
                .first { $0.id == entry.marginId }?.audioPath != nil
        }
        return voiced ?? spot.entries.first
    }

    /// "Ana, Ben and you": the listener reads last.
    private func names(_ labels: [String]) -> String {
        let ordered = labels.filter { $0 != MarginLayerSynthesis.ownSenderLabel }
            + labels.filter { $0 == MarginLayerSynthesis.ownSenderLabel }
        return ListFormatter.localizedString(byJoining: ordered)
    }

    // MARK: Playing

    private func request(_ target: PlayTarget) {
        pendingPlay = target
        dismiss()
    }

    /// The existing "Play this moment" paths: a lead-in, the Margin, then the item.
    private func play(_ target: PlayTarget) {
        let item = model.selectedItem
        if let layerId = target.layerId {
            guard let layer = item.importedCommentaryLayers.first(where: { $0.id == layerId }),
                  let margin = item.importedCommentaryInterjections[layerId]?.first(where: { $0.id == target.marginId })
            else { return }
            model.playSharedMarginMoment(SharedMarginRow(interjection: margin, layer: layer, itemTitle: item.title))
        } else if let margin = item.interjections.first(where: { $0.id == target.marginId }) {
            _ = model.playMarginMoment(MarginRow(interjection: margin, itemTitle: item.title, sessionDate: nil))
        }
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.title3, design: .serif).weight(.bold))
            Text(detail).font(.caption).foregroundStyle(AppColors.secondaryText)
        }
    }
}
