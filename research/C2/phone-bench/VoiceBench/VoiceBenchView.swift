// C2 M2 phone benchmark: the VoiceBench app's only screen. See ../README.md.
import SwiftUI

struct VoiceBenchView: View {
    @State private var running = false
    @State private var status = "Warm the phone, turn on Low Power Mode, then tap Run all."
    @State private var report: VoiceBenchReport?
    @State private var savedURL: URL?

    var body: some View {
        List {
            Section {
                Button(running ? "Running…" : "Run all") { start() }
                    .disabled(running)
                    .accessibilityIdentifier("voiceBench.runAll")
                Text(status).font(.footnote).foregroundStyle(.secondary)
                Text("Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off") · Thermal: \(VoiceBenchDevice.thermal)")
                    .font(.footnote.monospacedDigit())
            } footer: {
                Text("Keep the screen on; a run takes about 3 minutes.")
            }
            if let report {
                Section("Results") {
                    ForEach(Array(report.engines.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.engine) · \(e.threads) thr").font(.headline)
                            if let error = e.error {
                                Text(error).foregroundStyle(.red)
                            } else {
                                Text(String(format: "%.1f× real time · first audio %.2f s · peak %.0f MB",
                                            e.speedX, e.medianTimeToFirstAudioSeconds, e.peakFootprintMB))
                                    .font(.subheadline.monospacedDigit())
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if let savedURL {
                    Section {
                        ShareLink(item: savedURL) { Label("Share results JSON", systemImage: "square.and.arrow.up") }
                    } footer: {
                        Text("Post the JSON on issue #192. Pass: Kitten fp32 at 4× real time or faster, with Low Power Mode on.")
                    }
                }
            }
        }
        .navigationTitle("Voice benchmark")
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func start() {
        running = true
        report = nil
        savedURL = nil
        Task.detached(priority: .userInitiated) {
            let result = await VoiceBench.runAll { message in
                await MainActor.run { status = message }
            }
            let url = try? VoiceBench.save(result)
            await MainActor.run {
                report = result
                savedURL = url
                status = url == nil ? "Done, but the JSON couldn't be saved." : "Done."
                running = false
            }
        }
    }
}
