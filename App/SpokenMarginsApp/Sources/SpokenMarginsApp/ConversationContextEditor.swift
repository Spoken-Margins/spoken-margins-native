import SwiftUI
import UIKit
import SessionKit

/// Optional detail editor; ordinary capture and quick sharing need no extra steps.
struct ConversationContextEditor: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    let note: Interjection
    @State private var targetID = "source"
    @State private var customContext = false
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var mediaStart = 0.0
    @State private var mediaEnd = 0.0
    @State private var initialized = false

    private var options: [MarginConversationSnapshot] { model.replyTargetOptions(for: note) }
    private var parent: MarginConversationSnapshot? { options.first { $0.id == targetID } }
    private var sourceEnd: Int { min(max(0, note.anchor.startChar), model.selectedItem.text.count) }
    private var sourceStart: Int { max(0, sourceEnd - 5_000) }
    private var passage: String { String(model.selectedItem.text.dropFirst(sourceStart).prefix(sourceEnd - sourceStart)) }
    private var mediaAnchor: Double { Double(max(0, note.anchor.mediaTimeMs ?? 0)) / 1_000 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Responding to") {
                    Picker("Response target", selection: $targetID) {
                        Text("Source passage").tag("source")
                        if targetID != "source", parent == nil {
                            Text("Referenced Margin · not received yet").tag(targetID)
                        }
                        ForEach(options) { node in
                            Text("\(model.conversationTitle(node)): \(node.transcript.prefix(70))").tag(node.id)
                        }
                    }
                    if let parent {
                        Text(parent.transcript).textSelection(.enabled)
                        Text("The complete referenced Margin plays before your reply. Its source context is played once for the conversation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Changing the response target keeps your original capture position.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if targetID == "source" {
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
        targetID == "source" ? (!customContext || model.selectedItem.isNativeAudio || selection.length > 0) : parent != nil
    }
    private func initialize() {
        guard !initialized else { return }; initialized = true
        targetID = note.conversation?.parent?.id ?? "source"
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
        if let parent {
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
        return model.saveConversationContext(note: note, parent: parent?.conversation.reference, context: context)
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
    let reply: (MarginConversationSnapshot, Bool) -> Void
    var listen: (MarginConversationSnapshot) -> Void = { _ in }
    var body: some View {
        if let reference {
            let children = descendants(of: reference)
            if !children.isEmpty {
                Section("Conversation replies") {
                    ForEach(children) { child in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.conversationTitle(child)).font(.headline)
                            if let parent = child.conversation.parent,
                               let target = model.conversationSnapshots.first(where: { $0.id == parent.id }) {
                                Text("In reply to \(model.conversationTitle(target)): \(target.transcript.prefix(70))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(child.transcript).textSelection(.enabled)
                            Button("Listen to conversation") { listen(child) }
                            HStack {
                                Button("Voice reply") { reply(child, false) }
                                Button("Written reply") { reply(child, true) }
                            }
                        }
                    }
                }
            }
        }
    }
    private func descendants(of reference: MarginReference) -> [MarginConversationSnapshot] {
        var result: [MarginConversationSnapshot] = []
        var pending = [reference.contributionID]
        var seen: Set<String> = [reference.contributionID]
        while !pending.isEmpty {
            let parentID = pending.removeFirst()
            let children = model.conversationSnapshots.filter { $0.conversation.parent?.contributionID == parentID }
                .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
            for child in children {
                result.append(child)
                if seen.insert(child.conversation.reference.contributionID).inserted { pending.append(child.conversation.reference.contributionID) }
            }
        }
        return result
    }
}
