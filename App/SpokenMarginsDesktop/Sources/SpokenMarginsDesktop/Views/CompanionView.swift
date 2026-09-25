import AppKit
import SwiftUI

struct CompanionView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openSettings) private var openSettings
    @Bindable var model: DesktopModel
    @State private var showsMargins = false
    @State private var showsChapters = false
    @State private var showsManualText = false
    @State private var scrubbingOffset: Double?
    @State private var showsWrittenMargin = false
    @State private var writtenMargin = ""
    @State private var showsRecent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "quote.bubble.fill")
                    .foregroundStyle(DesktopPalette.evergreen(scheme))
                Text("Spoken Margins")
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(DesktopPalette.text(scheme))
                Spacer()
                Button { model.newText(); showsManualText = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New Text")
                .accessibilityLabel("New Text")
                .disabled(model.isBusy || model.isRecording)
                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                    Task { @MainActor in
                        await Task.yield()
                        NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) })?
                            .makeKeyAndOrderFront(nil)
                    }
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }

            Button("Paste & Listen", systemImage: "doc.on.clipboard") {
                model.pasteAndListen()
                showsManualText = false
                showsMargins = false
            }
            .buttonStyle(DesktopPrimaryButtonStyle())
            .disabled(model.isBusy || model.isRecording)
            .accessibilityHint("Starts speaking copied text in one action")

            statusLine

            if !model.recentSessions.isEmpty {
                Button("Recent Sessions (\(model.recentSessions.count))", systemImage: showsRecent ? "chevron.up" : "chevron.down") {
                    showsRecent.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption)
                if showsRecent {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.recentSessions, id: \.session.id) { recent in
                                Button(recent.title) { model.openRecentSession(id: recent.session.id) }
                                    .buttonStyle(.plain)
                                    .lineLimit(1)
                                    .disabled(model.isBusy || model.isRecording)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 115)
                }
            }

            if model.hasSession { sessionControls } else { manualText }
        }
        .padding(.horizontal, 13)
        .padding(.top, 8)
        .padding(.bottom, 13)
        .frame(width: 352, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: false)
        .background(DesktopPalette.bone(scheme))
    }

    private var statusText: String {
        if let status = model.voiceRenderStatus { return status }
        if let warning = model.voicePerformanceMessage { return warning }
        if model.isVoiceWaiting { return "Preparing \(model.selectedBackend.title) audio…" }
        return model.message ?? "Ready"
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if model.voiceRenderStatus != nil || (model.isVoiceWaiting && model.voicePerformanceMessage == nil) {
                ProgressView().controlSize(.small).frame(width: 13, height: 13)
            } else {
                Image(systemName: model.voicePerformanceMessage == nil ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(model.voicePerformanceMessage == nil ? DesktopPalette.secondary(scheme) : .orange)
                    .frame(width: 13, height: 13)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(model.voicePerformanceMessage == nil ? DesktopPalette.secondary(scheme) : .orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(statusText)
        }
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text(model.title)
                .font(.system(.subheadline, design: .serif).weight(.semibold))
                .foregroundStyle(DesktopPalette.text(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                Slider(
                    value: Binding(
                        get: { scrubbingOffset ?? Double(model.currentOffset) },
                        set: { scrubbingOffset = $0 }
                    ),
                    in: 0...Double(max(1, model.sourceLength)),
                    onEditingChanged: { editing in
                        if !editing {
                            let target = Int((scrubbingOffset ?? Double(model.currentOffset)).rounded())
                            scrubbingOffset = nil
                            model.seek(toCharacterOffset: target)
                        }
                    }
                )
                .disabled(model.isBusy || model.isRecording)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(Int(model.progress * 100)) percent")
                Text("\(Int(model.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DesktopPalette.secondary(scheme))
                    .frame(width: 35, alignment: .trailing)
            }

            HStack(spacing: 11) {
                Button { model.skipBackward() } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("Previous sentence")
                    .help("Previous sentence")
                    .disabled(model.isBusy || model.isRecording)
                Button(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                    model.togglePlayback()
                }
                .disabled(model.isBusy || model.isRecording)
                Button { model.skipForward() } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("Next sentence")
                    .help("Next sentence")
                    .disabled(model.isBusy || model.isRecording)
                Spacer(minLength: 0)
                Button(model.isRecording ? "Finish Margin" : "Interject",
                       systemImage: model.isRecording ? "checkmark" : "waveform") {
                    Task { await model.toggleRecording() }
                }
                .buttonStyle(DesktopPrimaryButtonStyle())
                .disabled(model.isBusy && !model.isRecording)
            }

            Button("Write Margin", systemImage: "square.and.pencil") {
                showsWrittenMargin.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .disabled(model.isBusy || model.isRecording)
            if showsWrittenMargin {
                TextEditor(text: $writtenMargin)
                    .frame(height: 72)
                    .accessibilityLabel("Written Margin")
                Button("Save Written Margin") {
                    if model.saveWrittenMargin(writtenMargin) {
                        writtenMargin = ""
                        showsWrittenMargin = false
                    }
                }
                .buttonStyle(DesktopPrimaryButtonStyle())
                .disabled(writtenMargin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !model.chapters.isEmpty {
                Button("Chapters (\(model.chapters.count))", systemImage: showsChapters ? "chevron.up" : "chevron.down") {
                    showsChapters.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption)
                if showsChapters {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.chapters.enumerated()), id: \.element.id) { index, chapter in
                                VStack(alignment: .leading, spacing: 3) {
                                    Button("\(index + 1). \(chapter.title)") { model.jumpToChapter(chapter) }
                                        .buttonStyle(.plain)
                                        .disabled(model.isBusy || model.isRecording)
                                        .accessibilityHint("Jump to \(chapter.percent) percent of the source")
                                    if let summary = model.summary(for: chapter) {
                                        Text(summary)
                                            .font(.caption)
                                            .foregroundStyle(DesktopPalette.secondary(scheme))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            if model.aiChapterSummariesEnabled {
                                if let reason = model.chapterSummaryAvailabilityMessage {
                                    Text(reason).font(.caption).foregroundStyle(.orange)
                                } else {
                                    Button(model.isGeneratingChapterSummaries ? "Generating summaries…" : "Generate Summaries") {
                                        Task { await model.generateChapterSummaries() }
                                    }
                                    .disabled(model.isBusy || model.isRecording || model.isPlaying ||
                                              model.chapterSummaries.count >= model.chapters.count)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: chapterListHeight)
                }
            }

            if !model.margins.isEmpty {
                HStack {
                    Button("Margins (\(model.margins.count))", systemImage: showsMargins ? "chevron.up" : "chevron.down") {
                        showsMargins.toggle()
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Copy Output") { model.copyOutput() }
                        .disabled(model.isBusy)
                }
                .font(.caption)
                if showsMargins {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 9) {
                            ForEach(model.margins) { margin in
                                MarginRow(margin: margin, model: model)
                            }
                        }
                    }
                    .frame(maxHeight: 165)
                }
            }
        }
    }

    private var chapterListHeight: CGFloat {
        let perChapter: CGFloat = model.aiChapterSummariesEnabled ? 66 : 32
        let actionHeight: CGFloat = model.aiChapterSummariesEnabled ? 45 : 0
        return min(180, max(56, CGFloat(model.chapters.count) * perChapter + actionHeight))
    }

    private var manualText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Enter text manually", systemImage: showsManualText ? "chevron.up" : "chevron.down") {
                showsManualText.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption)
            if showsManualText {
                TextEditor(text: $model.draft)
                    .frame(height: 85)
                    .accessibilityLabel("Text to listen to")
                Button("Listen to Text") { model.startDraft() }
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct MarginRow: View {
    @Environment(\.colorScheme) private var scheme
    let margin: DesktopMarginRow
    let model: DesktopModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(margin.context)
                .font(.caption)
                .foregroundStyle(DesktopPalette.secondary(scheme))
                .lineLimit(2)
            TextField("Your Margin", text: $text, axis: .vertical)
                .font(.system(.body, design: .serif))
                .lineLimit(2...4)
                .disabled(model.isBusy)
            HStack {
                Button("Save Edit") { model.editMargin(id: margin.id, text: text) }
                    .disabled(model.isBusy || text == margin.text || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if margin.hasAudio {
                    Button("Retry Transcript") { Task { await model.retryTranscript(id: margin.id) } }
                        .disabled(model.isBusy)
                }
            }
            .font(.caption)
        }
        .onAppear { text = margin.text }
        .onChange(of: margin.text) { text = margin.text }
    }
}
