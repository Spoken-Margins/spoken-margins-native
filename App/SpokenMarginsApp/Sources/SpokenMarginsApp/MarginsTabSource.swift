import SessionKit
import SwiftUI

/// The open item's Margins for the Margins tab, the arrival preview and the Next Margin pill: the control centre's rows
/// (`MarginsControlCenter.rows`) plus the app rows each one opens and plays. Built from what the model already
/// publishes; it keeps no state and moves nothing. Every jump goes through the actions the old Margins list used:
/// `MarginMomentTap.start` for your own, and `goToSharedMargin` for a friend's, which plays the lead-in and the Margin,
/// a passage of an article or PDF and then the Margin (#4447), or goes there silently when it is never read aloud (#4934).
@MainActor
struct MarginsTabSource {
    let rows: [MarginsControlCenter.Row]
    let own: [String: MarginRow]
    let shared: [String: SharedMarginRow]

    init(model: Gate1AppModel) {
        let itemId = model.selectedItem.id
        let ownRows = model.marginRows.filter { $0.interjection.itemId == itemId && $0.interjection.status == "active" }
        let sharedRows = model.sharedMarginRows.filter { $0.layer.itemId == itemId && $0.layer.deletedAt == nil }
        var layers: [ImportedCommentaryLayer] = []
        for row in sharedRows where !layers.contains(where: { $0.id == row.layer.id }) { layers.append(row.layer) }
        rows = MarginsControlCenter.rows(
            itemId: itemId, localMargins: ownRows.map(\.interjection), layers: layers,
            importedMargins: sharedRows.map(\.interjection))
        own = Dictionary(ownRows.map { ($0.interjection.id, $0) }, uniquingKeysWith: { first, _ in first })
        shared = Dictionary(sharedRows.map { ($0.interjection.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func ownRow(_ row: MarginsControlCenter.Row) -> MarginRow? {
        if case .local(let id) = row.reference { return own[id] }
        return nil
    }

    func sharedRow(_ row: MarginsControlCenter.Row) -> SharedMarginRow? {
        if case .imported(let id) = row.reference { return shared[id] }
        return nil
    }

    /// Whether the row's start control can do anything: a placed Margin whose voice (or reading) can be offered.
    func canJump(_ row: MarginsControlCenter.Row) -> Bool {
        if let shared = sharedRow(row) { return shared.canPlayFromMarginsList || shared.goesToFromList }
        return ownRow(row) != nil && row.timeMs != nil
    }

    /// Whether the start control goes to the place with nothing read aloud: a friend's Margin never read aloud, or your
    /// own written one (`SilentMarginWords`, #4934).
    func goesTo(_ row: MarginsControlCenter.Row) -> Bool {
        if let shared = sharedRow(row) { return shared.goesToFromList }
        if let own = ownRow(row) { return SilentMarginWords.ownWrittenGoesTo(own.interjection) }
        return false
    }

    /// The identifier the old list gave this row, kept so journeys and UI tests still find it.
    func identifier(_ row: MarginsControlCenter.Row) -> String {
        if let own = ownRow(row) { return "margins.row.\(own.id)" }
        if let shared = sharedRow(row) { return "margins.shared.row.\(shared.id)" }
        return "margins.row.\(row.id)"
    }

    /// Whether this row's Margin is the one playing now (its voice, or its moment's lead-in).
    func isPlaying(_ row: MarginsControlCenter.Row, model: Gate1AppModel) -> Bool {
        if let shared = sharedRow(row) {
            if model.playingImportedCommentary?.interjection.id == shared.interjection.id { return true }
            return model.marginMoment?.target.marginId == shared.id
        }
        if let own = ownRow(row) { return model.marginMoment?.target.marginId == own.id } // `marginIdentity`: session::id
        return false
    }

    /// "Jump to this Margin" / "Start with this Margin": the lead-in, then the Margin, as the old row's Play did.
    func jump(to row: MarginsControlCenter.Row, model: Gate1AppModel) {
        if let shared = sharedRow(row) {
            model.goToSharedMargin(shared)
        } else if let own = ownRow(row) {
            MarginMomentTap.start(own, model: model)
        }
    }

    /// Next Margin from the playhead, from `NextMarginSkip`: the next thread (the next one with something unheard
    /// under Autoplay Unheard), the countdown to its first Margin, and the Margin that plays first there.
    func nextSkip(playheadMs: Int, autoplay: MarginsControlCenter.Autoplay) -> NextMarginSkip? {
        NextMarginSkip.next(playheadMs: playheadMs, rows: rows, autoplay: autoplay)
    }

    /// The Next Margin press. Before the lead-in it jumps to the lead-in, as a row does. Inside a friend's lead-in it
    /// plays the Margin straight away, never back to the lead-in's start. Your own Margin has no "play it now" path,
    /// so inside its lead-in the press starts its moment, which begins at the lead-in.
    func pressNext(_ skip: NextMarginSkip, model: Gate1AppModel) {
        let target = skip.firstToPlay.flatMap { reference in rows.first { $0.reference == reference } }
        guard let row = target ?? rows.first(where: { $0.depth == 0 && $0.timeMs == skip.marginTimeMs }) else { return }
        if skip.action == .playMargin, let shared = sharedRow(row),
           let prompt = model.importedCommentaryPrompts(includeAnnounced: true)
               .first(where: { $0.interjection.id == shared.interjection.id }) {
            model.playSharedMarginNow(prompt)
            return
        }
        jump(to: row, model: model)
    }
}
