import SwiftUI
import SessionKit

/// Card D's rows inside a friend card's About (#4675, `docs/design/reply-mailbox.md` screen D), for an answer that came
/// through one of this phone's reply boxes: the line that names on answers are typed, "Report this answer" and "Stop
/// answers through this link". Any other layer shows nothing here. Its own view, so it redraws when the records load
/// while the card list above it stays equatable.
struct ReplyBoxCardActions: View {
    @ObservedObject var replyBoxes: ReplyBoxCoordinator
    let layerID: String
    /// The card's sender label; "A friend" stands in when it names nobody (`ReplyArrivalWords.friendName`).
    let senderLabel: String

    @State private var confirmingStop = false
    @State private var stopping = false
    @State private var reporting: ReportTarget?

    struct ReportTarget: Identifiable, Equatable {
        let boxId: String
        let seq: Int
        var id: String { "\(boxId)#\(seq)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let answer = replyBoxes.answer(carrying: layerID) {
                answerControls(answer.record, seq: answer.seq)
            }
        }
        .onAppear { replyBoxes.loadRecordsIfNeeded() }
    }

    @ViewBuilder
    private func answerControls(_ record: ReplyBoxRecord, seq: Int) -> some View {
        // The name is a label the sender of the answer typed, not proof of who they are.
        Text(ReplyArrivalWords.namesAreTyped)
            .font(.footnote)
            .foregroundStyle(AppColors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

        // The friend made no link, and a link report would point at the sender's own link.
        Button {
            reporting = ReportTarget(boxId: record.boxId, seq: seq)
        } label: {
            Label(ReplyArrivalWords.reportAnswer, systemImage: "flag")
                .font(.subheadline.weight(.semibold))
        }
        .accessibilityHint("Reports this answer to Spoken Margins and hides it on this phone.")
        .accessibilityIdentifier("build23.imported.layer.\(layerID).reportAnswer")
        .trackedSheet(item: $reporting) { target in
            ReplyReportSheet(replyBoxes: replyBoxes, boxId: target.boxId, seq: target.seq, layerID: layerID)
        }

        if record.closed {
            Button {} label: {
                Label(ReplyArrivalWords.stoppedRow, systemImage: "nosign")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(true)
            .accessibilityIdentifier("build23.imported.layer.\(layerID).answersStopped")
        } else {
            Button(role: .destructive) {
                confirmingStop = true
            } label: {
                Label(ReplyArrivalWords.stopAnswers, systemImage: "nosign")
                    .font(.subheadline.weight(.semibold))
            }
            .disabled(stopping)
            .accessibilityHint("New answers through this link won't reach you. The answers already here stay.")
            .accessibilityIdentifier("build23.imported.layer.\(layerID).stopAnswers")
            .confirmationDialog(ReplyArrivalWords.stopConfirmTitle, isPresented: $confirmingStop, titleVisibility: .visible) {
                Button(ReplyArrivalWords.stopConfirmButton, role: .destructive) {
                    stopping = true
                    Task {
                        await replyBoxes.stopAnswers(boxId: record.boxId)
                        stopping = false
                    }
                }
                Button(ReplyArrivalWords.cancel, role: .cancel) {}
            } message: {
                Text(ReplyArrivalWords.stopConfirmMessage(senderLabel: senderLabel))
            }
        }
    }
}

/// "Report this answer" (screen E): a standard form in a sheet. The rules (what can be sent, the footers, what a result
/// does) are `ReplyReportForm`; the sends are the coordinator's.
struct ReplyReportSheet: View {
    let replyBoxes: ReplyBoxCoordinator
    let boxId: String
    let seq: Int
    let layerID: String

    @Environment(\.dismiss) private var dismiss
    @State private var form = ReplyReportForm()

    /// Once the report is filed and a reason is owed, the category and the toggle are what was sent: they no longer change.
    private var isFiled: Bool {
        if case .reasonOwed = form.phase { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(ReplyArrivalWords.reportCategorySection) {
                    ForEach(ReplyReportCategory.allCases) { category in
                        Button {
                            form.category = category
                        } label: {
                            HStack {
                                Text(category.title)
                                    .foregroundStyle(AppColors.text)
                                Spacer()
                                if form.category == category {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppColors.evergreen)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(form.category == category ? .isSelected : [])
                        .accessibilityIdentifier("replyBox.report.category.\(category.rawValue)")
                    }
                }
                .disabled(isFiled || form.isSending)

                Section {
                    TextField(ReplyArrivalWords.reportReasonPlaceholder, text: $form.reason, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("replyBox.report.reason")
                } header: {
                    Text(ReplyArrivalWords.reportReasonSection)
                } footer: {
                    if let footer = form.footer {
                        Text(footer)
                            .accessibilityIdentifier("replyBox.report.footer")
                    }
                }

                Section {
                    Toggle(ReplyArrivalWords.reportAlsoStop, isOn: $form.alsoStop)
                        .tint(AppColors.evergreen)
                        .accessibilityIdentifier("replyBox.report.alsoStop")
                }
                .disabled(isFiled || form.isSending)
            }
            .miniPlayerKeepOut()
            .navigationTitle(ReplyArrivalWords.reportTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ReplyArrivalWords.cancel, action: cancel)
                        .disabled(form.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if form.isSending {
                        ProgressView()
                    } else {
                        Button(ReplyArrivalWords.reportSend, action: send)
                            .disabled(!form.canSend)
                            .accessibilityIdentifier("replyBox.report.send")
                    }
                }
            }
        }
        // A filed report owes its reason or a Cancel, so a swipe can't drop it silently.
        .interactiveDismissDisabled(form.isSending || isFiled)
    }

    private func send() {
        let category = form.category
        guard let from = form.beginSending() else { return }
        Task {
            let completion: ReplyReportForm.Completion?
            if case .reasonOwed(let reference, let closeFailed) = from {
                let succeeded = await replyBoxes.sendReportReason(boxId: boxId, reference: reference, reason: form.reason)
                completion = form.finishReason(succeeded: succeeded, reference: reference, closeFailed: closeFailed)
            } else if let category {
                let result = await replyBoxes.report(
                    boxId: boxId, seq: seq, category: category, reason: form.trimmedReason, alsoStop: form.alsoStop)
                completion = form.finishReport(result)
            } else {
                completion = form.finishReport(.failed)
            }
            if let completion { close(with: completion) }
        }
    }

    private func cancel() {
        if let completion = form.cancelled() { close(with: completion) } else { dismiss() }
    }

    /// The sheet goes first; the answer is hidden and the banner shown after, so nothing on the card moves under it.
    private func close(with completion: ReplyReportForm.Completion) {
        dismiss()
        let replyBoxes = replyBoxes, layerID = layerID
        Task { await replyBoxes.finishReport(completion, layerId: layerID) }
    }
}
