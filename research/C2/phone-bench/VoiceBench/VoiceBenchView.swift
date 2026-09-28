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
                Text("Keep the app open; a run takes about 5 minutes. The screen stays on by itself.")
            }
            if let report {
                if let kitten = report.engines.filter({ $0.engine.contains("fp32") && $0.error == nil }).max(by: { $0.speedX < $1.speedX }) {
                    Section("Kitten fp32, best") {
                        Text(String(format: "%.1f× real time: %@ the 4× bar", kitten.speedX,
                                    kitten.speedX >= 4 ? "meets" : "below"))
                            .font(.title3.monospacedDigit().bold())
                    }
                }
                Section("Results") {
                    ForEach(Array(report.engines.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.engine) · \(e.threads) thr").font(.headline)
                            if let error = e.error {
                                Label("Failed: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
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
                        Text("AirDrop the JSON to the Mac. Pass: Kitten fp32 at 4× real time or faster, with Low Power Mode on and the phone warm.")
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
