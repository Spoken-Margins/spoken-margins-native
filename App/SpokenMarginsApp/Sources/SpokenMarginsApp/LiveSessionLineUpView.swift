import AVFoundation
import SessionKit
import SessionKitEPUB
import SwiftUI
import UniformTypeIdentifiers

/// Lines a finished live session up with the meeting's transcript (#2481), and optionally its recording.
/// Shows each Margin's evidence (transcript match, the listener's setting, the estimate) before saving.
struct LiveSessionLineUpView: View {
    let session: LiveSession
    let onSaved: () -> Void
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Picking { case transcript, recording }
    @State private var picking: Picking?
    @State private var showsImporter = false
    @State private var transcript: ImportedTranscript?
    @State private var transcriptName: String?
    @State private var recordingURL: URL?
    @State private var nudgeMs = 0
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var player: AVPlayer?

    private var result: TranscriptAlignment.Result? {
        transcript.map { TranscriptAlignment.align(session: session, transcript: $0, nudgeMs: nudgeMs) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filesCard
                    if let result { alignmentCard(result) }
                    if let errorMessage {
                        Text(errorMessage).font(.callout).foregroundStyle(AppColors.dangerText)
                    }
                    Button {
                        save()
                    } label: {
                        Label(isSaving ? "Saving…" : "Save to Library", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .filledActionButton()
                    .disabled(transcript == nil || isSaving)
                }
                .padding(20)
            }
            .background(AppColors.bone)
            .miniPlayerKeepOut()
            .navigationTitle("Line Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { stopAccess(); dismiss() } }
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: allowedTypes) { result in
            switch result {
            case .success(let url): picked(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    private var allowedTypes: [UTType] {
        switch picking {
        case .recording: [.mpeg4Movie, .mpeg4Audio, .mp3, .audio]
        default: [UTType(filenameExtension: "vtt") ?? .plainText, UTType(filenameExtension: "srt") ?? .plainText,
                  UTType(filenameExtension: "docx") ?? .data, .plainText, .text]
        }
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                picking = .transcript
                showsImporter = true
            } label: {
                Label(transcriptName.map { "Transcript: \($0)" } ?? "Choose Transcript", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)
            Button {
                picking = .recording
                showsImporter = true
            } label: {
                Label(recordingURL.map { "Recording: \($0.lastPathComponent)" } ?? "Add Recording (optional)", systemImage: "waveform")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)
            Text("Teams, Zoom, Webex, Google Meet and Otter transcripts work. With a recording, the item plays it; without one, the item is the transcript's text.")
                .font(.caption).foregroundStyle(AppColors.secondaryText)
        }
    }

    private func alignmentCard(_ result: TranscriptAlignment.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(methodLine(result)).font(.subheadline)
            PositionNudgeRow(label: "Shift unmatched Margins", adjustmentMs: Binding(get: { -nudgeMs }, set: { nudgeMs = -$0 }))
            ForEach(result.placed) { placed in
                let margin = session.margins.first { $0.id == placed.id }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(placed.source == .transcriptMatch ? LiveSessionPositionMap.clock(placed.offsetMs) : "about \(LiveSessionPositionMap.clock(placed.offsetMs))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                        Spacer()
                        if recordingURL != nil {
                            Button("Hear") { hear(placed.offsetMs) }
                                .buttonStyle(.borderless)
                                .frame(minHeight: 44)
                                .accessibilityLabel("Hear the recording at \(LiveSessionPositionMap.clock(placed.offsetMs))")
                        }
                    }
                    Text(placed.text)
                    if let margin {
                        Text(LiveSessionMarkdown.evidence(margin: margin, placed: placed, session: session))
                            .font(.caption).foregroundStyle(AppColors.secondaryText)
                    }
                    if let matched = placed.matchText {
                        Text("\u{201C}\(placed.matchSpeaker.map { "\($0): " } ?? "")\(matched)\u{201D}")
                            .font(.caption.italic()).foregroundStyle(AppColors.secondaryText)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func methodLine(_ result: TranscriptAlignment.Result) -> String {
        let count = result.matches.count
        switch result.method {
        case .textMatch: return "Lined up by \(count) Margin\(count == 1 ? "" : "s") found in the transcript."
        case .transcriptStart: return "Lined up by the transcript's start time\(count > 0 ? ", \(count) matched" : "")."
        case .roughStart: return "Lined up by where you said you were at the start\(count > 0 ? ", \(count) matched" : ""). Shift if it's off."
        }
    }

    private func picked(_ url: URL) {
        errorMessage = nil
        switch picking {
        case .recording:
            stopAccess()
            _ = url.startAccessingSecurityScopedResource()
            recordingURL = url
            player = nil
        default:
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let parsed: ImportedTranscript
                if url.pathExtension.lowercased() == "docx" {
                    parsed = try TranscriptImport.parse(text: try DocxPlainText.text(from: url))
                } else {
                    parsed = try TranscriptImport.parse(data: try Data(contentsOf: url))
                }
                transcript = parsed
                transcriptName = url.lastPathComponent
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func hear(_ offsetMs: Int) {
        guard let recordingURL else { return }
        let current = player ?? AVPlayer(url: recordingURL)
        player = current
        current.seek(to: CMTime(seconds: max(0, Double(offsetMs) / 1_000 - 3), preferredTimescale: 600))
        current.play()
    }

    private func stopAccess() {
        player?.pause()
        recordingURL?.stopAccessingSecurityScopedResource()
    }

    private func save() {
        guard let transcript, let result else { return }
        isSaving = true
        player?.pause()
        Task {
            do {
                try await model.saveLiveSession(session, transcript: transcript, placed: result.placed, recordingURL: recordingURL)
                stopAccess()
                onSaved()
            } catch {
                errorMessage = "Couldn't save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}
