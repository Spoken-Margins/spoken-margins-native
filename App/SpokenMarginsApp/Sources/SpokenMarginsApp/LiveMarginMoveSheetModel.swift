import Foundation
import SessionKit

/// The state of Move to an Item (#4233 Design 2.5): which Margins are chosen, the Library's started items to move them
/// onto, the search, the confirmation the listener is asked, and a failed move's line. It holds no store and no files:
/// what it reads and writes comes in as closures, so its states and words are tested without the app. The rules are
/// `LiveMarginMove`'s; the move itself is `LiveMarginMoving`'s.
@MainActor
final class LiveMarginMoveSheetModel: ObservableObject {
    enum Load: Equatable {
        case loading
        case failed
        case loaded([StoredSessionMargin.ItemChoice])
    }

    /// What the list shows when it has no rows.
    enum EmptyState: Equatable {
        case nothingStarted
        case noHits(String)
    }

    /// The session as it was when the sheet opened. The list of Margins to choose from is this one: new arrivals are not
    /// added (Design 2.5a).
    let session: LiveSession
    /// Opened from one Margin's sheet: "Moving this Margin", and no Choose….
    let isSingleMargin: Bool
    @Published private(set) var load: Load = .loading
    @Published var query = ""
    @Published private(set) var chosenIds: Set<String>
    /// The move the confirmation dialog asks about. It outlives the dialog: SwiftUI hides the dialog before a button's
    /// `Task` runs, so the dialog shows `isAsking` and only `confirm` or a new choice clears the plan.
    @Published private(set) var pendingPlan: LiveMarginMove.Plan?
    /// The confirmation dialog is showing.
    @Published var isAsking = false
    /// "Couldn't move the Margins. Nothing was changed.", or "Those Margins are no longer in this session."
    @Published private(set) var failureLine: String?
    @Published private(set) var isWorking = false

    private let loadChoices: () async throws -> [StoredSessionMargin.ItemChoice]
    private let makePlan: (_ margins: [LiveSessionMargin], _ itemId: String) async throws -> LiveMarginMove.Plan

    init(
        session: LiveSession, marginIds: Set<String>? = nil,
        loadChoices: @escaping () async throws -> [StoredSessionMargin.ItemChoice],
        makePlan: @escaping (_ margins: [LiveSessionMargin], _ itemId: String) async throws -> LiveMarginMove.Plan
    ) {
        self.session = session
        let movable = Set(LiveMarginMove.movableMargins(in: session).map(\.id))
        isSingleMargin = marginIds?.count == 1
        chosenIds = marginIds.map { $0.intersection(movable) } ?? movable
        self.loadChoices = loadChoices
        self.makePlan = makePlan
    }

    // MARK: The Margins

    /// Every Margin of the session in the Margins pane's order, movable or not (Choose Margins lists them all).
    var allMargins: [LiveSessionMargin] {
        let byId = Dictionary(session.margins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return LiveSessionMarginsList.rows(for: session).compactMap { byId[$0.id] }
    }

    var chosenMargins: [LiveSessionMargin] { allMargins.filter { chosenIds.contains($0.id) } }

    var movingLine: String {
        isSingleMargin ? LiveMarginMove.Wording.movingThis : LiveMarginMove.Wording.movingLine(count: chosenIds.count)
    }

    func unmovableReason(_ margin: LiveSessionMargin) -> String? {
        LiveMarginMove.movability(margin: margin, in: session)?.reason
    }

    func toggle(_ margin: LiveSessionMargin) {
        guard LiveMarginMove.movability(margin: margin, in: session) == nil else { return }
        if chosenIds.contains(margin.id) { chosenIds.remove(margin.id) } else { chosenIds.insert(margin.id) }
    }

    /// Choose Margins' Done is dimmed while nothing is ticked.
    var canFinishChoosing: Bool { !chosenIds.isEmpty }

    // MARK: The items

    func loadIfNeeded() async {
        if case .loaded = load { return }
        await reload()
    }

    func reload() async {
        load = .loading
        do {
            load = .loaded(try await loadChoices())
        } catch {
            load = .failed
        }
    }

    /// The two sections, filtered by the search: titles that contain it, ignoring case and accents, as the Shortcuts picker
    /// matches (`StoredSessionMargin.itemChoices`).
    var sections: (playingThen: [StoredSessionMargin.ItemChoice], recent: [StoredSessionMargin.ItemChoice]) {
        guard case let .loaded(choices) = load else { return ([], []) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = trimmed.isEmpty ? choices : choices.filter {
            $0.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        return LiveMarginMove.suggestions(margins: chosenMargins, choices: shown)
    }

    var emptyState: EmptyState? {
        guard case let .loaded(choices) = load else { return nil }
        if choices.isEmpty { return .nothingStarted }
        let (playing, recent) = sections
        return playing.isEmpty && recent.isEmpty ? .noHits(query) : nil
    }

    // MARK: Moving

    /// A tap on an item: works out the move, then asks (the dialog reads `pendingPlan`).
    func choose(itemId: String) async {
        guard !isWorking, !chosenIds.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        failureLine = nil
        pendingPlan = nil
        do {
            pendingPlan = try await makePlan(chosenMargins, itemId)
            isAsking = true
        } catch LiveMarginMove.Failure.nothingToMove {
            failureLine = LiveMarginMove.Wording.marginsGone
        } catch {
            failureLine = LiveMarginMove.Wording.moveFailed(count: chosenIds.count)
        }
    }

    /// Confirmed: runs `perform`, once, however often it is tapped. True when the Margins moved and the sheet closes.
    func confirm(_ perform: (LiveMarginMove.Plan) async -> Bool) async -> Bool {
        guard let plan = pendingPlan, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        pendingPlan = nil
        isAsking = false
        let moved = await perform(plan)
        if !moved { failureLine = LiveMarginMove.Wording.moveFailed(count: plan.count) }
        return moved
    }

    var dialogTitle: String {
        pendingPlan.map { LiveMarginMove.Wording.dialogTitle(count: $0.count, title: $0.itemTitle) } ?? ""
    }

    var dialogMessage: String {
        pendingPlan.map { LiveMarginMove.Wording.dialogMessage(placed: $0.placedCount, unplaced: $0.unplacedCount, title: $0.itemTitle) } ?? ""
    }

    var confirmTitle: String {
        pendingPlan.map { LiveMarginMove.Wording.confirmButton(count: $0.count) } ?? ""
    }
}
