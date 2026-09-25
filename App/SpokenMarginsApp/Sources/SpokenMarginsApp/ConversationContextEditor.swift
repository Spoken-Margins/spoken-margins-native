import SwiftUI
import UIKit
import SessionKit

/// Optional detail editor; ordinary capture and quick sharing need no extra steps.
struct ConversationContextEditor: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    let note: Interjection
    @State private var targetIDs: [String] = []
    @State private var customContext = false
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var mediaStart = 0.0
    @State private var mediaEnd = 0.0
    @State private var initialized = false

    private var options: [MarginConversationSnapshot] { model.replyTargetOptions(for: note) }
    private var parents: [MarginConversationSnapshot] { targetIDs.compactMap { id in options.first { $0.id == id } } }
    private var sourceEnd: Int { min(max(0, note.anchor.startChar), model.selectedItem.text.count) }
    private var sourceStart: Int { max(0, sourceEnd - 5_000) }
    private var passage: String { String(model.selectedItem.text.dropFirst(sourceStart).prefix(sourceEnd - sourceStart)) }
    private var mediaAnchor: Double { Double(max(0, note.anchor.mediaTimeMs ?? 0)) / 1_000 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Responding to") {
                    Button("Source passage") { targetIDs = [] }
                    ForEach(options) { node in
                        Button {
                            if let index = targetIDs.firstIndex(of: node.id) { targetIDs.remove(at: index) }
                            else if targetIDs.count < 4 { targetIDs.append(node.id) }
                        } label: {
                            Label("\(model.conversationTitle(node)): \(node.transcript.prefix(70))",
                                  systemImage: targetIDs.contains(node.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    ForEach(parents) { parent in
                        Text(parent.transcript).textSelection(.enabled)
                    }
                    if !targetIDs.isEmpty {
                        Text("The selected Margins play in this order before your reply. Shared ancestors play once.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if targetIDs.count != parents.count { Text("A referenced Margin has not arrived yet.").foregroundStyle(.secondary) }
                    Text("Changing the response target keeps your original capture position.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if targetIDs.isEmpty {
                    Section("Listening lead-up") {
                        Toggle("Choose a specific passage", isOn: $customContext)
                        if customContext {
                            if model.selectedItem.isNativeAudio {
                                Text("From \(Int(mediaStart))s to \(Int(mediaEnd))s")
                                Slider(value: $mediaStart, in: max(0, mediaAnchor - 300)...max(0.001, mediaAnchor), step: 1)
                                    .accessibilityLabel("Lead-up start in seconds")
                                    .onChange(of: mediaStart) { _, value in mediaEnd = max(value, mediaEnd) }
                                Slider(value: $mediaEnd, in: max(0, mediaAnchor - 300)...max(0.001, mediaAnchor), step: 1)
                                    .accessibilityLabel("Lead-up end in seconds")
                                    .onChange(of: mediaEnd) { _, value in mediaStart = min(value, mediaStart) }
                            } else if passage.isEmpty {
                                Text("There is no source text before this position.")
                            } else {
                                Text("Select the words you want your friend to hear. Drag the selection handles to shorten the lead-up.")
                                    .font(.caption)
                                ConversationPassageSelection(text: passage, selection: $selection)
                                    .frame(minHeight: 240, maxHeight: 360)
                                    .accessibilityIdentifier("conversation.context.passage")
                            }
                            Text("This changes listening guidance only. Source matching keeps its original anchor evidence.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Use the listener’s normal Skim context. A second tap skips the lead-up.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("Save and play with context") {
                        if save() { model.playConversationMargin(model.conversationUpdatedNote(note), withContext: true); dismiss() }
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle("Response & Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if save() { dismiss() } }.disabled(!canSave)
                }
            }
            .onAppear(perform: initialize)
        }
    }

    private var canSave: Bool {
        targetIDs.isEmpty ? (!customContext || model.selectedItem.isNativeAudio || selection.length > 0) : targetIDs.count == parents.count
    }
    private func initialize() {
        guard !initialized else { return }; initialized = true
        targetIDs = note.conversation?.parents.map(\.id) ?? []
        mediaStart = max(0, mediaAnchor - 120); mediaEnd = mediaAnchor
        selection = NSRange(location: 0, length: (passage as NSString).length)
        if let context = note.conversation?.context, context.kind != .parent {
            customContext = true
            if context.kind == .sourceMedia {
                mediaStart = Double(context.start) / 1_000; mediaEnd = Double(context.end) / 1_000
            } else if let quote = context.quote, let range = passage.range(of: quote) {
                selection = NSRange(range, in: passage)
            }
        }
    }
    private func save() -> Bool {
        var context: MarginListeningContext?
        if let parent = parents.first {
            context = .init(kind: .parent, start: 0, end: parent.audioDurationMs ?? parent.transcript.count)
        } else if customContext {
            if model.selectedItem.isNativeAudio {
                context = .init(kind: .sourceMedia, start: Int(mediaStart * 1_000), end: Int(mediaEnd * 1_000))
            } else if let range = Range(selection, in: passage) {
                let start = sourceStart + passage.distance(from: passage.startIndex, to: range.lowerBound)
                context = .init(kind: .sourceText, start: start,
                    end: start + passage[range].count, quote: String(passage[range]))
            }
        }
        return model.saveConversationContext(note: note, parents: parents.map { $0.conversation.reference }, context: context)
    }
}

private struct ConversationPassageSelection: UIViewRepresentable {
    let text: String
    @Binding var selection: NSRange
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.text = text; view.selectedRange = selection
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if view.selectedRange != selection { view.selectedRange = selection }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ConversationPassageSelection
        init(_ parent: ConversationPassageSelection) { self.parent = parent }
        func textViewDidChangeSelection(_ textView: UITextView) {
            if parent.selection != textView.selectedRange { parent.selection = textView.selectedRange }
        }
    }
}

struct ConversationRepliesSection: View {
    @EnvironmentObject private var model: Gate1AppModel
    let reference: MarginReference?
    let reply: ([MarginConversationSnapshot], Bool) -> Void
    var listen: (MarginConversationSnapshot) -> Void = { _ in }
    @State private var selectingTargets = false
    @State private var selectedTargetIDs: [String] = []
    @State private var pendingMultiReply: ([MarginConversationSnapshot], Bool)?
    var body: some View {
        if let reference {
            let children = descendants(of: reference)
            if !children.isEmpty {
                Section("Conversation replies") {
                    ForEach(children) { child in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.conversationTitle(child)).font(.headline)
                            ForEach(child.conversation.parents) { parent in
                                if let target = model.conversationSnapshots.first(where: { $0.id == parent.id }) {
                                    Text("In reply to \(model.conversationTitle(target)): \(target.transcript.prefix(70))")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Referenced Margin not received yet").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(child.transcript).textSelection(.enabled)
                            Button("Listen to conversation") { listen(child) }
                            HStack {
                                Button("Voice reply") { reply([child], false) }
                                Button("Written reply") { reply([child], true) }
                            }
                        }
                    }
                    Button("Reply to several") {
                        selectedTargetIDs = []
                        selectingTargets = true
                    }
                    .sheet(isPresented: $selectingTargets, onDismiss: {
                        if let pendingMultiReply {
                            self.pendingMultiReply = nil
                            reply(pendingMultiReply.0, pendingMultiReply.1)
                        }
                    }) {
                        NavigationStack {
                            List {
                                Section("Replying to") {
                                    ForEach(children) { child in
                                        Button {
                                            if let index = selectedTargetIDs.firstIndex(of: child.id) { selectedTargetIDs.remove(at: index) }
                                            else if selectedTargetIDs.count < 4 { selectedTargetIDs.append(child.id) }
                                        } label: {
                                            Label("\(model.conversationTitle(child)): \(child.transcript.prefix(70))",
                                                  systemImage: selectedTargetIDs.contains(child.id) ? "checkmark.circle.fill" : "circle")
                                        }
                                    }
                                }
                                Section {
                                    Button("Voice reply") { finishMultiReply(children, written: false) }
                                    Button("Written reply") { finishMultiReply(children, written: true) }
                                }.disabled(selectedTargetIDs.count < 2)
                            }
                            .navigationTitle("Reply to several")
                            .toolbar { Button("Cancel") { selectingTargets = false } }
                        }
                    }
                }
            }
        }
    }
    private func finishMultiReply(_ children: [MarginConversationSnapshot], written: Bool) {
        let selected = selectedTargetIDs.compactMap { id in children.first { $0.id == id } }
        guard selected.count >= 2 else { return }
        pendingMultiReply = (selected, written)
        selectingTargets = false
    }
    private func descendants(of reference: MarginReference) -> [MarginConversationSnapshot] {
        var result: [MarginConversationSnapshot] = []
        var pending = [reference.contributionID]
        var seen: Set<String> = [reference.contributionID]
        var seenRevisions: Set<String> = []
        while !pending.isEmpty {
            let parentID = pending.removeFirst()
            let children = model.conversationSnapshots.filter { $0.conversation.parents.contains(where: { $0.contributionID == parentID }) }
                .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
            for child in children {
                if seenRevisions.insert(child.id).inserted { result.append(child) }
                if seen.insert(child.conversation.reference.contributionID).inserted { pending.append(child.conversation.reference.contributionID) }
            }
        }
        return result
    }
}
