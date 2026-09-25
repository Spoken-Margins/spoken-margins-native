import AppKit
import DesktopCore
import SessionKitSupertonic
import SwiftUI

struct DesktopSettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Bindable var model: DesktopModel
    @State private var hasAcceptedSupertonic = DesktopVoiceTerms.hasAccepted(.supertonic)
    @State private var hasAcceptedChatterbox = false
    @State private var confirmsSupertonic = false
    @State private var confirmsChatterbox = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    DesktopEyebrow(text: "Preferences")
                    Text("Listening settings")
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(DesktopPalette.text(scheme))
                    Text("Current engine: \(model.selectedBackend.title)")
                        .font(.subheadline)
                }

                DesktopSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Mac voices")
                        Picker("Language", selection: $model.selectedLanguage) {
                            ForEach(model.availableLanguages, id: \.self) { language in
                                Text(Locale.current.localizedString(forLanguageCode: language) ?? language)
                                    .tag(language)
                            }
                        }
                        .onChange(of: model.selectedLanguage) { model.updateLanguage() }
                        Picker("Voice", selection: $model.selectedVoiceID) {
                            Text("Mac default").tag("")
                            ForEach(model.filteredVoiceOptions) { voice in
                                Text("\(voice.name) · \(voice.quality)").tag(voice.id)
                            }
                        }
                        .onChange(of: model.selectedVoiceID) { model.updateVoice() }
                        Text("\(model.filteredVoiceOptions.count) installed voices for this language. Add more in System Settings → Accessibility → Read & Speak.")
                            .font(.caption)
                            .foregroundStyle(DesktopPalette.secondary(scheme))
                        Button("Use Mac voice") { model.activateBackend(.mac) }
                            .disabled(model.selectedBackend == .mac)
                    }
                }

                DesktopSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Supertonic")
                        Text("Local neural speech using the models bundled with Spoken Margins. Code: MIT; model: OpenRAIL-M.")
                            .font(.caption)
                        HStack {
                            Link("Code license", destination: URL(string: "https://github.com/supertone-oss-archive/supertonic/blob/main/LICENSE")!)
                            Link("Model terms", destination: URL(string: "https://huggingface.co/Supertone/supertonic-3/blob/main/LICENSE")!)
                        }
                        .font(.caption)
                        Picker("Voice", selection: $model.selectedSupertonicVoice) {
                            ForEach(SupertonicVoiceID.allCases, id: \.self) { voice in
                                Text(voice.rawValue).tag(voice)
                            }
                        }
                        .onChange(of: model.selectedSupertonicVoice) { model.updateSupertonicVoice() }
                        if let error = model.supertonicSetupError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        if !model.supertonicSupportsLanguage {
                            Text("This model does not support the selected language.").font(.caption).foregroundStyle(.orange)
                        }
                        if !hasAcceptedSupertonic {
                            Toggle("I have read and accept the Supertonic code and model terms", isOn: $confirmsSupertonic)
                        } else {
                            Text("Terms accepted on this Mac.").font(.caption)
                        }
                        HStack {
                            Button("Test voice") {
                                acceptSupertonicIfConfirmed()
                                Task { await model.testSupertonic() }
                            }
                            .disabled(!model.supertonicReady || !model.supertonicSupportsLanguage ||
                                      (!hasAcceptedSupertonic && !confirmsSupertonic) || model.isBusy)
                            Button(model.selectedBackend == .supertonic ? "Using Supertonic" : "Use Supertonic") {
                                acceptSupertonicIfConfirmed()
                                model.activateBackend(.supertonic)
                            }
                            .disabled(model.selectedBackend == .supertonic || !model.supertonicReady || !model.supertonicSupportsLanguage ||
                                      (!hasAcceptedSupertonic && !confirmsSupertonic))
                        }
                    }
                }

                DesktopSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Chatterbox")
                        Text("Uses your own local Python installation and model. Spoken Margins does not download models or send text to a service. A separate process has memory, swap and time limits.")
                            .font(.caption)
                        Text("Nano and Turbo currently support English only.")
                            .font(.caption)
                        let rssLimit = ChatterboxResourcePolicy.residentLimit(
                            for: model.selectedChatterboxModel,
                            physicalMemory: ProcessInfo.processInfo.physicalMemory)
                        Text("Stop limits for \(model.selectedChatterboxModel.title): \(Double(rssLimit) / 1_000_000_000, specifier: "%.1f") GB process memory, 512 MB added system swap, or 90 seconds for one load/render.")
                            .font(.caption)
                        HStack {
                            Link("Code terms", destination: URL(string: "https://github.com/resemble-ai/chatterbox/blob/master/LICENSE")!)
                            Link("Model terms", destination: URL(string: model.selectedChatterboxModel == .nano ?
                                "https://huggingface.co/ResembleAI/chatterbox-nano" :
                                "https://huggingface.co/ResembleAI/chatterbox-turbo")!)
                            Link("Setup guide", destination: URL(string: "https://github.com/resemble-ai/chatterbox#installation")!)
                        }
                        .font(.caption)
                        Picker("Model", selection: $model.selectedChatterboxModel) {
                            ForEach(DesktopChatterboxModel.allCases, id: \.self) { variant in
                                Text(chatterboxModelTitle(variant))
                                    .tag(variant)
                            }
                        }
                        .onChange(of: model.selectedChatterboxModel) {
                            model.updateChatterboxSetup()
                            hasAcceptedChatterbox = DesktopVoiceTerms.hasAccepted(.chatterbox, variant: model.selectedChatterboxModel)
                            confirmsChatterbox = false
                        }
                        HStack {
                            TextField("Python executable", text: $model.chatterboxPythonPath)
                                .onSubmit { model.updateChatterboxSetup() }
                            Button("Choose…") { choosePython() }
                        }
                        HStack {
                            TextField("Model folder", text: $model.chatterboxModelPath)
                                .onSubmit { model.updateChatterboxSetup() }
                            Button("Choose…") { chooseModelFolder() }
                        }
                        if let setupError = model.chatterboxSetupError {
                            Text(setupError)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        } else {
                            Label("Selected model files are ready to test.", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(DesktopPalette.secondary(scheme))
                        }
                        if model.selectedChatterboxModel == .nano && !model.chatterboxModelAvailable(.nano) {
                            Text("Nano needs a local folder containing t3_nano_v1.safetensors. The selected Turbo starter also needs a Nano-compatible Python runtime. Spoken Margins does not download either.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                        if let status = model.voiceRenderStatus {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text(status).font(.caption).lineLimit(2).textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if !hasAcceptedChatterbox {
                            Toggle("I have read and accept the Chatterbox code and selected model terms", isOn: $confirmsChatterbox)
                        } else {
                            Text("Terms accepted on this Mac.").font(.caption)
                        }
                        HStack {
                            Button(chatterboxTestButtonTitle) {
                                acceptChatterboxIfConfirmed()
                                Task { await model.testChatterbox() }
                            }
                            .disabled(!model.chatterboxReady || model.selectedLanguage != "en" ||
                                      (!hasAcceptedChatterbox && !confirmsChatterbox) || model.isBusy)
                            Button(model.selectedBackend == .chatterbox ? "Using Chatterbox" : "Use Chatterbox") {
                                acceptChatterboxIfConfirmed()
                                model.activateBackend(.chatterbox)
                            }
                            .disabled(model.selectedBackend == .chatterbox || !model.chatterboxReady || model.selectedLanguage != "en" ||
                                      (!hasAcceptedChatterbox && !confirmsChatterbox) || model.isBusy)
                        }
                        Text("Nano is recommended for lower memory use, but it needs its own checkpoint and a Nano-compatible Python runtime. Turbo has a higher memory limit. If rendering falls behind, switch to an installed Nano model, Supertonic, or a Mac voice.")
                            .font(.caption)
                            .foregroundStyle(DesktopPalette.secondary(scheme))
                    }
                }

                DesktopSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Playback")
                        Picker("Speed", selection: $model.rate) {
                            ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                                Text("\(rate, specifier: "%g")×").tag(rate)
                            }
                        }
                        .onChange(of: model.rate) { model.updateRate() }
                        Toggle("On-device chapter summaries", isOn: $model.aiChapterSummariesEnabled)
                            .onChange(of: model.aiChapterSummariesEnabled) { model.updateChapterSummaryPreference() }
                        Text("Off by default. When enabled, choose Generate Summaries in the chapter list. Source text stays on this Mac; Apple Intelligence availability is required.")
                            .font(.caption)
                            .foregroundStyle(DesktopPalette.secondary(scheme))
                        if let warning = model.voicePerformanceMessage {
                            Text(warning).foregroundStyle(.orange)
                            Button("Use Mac voice") { model.activateBackend(.mac) }
                        }
                        if let message = model.message {
                            Text(message).font(.caption).textSelection(.enabled)
                        }
                    }
                }

                HStack {
                    Button("Show Saved Files") { model.showFiles() }
                    Spacer()
                    Button("Quit Spoken Margins") {
                        if model.prepareToQuit() { NSApp.terminate(nil) }
                    }
                    .disabled(model.isBusy)
                }
            }
            .padding(22)
        }
        .frame(width: 540, height: 620)
        .background(DesktopPalette.bone(scheme))
        .onAppear {
            hasAcceptedChatterbox = DesktopVoiceTerms.hasAccepted(.chatterbox, variant: model.selectedChatterboxModel)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(.headline, design: .serif))
    }

    private var chatterboxTestButtonTitle: String {
        if model.isBusy { return "Testing voice…" }
        if !model.chatterboxModelAvailable(model.selectedChatterboxModel) { return "Model files needed" }
        if !model.chatterboxVariantReady(model.selectedChatterboxModel) { return "Runtime support needed" }
        return "Test voice"
    }

    private func chatterboxModelTitle(_ variant: DesktopChatterboxModel) -> String {
        if !model.chatterboxModelAvailable(variant) { return "\(variant.shortTitle) · files missing" }
        if !model.chatterboxVariantReady(variant) { return "\(variant.shortTitle) · runtime incompatible" }
        return variant.title
    }

    private func acceptChatterboxIfConfirmed() {
        if !hasAcceptedChatterbox && confirmsChatterbox {
            DesktopVoiceTerms.accept(.chatterbox, variant: model.selectedChatterboxModel)
            hasAcceptedChatterbox = true
        }
        model.updateChatterboxSetup()
    }

    private func acceptSupertonicIfConfirmed() {
        if !hasAcceptedSupertonic && confirmsSupertonic {
            DesktopVoiceTerms.accept(.supertonic)
            hasAcceptedSupertonic = true
        }
    }

    private func choosePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            model.chatterboxPythonPath = url.path
            model.updateChatterboxSetup()
        }
    }

    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.chatterboxModelPath = url.path
            model.updateChatterboxSetup()
        }
    }
}
