import SwiftUI
import SessionKit
#if canImport(UIKit)
import UIKit
#endif

struct BatchExportScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isShareSheetPresented = false
    /// Kept while the sheet closes, so its content does not blank out mid-animation.
    @State private var sharedFileURLs: [URL] = []

    private static let destinationAnchor = "batchExport.share"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Export Sessions")
                                .font(.largeTitle.bold())
                                .screenTitle()
                            Text("Choose listening sessions and share one Markdown file for each session.")
                                .foregroundStyle(AppColors.secondaryText)
                        }

                        ProductPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                Picker("Sessions", selection: $model.batchExportFilter) {
                                    Text("With Margins").tag(BatchSessionExportFilter.withInterjections)
                                    Text("All Sessions").tag(BatchSessionExportFilter.all)
                                }
                                .segmentedUnlessLargeText()
                                .accessibilityIdentifier("batchExport.filter.picker")

                                HStack {
                                    Text("\(model.selectedBatchExportSessionIds.count) selected")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Button("Select All", action: model.selectAllVisibleBatchExportSessions)
                                        .disabled(model.visibleBatchExportRows.isEmpty)
                                        .accessibilityIdentifier("batchExport.selectAll.button")
                                    Button("Clear", action: model.clearBatchExportSelection)
                                        .disabled(model.selectedBatchExportSessionIds.isEmpty)
                                        .accessibilityIdentifier("batchExport.clear.button")
                                }
                            }
                        }

                        sessionSelection

                        if !model.selectedBatchExportSessionIds.isEmpty {
                            exportOptions
                            exportAction
                                .id(Self.destinationAnchor)
                        }

                        if let result = model.batchExportResult {
                            exportResult(result)
                        }
                    }
                    .padding(20)
                }
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("batchExport.screen")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: model.openMargins) {
                            Label("Margins", systemImage: "arrow.left")
                        }
                        .accessibilityIdentifier("batchExport.home.button")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Export") {
                            jumpToDestination(using: proxy)
                        }
                        .disabled(model.selectedBatchExportSessionIds.isEmpty)
                        .accessibilityHint("Jumps to Included Material and the Export button.")
                        .accessibilityIdentifier("batchExport.jumpToDestination.button")
                    }
                }
            }
            .onChange(of: model.batchExportShare) { _, files in
                if let files { sharedFileURLs = files.fileURLs }
                isShareSheetPresented = files != nil
            }
            #if canImport(UIKit)
            .sheet(isPresented: $isShareSheetPresented, onDismiss: model.batchShareSheetDismissed) {
                BatchShareActivityView(fileURLs: sharedFileURLs) { completed, activityType in
                    model.batchShareSheetFinished(completed: completed, activityType: activityType)
                }
            }
            #endif
            .miniPlayerKeepOut()
        }
    }

    private func jumpToDestination(using proxy: ScrollViewProxy) {
        if accessibilityReduceMotion {
            proxy.scrollTo(Self.destinationAnchor, anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(Self.destinationAnchor, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private var sessionSelection: some View {
        if model.visibleBatchExportRows.isEmpty {
            ProductPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.batchExportFilter == .withInterjections ? "No sessions with Margins" : "No sessions yet")
                        .font(.headline)
                    if model.batchExportFilter == .withInterjections, !model.batchExportRows.isEmpty {
                        Text("Choose All Sessions to include listening sessions without Margins.")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.visibleBatchExportRows) { row in
                    let selected = model.selectedBatchExportSessionIds.contains(row.id)
                    Button {
                        model.toggleBatchExportSelection(sessionId: row.id)
                    } label: {
                        ProductPanel {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selected ? AppColors.green : AppColors.secondaryText)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.itemTitle)
                                        .font(.headline)
                                        .foregroundStyle(AppColors.text)
                                    Text(sessionDateDescription(row.session))
                                        .font(.subheadline)
                                        .foregroundStyle(AppColors.secondaryText)
                                    Text("\(sessionProgressDescription(row.session)) · \(row.interjectionCount) \(row.interjectionCount == 1 ? "Margin" : "Margins") · \(humanizedItemStatus(row.session.status))")
                                        .font(.caption)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityLabel("\(row.itemTitle), \(row.interjectionCount) \(row.interjectionCount == 1 ? "Margin" : "Margins"), \(row.session.completionPercent) percent complete")
                    .accessibilityIdentifier("batchExport.session.\(row.id)")
                }
            }
        }
    }

    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Included Material")
                .font(.headline)
            ProductPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Markdown", systemImage: "doc.text")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("One file per session")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Picker("Scope", selection: $model.exportScope) {
                        Text("Original").tag("original")
                        Text("Margins").tag("source_interjections")
                        Text("Full Session").tag("full_session")
                    }
                    .segmentedUnlessLargeText()
                    .accessibilityIdentifier("batchExport.scope.picker")
                    .onCompatibleChange(of: model.exportScope) { _ in model.exportOptionsChanged() }

                    Toggle("Source Text", isOn: $model.exportIncludesSourceText)
                        .accessibilityIdentifier("batchExport.includeSourceText.toggle")
                        .onCompatibleChange(of: model.exportIncludesSourceText) { _ in model.exportOptionsChanged() }
                    Toggle("Reference", isOn: $model.exportIncludesReference)
                        .accessibilityIdentifier("batchExport.includeReference.toggle")
                        .onCompatibleChange(of: model.exportIncludesReference) { _ in model.exportOptionsChanged() }
                    Toggle("Listening Map", isOn: $model.exportIncludesListeningMap)
                        .accessibilityIdentifier("batchExport.includeListeningMap.toggle")
                        .onCompatibleChange(of: model.exportIncludesListeningMap) { _ in model.exportOptionsChanged() }
                    Toggle("Margins", isOn: $model.exportIncludesInterjections)
                        .accessibilityIdentifier("batchExport.includeInterjections.toggle")
                        .onCompatibleChange(of: model.exportIncludesInterjections) { _ in model.exportOptionsChanged() }
                    Toggle("AI Turns", isOn: $model.exportIncludesTurns)
                        .accessibilityIdentifier("batchExport.includeTurns.toggle")
                        .onCompatibleChange(of: model.exportIncludesTurns) { _ in model.exportOptionsChanged() }
                }
            }
        }
    }

    private var exportAction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share")
                .font(.headline)
            ProductPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(AppColors.green)
                        Text("The share sheet opens with the files. Choose AirDrop, Save to Files or another app each time.")
                            .font(.subheadline)
                    }
                    Button { model.prepareSelectedSessionsForSharing() } label: {
                        Label("Export \(model.selectedBatchExportSessionIds.count) Session\(model.selectedBatchExportSessionIds.count == 1 ? "" : "s")", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.batchExportShare != nil || model.isPreparingBatchShare)
                    .accessibilityIdentifier("batchExport.export.button")
                }
            }
        }
    }

    private func exportResult(_ result: BatchSessionExportResult) -> some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Export Result")
                    .font(.headline)
                if !result.sharedFileNames.isEmpty {
                    Text(SessionShareFiles.sharedSummary(count: result.sharedFileNames.count, activityType: result.activityType))
                        .font(.subheadline)
                }
                ForEach(result.sharedFileNames, id: \.self) { fileName in
                    Label(fileName, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                    FailureMessageLabel(failure)
                        .font(.caption)
                }
            }
        }
        .accessibilityIdentifier("batchExport.result")
    }
}

#if canImport(UIKit)
/// The system share sheet for the batch's Markdown files. It reports whether the listener actually shared
/// (cancelling is not a share) and which activity took the files (#1528).
private struct BatchShareActivityView: UIViewControllerRepresentable {
    let fileURLs: [URL]
    let onFinished: (_ completed: Bool, _ activityType: String?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: fileURLs, applicationActivities: nil)
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            onFinished(completed, activityType?.rawValue)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
