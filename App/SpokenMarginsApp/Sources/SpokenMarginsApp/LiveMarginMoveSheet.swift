import SessionKit
import SwiftUI

/// Move to an Item (#4233 Design 2.5 to 2.6): the chosen live-session Margins, the Library's started items to move them
/// onto (what was playing when they were made first, then recently played), a search, and the confirmation that says
/// which will have a place on the item and which won't. Choose… narrows the Margins (2.5a). The state is
/// `LiveMarginMoveSheetModel`'s; the move is `LiveMarginMoving`'s.
struct LiveMarginMoveSheet: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sheet: LiveMarginMoveSheetModel
    /// True at the sheet's root (the finish card, Move…, the VoiceOver action): a Cancel button. False when pushed from a
    /// Margin's sheet, which has the system back button.
    let isRoot: Bool
    /// Called once the Margins have moved, before the sheet closes.
    let moved: (LiveMarginMoving.Moved) -> Void

    var body: some View {
        if isRoot {
            NavigationStack { content }
        } else {
            content
        }
    }

    private var content: some View {
        List {
            if let line = sheet.failureLine {
                Section {
                    Label(line, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(AppColors.text)
                        .accessibilityIdentifier("liveMove.failure.label")
                }
            }
            Section {
                HStack {
                    Text(sheet.movingLine).accessibilityIdentifier("liveMove.moving.label")
                    Spacer()
                    if !sheet.isSingleMargin {
                        NavigationLink("Choose…") { LiveMarginChooseView(sheet: sheet) }
                            .fixedSize()
                            .accessibilityIdentifier("liveMove.choose.button")
                    }
                }
            }
            items
        }
        .searchable(text: $sheet.query, prompt: "Search your Library")
        .navigationTitle("Move to an Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("liveMove.cancel.button")
                }
            }
        }
        .task { await sheet.loadIfNeeded() }
        .confirmationDialog(
            sheet.dialogTitle,
            isPresented: Binding(get: { sheet.pendingPlan != nil }, set: { if !$0 { sheet.pendingPlan = nil } }),
            titleVisibility: .visible
        ) {
            Button(sheet.confirmTitle) {
                Task {
                    var result: LiveMarginMoving.Moved?
                    let done = await sheet.confirm { plan in
                        result = await LiveMarginMoving.move(plan, model: model)
                        return result != nil
                    }
                    if done, let result {
                        moved(result)
                        dismiss()
                    }
                }
            }
            .accessibilityIdentifier("liveMove.confirm.button")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(sheet.dialogMessage)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveMove.screen")
    }

    @ViewBuilder
    private var items: some View {
        switch sheet.load {
        case .loading:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(LiveMarginMove.Wording.loading).foregroundStyle(AppColors.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        case .failed:
            Section {
                Text(LiveMarginMove.Wording.loadFailed)
                Button("Try Again") { Task { await sheet.reload() } }
                    .accessibilityIdentifier("liveMove.retry.button")
            }
        case .loaded:
            if let empty = sheet.emptyState {
                Section {
                    switch empty {
                    case .nothingStarted:
                        VStack(alignment: .leading, spacing: 6) {
                            Text(LiveMarginMove.Wording.emptyTitle).font(.headline).accessibilityAddTraits(.isHeader)
                            Text(LiveMarginMove.Wording.emptyMessage).foregroundStyle(AppColors.secondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    case let .noHits(query):
                        Text(LiveMarginMove.Wording.noHits(query)).foregroundStyle(AppColors.secondaryText)
                    }
                }
            } else {
                let (playing, recent) = sheet.sections
                if !playing.isEmpty {
                    Section(LiveMarginMove.Wording.playingThenSection) {
                        ForEach(playing, id: \.id) { row($0, line: LiveMarginMove.Wording.playingThenLine) }
                    }
                }
                if !recent.isEmpty {
                    Section(LiveMarginMove.Wording.recentSection) {
                        ForEach(recent, id: \.id) { row($0, line: nil) }
                    }
                }
            }
        }
    }

    private func row(_ choice: StoredSessionMargin.ItemChoice, line: String?) -> some View {
        Button {
            Task { await sheet.choose(itemId: choice.id) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title).foregroundStyle(AppColors.text).lineLimit(2)
                if let line { Text(line).font(.caption).foregroundStyle(AppColors.secondaryText) }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(sheet.isWorking)
        .accessibilityIdentifier("liveMove.item.\(choice.id)")
    }
}

/// Choose Margins (Design 2.5a): the session's Margins as they were when the sheet opened, each with a tick that shows as a
/// circle and as VoiceOver's Selected trait, never by colour alone. Margins that can't move are dimmed with their reason.
struct LiveMarginChooseView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sheet: LiveMarginMoveSheetModel

    var body: some View {
        List {
            Section {
                ForEach(sheet.allMargins) { margin in
                    if let reason = sheet.unmovableReason(margin) {
                        rowText(margin, second: reason)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("liveMove.choose.row.\(margin.id)")
                    } else {
                        let ticked = sheet.chosenIds.contains(margin.id)
                        Button { sheet.toggle(margin) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(AppColors.evergreen)
                                    .accessibilityHidden(true)
                                rowText(margin, second: LiveSessionMarginsList.positionLabel(for: margin, in: sheet.session))
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(ticked ? .isSelected : [])
                        .accessibilityIdentifier("liveMove.choose.row.\(margin.id)")
                    }
                }
            } header: {
                Text(LiveMarginMove.Wording.chooseIntro)
            }
        }
        .navigationTitle("Choose Margins")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .disabled(!sheet.canFinishChoosing)
                    .accessibilityIdentifier("liveMove.choose.done.button")
            }
        }
        // Back would leave nothing chosen: Done is the way out, and it waits for a tick.
        .navigationBarBackButtonHidden(true)
    }

    private func rowText(_ margin: LiveSessionMargin, second: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(words(margin)).lineLimit(2).foregroundStyle(AppColors.text)
            Text(second).font(.caption).foregroundStyle(AppColors.secondaryText)
        }
    }

    private func words(_ margin: LiveSessionMargin) -> String {
        if margin.isSpoken { return margin.spokenTranscript ?? LiveMarginMove.Wording.notTranscribed }
        return margin.savedText
    }
}
