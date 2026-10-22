import ReplayKit
import SessionKit
import SwiftUI

/// Live capture (#2481, prototype): add Margins to audio playing in any app. The system broadcast picker starts
/// the capture extension; this screen shows whether audio is arriving and takes Margins at the capture's time.
struct LiveCaptureView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = LiveCaptureController()
    @AppStorage("liveCapture.consentAccepted") private var consentAccepted = false
    @AppStorage("liveCapture.transcribe") private var transcribe = false
    @State private var showsConsent = false
    @State private var marginText = ""
    @State private var confirmsDiscard = false
    @FocusState private var marginFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    captureCard
                    marginCard
                    if !controller.margins.isEmpty { marginList }
                    finishCard
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.bone)
            .navigationTitle("Live capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            if consentAccepted {
                controller.prepare(transcribe: transcribe)
            } else {
                showsConsent = true
            }
        }
        .onDisappear { controller.stopPolling() }
        .sheet(isPresented: $showsConsent) {
            LiveCaptureConsentSheet(transcribe: $transcribe) {
                consentAccepted = true
                showsConsent = false
                controller.prepare(transcribe: transcribe)
            } onCancel: {
                showsConsent = false
                dismiss()
            }
            .interactiveDismissDisabled()
        }
        .alert("Live capture", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .confirmationDialog("Discard this capture and its Margins?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("Discard Capture", role: .destructive) {
                controller.discard()
                dismiss()
            }
        }
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                BroadcastPickerButton()
                    .frame(width: 60, height: 60)
                    .background(AppColors.softGreen, in: Circle())
                    .accessibilityLabel(controller.isRunning ? "Stop capture" : "Start capture")
                VStack(alignment: .leading, spacing: 4) {
                    Text(stateTitle).font(.headline).foregroundStyle(AppColors.text)
                    Text(stateDetail).font(.caption).foregroundStyle(AppColors.secondaryText)
                }
            }
            Text(Self.clock(controller.elapsedMs))
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(AppColors.text)
                .accessibilityLabel("Elapsed \(Self.clock(controller.elapsedMs))")
            LiveCaptureLevelMeter(rms: controller.status?.rms ?? 0, peak: controller.status?.peak ?? 0, active: controller.isReceivingAudio)
            Text(diagnostics)
                .font(.caption2.monospaced())
                .foregroundStyle(AppColors.secondaryText)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(AppColors.border) }
    }

    private var stateTitle: String {
        guard let status = controller.status else { return "Not started" }
        switch status.state {
        case .running: return controller.isReceivingAudio ? "Capturing audio" : "Capturing, no audio arriving"
        case .stopped: return "Stopped"
        case .failed: return "Capture failed"
        }
    }

    private var stateDetail: String {
        guard let status = controller.status else {
            return "Tap the button, choose Spoken Margins Live, then Start Broadcast. Then play audio in any app."
        }
        if status.state == .running {
            return "Switch to the other app and play. To stop, come back and tap the button, or tap the red status pill."
        }
        return "Tap Save to Library below, or start again to keep adding to this capture."
    }

    private var diagnostics: String {
        guard let status = controller.status else { return "No status from the extension yet." }
        var parts: [String] = []
        parts.append(status.sourceFormat?.summary ?? "format: none yet")
        parts.append("buffers \(status.buffersReceived), all-zero \(status.zeroBuffers)")
        parts.append(String(format: "peak %.3f · rms %.4f", status.peak, status.rms))
        parts.append(String(format: "%.1f s written, %.1f s silence padding", Double(status.samplesWritten) / 16_000, Double(status.paddedSamples) / 16_000))
        if let failure = status.failure { parts.append("error: \(failure)") }
        return parts.joined(separator: "\n")
    }

    private var marginCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add Margin").font(.headline)
            TextField("Your note at this moment", text: $marginText, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($marginFieldFocused)
            Button {
                controller.addMargin(text: marginText)
                marginText = ""
                marginFieldFocused = false
            } label: {
                Label("Add Margin at \(Self.clock(controller.elapsedMs))", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.evergreen)
            .disabled(marginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("The Margin's time is when you tap Add. Spoken Margins aren't in this prototype yet.")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var marginList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Margins (\(controller.margins.count))").font(.headline)
            ForEach(controller.margins) { margin in
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.clock(margin.offsetMs)).font(.caption.monospacedDigit()).foregroundStyle(AppColors.secondaryText)
                    Text(margin.text).frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        controller.removeMargin(id: margin.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove Margin")
                }
            }
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var finishCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Transcribe on this phone after saving", isOn: $transcribe)
            Button {
                Task {
                    if await controller.finish(model: model, transcribe: transcribe) { dismiss() }
                }
            } label: {
                Label(controller.isFinishing ? "Saving…" : "Save to Library", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.evergreen)
            .disabled(!controller.canFinish)
            if controller.isRunning {
                Text("Stop the capture first, then save.").font(.caption).foregroundStyle(AppColors.secondaryText)
            }
            if controller.status != nil {
                Button("Discard Capture", role: .destructive) { confirmsDiscard = true }
                    .disabled(controller.isRunning || controller.isFinishing)
            }
        }
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    static func clock(_ ms: Int) -> String {
        let seconds = max(0, ms / 1_000)
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let secs = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// The level meter: blue while audio arrives, orange when the capture runs but receives nothing, so the colour
/// never carries meaning alone (the label says the same).
private struct LiveCaptureLevelMeter: View {
    let rms: Float
    let peak: Float
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(AppColors.border.opacity(0.4))
                    Capsule()
                        .fill(active ? Color.blue : Color.orange)
                        .frame(width: proxy.size.width * CGFloat(Self.scaled(rms)))
                    Rectangle()
                        .fill(AppColors.text)
                        .frame(width: 2)
                        .offset(x: proxy.size.width * CGFloat(Self.scaled(peak)))
                }
            }
            .frame(height: 12)
            Text(active ? (peak > 0.001 ? "Audio arriving" : "Buffers arriving, but silent") : "No audio arriving")
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    /// A rough dB scale: -60 dB at the left edge, 0 dB at the right.
    static func scaled(_ level: Float) -> Float {
        guard level > 0 else { return 0 }
        let db = 20 * log10(level)
        return max(0, min(1, (db + 60) / 60))
    }
}

/// The system broadcast picker, preset to the live capture extension.
private struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = LiveCaptureFiles.extensionBundleIdentifier
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// Shown once before the first capture.
private struct LiveCaptureConsentSheet: View {
    @Binding var transcribe: Bool
    let onAccept: () -> Void
    let onCancel: () -> Void
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Before you capture").font(.title2.weight(.bold))
                    Text("Live capture records the sound other apps play on this phone, such as a video or a call, so you can add Margins to it. The recording stays on this phone and is saved to your Library when you stop.")
                    Text("Recording people without their permission can be against the law where you or they are. On a call, that includes everyone else on it.")
                    Toggle(isOn: $confirmed) {
                        Text("I have permission from everyone whose voice or audio I capture, including others on a call.")
                    }
                    Toggle(isOn: $transcribe) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Transcribe captures")
                            Text("Off by default. Runs on this phone after you save; nothing is sent anywhere.")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    Button {
                        onAccept()
                    } label: {
                        Text("Continue").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppColors.evergreen)
                    .disabled(!confirmed)
                }
                .padding(20)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
