import SwiftUI

struct Gate1RootView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "text.page") }
            SessionView()
                .tabItem { Label("Session", systemImage: "waveform") }
            DiscussionView()
                .tabItem { Label("Discuss", systemImage: "bubble.left.and.bubble.right") }
            ExportView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .onAppear {
            model.resetAndSeed()
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        NavigationStack {
            Form {
                Picker("Runtime Profile", selection: $model.selectedProfileId) {
                    Text("Phone/Tablet Online").tag("phone-tablet-online")
                    Text("Phone/Tablet Offline").tag("phone-tablet-offline")
                }
                Button("Reset And Seed Fixtures", action: model.resetAndSeed)
                Button("Start Seeded Session", action: model.start)
                Section("Import Text") {
                    TextField("Title", text: $model.importTitle)
                    TextEditor(text: $model.importText)
                        .frame(minHeight: 120)
                    Button("Import And Start", action: model.importTextItem)
                }
                Section("Seeded Item") {
                    Text("You Can't Inspect the Pill")
                    Text("Contains source text suitable for mapless playback, interjections, summaries, offline deferral, and session export.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Library")
        }
    }
}

struct SessionView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.snapshot.title ?? "No Session")
                        .font(.title2)
                        .bold()
                    Text(model.snapshot.chapterTitle ?? "No chapter")
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(model.snapshot.progressPercent), total: 100)
                }
                HStack {
                    Button(action: model.skipBack) {
                        Label("Back", systemImage: "gobackward")
                    }
                    Button(action: model.start) {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button(action: model.skipForward) {
                        Label("Forward", systemImage: "goforward")
                    }
                }
                .buttonStyle(.bordered)
                HStack {
                    Button(action: model.beginInterjection) {
                        Label("Interject", systemImage: "mic.fill")
                    }
                    Button(action: model.finishInterjection) {
                        Label("Finish", systemImage: "checkmark.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                List {
                    LabeledContent("Phase", value: model.snapshot.phase.rawValue)
                    LabeledContent("Status", value: model.snapshot.status.rawValue)
                    LabeledContent("Interjections", value: "\(model.snapshot.activeInterjectionCount)")
                    LabeledContent("Pending AI Jobs", value: "\(model.snapshot.pendingAiJobCount)")
                }
            }
            .padding()
            .navigationTitle("Session")
        }
    }
}

struct DiscussionView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @State private var followUp = "Can you respond to that objection?"

    var body: some View {
        NavigationStack {
            Form {
                Button("Generate Interjection Summary", action: model.summarize)
                TextField("Follow-up", text: $followUp, axis: .vertical)
                Button("Submit Follow-up") {
                    model.followUp(followUp)
                }
                Section("AI State") {
                    LabeledContent("Pending Kind", value: model.snapshot.pendingAiJobKind ?? "none")
                    LabeledContent("Pending Status", value: model.snapshot.pendingAiJobStatus ?? "none")
                    LabeledContent("Provider Started", value: model.snapshot.providerCallStarted ? "yes" : "no")
                }
            }
            .navigationTitle("Discussion")
        }
    }
}

struct ExportView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Button("Build Session Export", action: model.buildExport)
                    .buttonStyle(.borderedProminent)
                ScrollView {
                    Text(model.exportPreview.isEmpty ? "No export yet." : model.exportPreview)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .navigationTitle("Export")
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var model: Gate1AppModel

    var body: some View {
        NavigationStack {
            List {
                Button("Refresh Diagnostics", action: model.refreshDiagnostics)
                Section("Diagnostics") {
                    ForEach(model.diagnostics.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: model.diagnostics[key] ?? "")
                    }
                }
                Section("Known Issues") {
                    ForEach(model.knownIssues, id: \.self) { issue in
                        Text(issue)
                    }
                }
            }
            .navigationTitle("Diagnostics")
        }
    }
}
