import SessionKit
import SwiftUI

/// The Paper note on a PDF's item screen (#4340): the citation, then Purpose, Key findings and three Evidence, each filled
/// by one of the listener's own Margins carrying that role. What it shows comes from `PaperNoteSlots` (SessionKit); this
/// view draws it and hands taps to the model. "Write it" comes in the next PR; until then an empty slot offers "Choose a
/// Margin" when the paper has Margins of the listener's own, and its question alone when it has none.
struct PaperNoteSection: View {
    @EnvironmentObject private var model: Gate1AppModel
    /// The paper's structure, for the answers' pages; read off the main thread when the item opens.
    @State private var document: StructuredDocument?
    @State private var choosing: PaperNoteChooseMarginSheet.Request?
    @State private var detailRow: MarginRow?

    var body: some View {
        let slots = model.paperNoteSlots(document: document)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(PaperNoteSlots.heading).font(.system(.title3, design: .serif).weight(.bold)).accessibilityAddTraits(.isHeader)
                Text(PaperNoteSlots.subheading).font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            ExperienceSurface {
                VStack(alignment: .leading, spacing: 0) {
                    Text(slots.citation)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                        .accessibilityLabel("Citation: \(slots.citation)")
                        .accessibilityIdentifier("paperNote.citation")
                    ForEach(slots.rows) { row in
                        Divider()
                        rowView(row, slots: slots)
                    }
                    if slots.offersMoreEvidence {
                        Divider()
                        Button {
                            choosing = .init(role: .evidence, replacing: nil)
                        } label: {
                            Label(PaperNoteSlots.addMoreEvidence, systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.evergreen)
                        .accessibilityIdentifier("paperNote.addMoreEvidence.button")
                    }
                }
            }
            if slots.hasNoMargins {
                Text(PaperNoteSlots.noMarginsFootnote)
                    .font(.footnote)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("paperNote.footnote")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paperNote.section")
        .task(id: model.selectedItem.id) {
            let id = model.selectedItem.id
            document = nil
            let loaded = await model.paperNoteDocument(itemId: id)
            guard id == model.selectedItem.id else { return }
            document = loaded
        }
        .trackedSheet(item: $choosing) { request in
            PaperNoteChooseMarginSheet(request: request, choices: slots.choices) { chosen in
                if let old = request.replacing {
                    model.changePaperAnswer(request.role, to: chosen.margin, replacing: old)
                } else {
                    model.setPaperRole(request.role, for: chosen.margin)
                }
            }
        }
        .trackedSheet(item: $detailRow) { row in
            ExperienceMarginDetailView(row: row).environmentObject(model)
        }
    }

    @ViewBuilder
    private func rowView(_ row: PaperNoteSlots.Row, slots: PaperNoteSlots) -> some View {
        switch row {
        case .empty(let role, let index):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(PaperNoteSlots.slotName(role)).font(.headline).foregroundStyle(AppColors.text)
                    Text(PaperNoteSlots.question(role))
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !slots.hasNoMargins {
                    Menu {
                        Button("Choose a Margin", systemImage: "quote.bubble") {
                            choosing = .init(role: role, replacing: nil)
                        }
                        .accessibilityIdentifier("paperNote.choose.\(role.rawValue).\(index)")
                    } label: {
                        Text("Add").frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.evergreen)
                    .accessibilityLabel("Add \(PaperNoteSlots.slotName(role))")
                    .accessibilityIdentifier("paperNote.add.\(role.rawValue).\(index)")
                }
            }
            .padding(.vertical, 10)
        case .filled(let answer):
            let marginRow = MarginRow(interjection: answer.margin, itemTitle: model.selectedItem.title, sessionDate: nil)
            HStack(alignment: .top, spacing: 8) {
                Button { play(marginRow) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PaperNoteSlots.slotName(row.role)).font(.headline).foregroundStyle(AppColors.text)
                        Text(marginRow.preview)
                            .font(.body)
                            .foregroundStyle(AppColors.text)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Text(answer.placeLine)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(MarginRowTap.action(for: answer.margin) == .playMoment ? "Plays this moment" : "Opens this Margin")
                .accessibilityIdentifier("paperNote.answer.\(answer.margin.id)")
                .contextMenu { answerActions(answer, role: row.role, marginRow: marginRow) }
                Menu {
                    answerActions(answer, role: row.role, marginRow: marginRow)
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .foregroundStyle(AppColors.evergreen)
                .accessibilityLabel("\(PaperNoteSlots.slotName(row.role)) options")
                .accessibilityIdentifier("paperNote.answerMenu.\(answer.margin.id)")
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func answerActions(_ answer: PaperNoteSlots.Answer, role: PaperNoteRole, marginRow: MarginRow) -> some View {
        Button("Change answer", systemImage: "arrow.triangle.2.circlepath") {
            choosing = .init(role: role, replacing: answer.margin)
        }
        .accessibilityIdentifier("paperNote.change.\(answer.margin.id)")
        Button("Open Margin", systemImage: "quote.bubble") { detailRow = marginRow }
            .accessibilityIdentifier("paperNote.open.\(answer.margin.id)")
        Button("Remove from paper note", systemImage: "minus.circle") {
            model.setPaperRole(nil, for: answer.margin)
        }
        .accessibilityIdentifier("paperNote.remove.\(answer.margin.id)")
    }

    /// The same as a tap on a Margin row on the Margins tab: the moment plays, or a Margin with no place opens.
    private func play(_ row: MarginRow) {
        switch MarginRowTap.action(for: row.interjection) {
        case .playMoment: MarginMomentTap.start(row, model: model)
        case .openDetails: detailRow = row
        }
    }
}

/// "Choose a Margin for Purpose": the listener's own Margins on the paper, page and first lines, to fill a slot (#4340).
/// A Margin that already has a role shows it and can still be chosen; choosing moves its role to this slot.
struct PaperNoteChooseMarginSheet: View {
    struct Request: Identifiable {
        let role: PaperNoteRole
        /// The answer "Change answer" replaces; nil for an empty slot.
        let replacing: Interjection?
        var id: String { "\(role.rawValue)|\(replacing.map { "\($0.sessionId)::\($0.id)" } ?? "new")" }
    }

    @Environment(\.dismiss) private var dismiss
    let request: Request
    let choices: [PaperNoteSlots.Answer]
    let choose: (PaperNoteSlots.Answer) -> Void

    var body: some View {
        NavigationStack {
            List(choices) { choice in
                let row = MarginRow(interjection: choice.margin, itemTitle: "", sessionDate: nil)
                Button {
                    choose(choice)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(choice.placeLine)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppColors.secondaryText)
                        Text(row.preview)
                            .font(.body)
                            .foregroundStyle(AppColors.text)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Text(detail(for: choice, row: row))
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("paperNote.choice.\(choice.margin.id)")
            }
            .navigationTitle(PaperNoteSlots.chooseTitle(request.role))
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("paperNote.choose.cancel")
                }
            }
        }
        .tint(AppColors.evergreen)
    }

    /// "Spoken" or "Written", then the role it already fills: "Written · Evidence".
    private func detail(for choice: PaperNoteSlots.Answer, row: MarginRow) -> String {
        [row.isWritten ? "Written" : "Spoken", choice.margin.paperRole.map(PaperNoteSlots.roleName)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
