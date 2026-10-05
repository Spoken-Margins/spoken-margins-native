import SwiftUI
import SessionKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct BatchExportScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isFolderImporterPresented = false

    private static let destinationAnchor = "batchExport.destination"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Export Sessions")
                                .font(.largeTitle.bold())
                            Text("Choose listening sessions and save one Markdown file for each session.")
                                .foregroundStyle(AppColors.secondaryText)
                        }

                        ProductPanel {
                            VStack(alignment: .leading, spacing: 14) {
                                Picker("Sessions", selection: $model.batchExportFilter) {
                                    Text("With Margins").tag(BatchSessionExportFilter.withInterjections)
                                    Text("All Sessions").tag(BatchSessionExportFilter.all)
                                }
                                .pickerStyle(.segmented)
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
                            destination
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
                        .accessibilityHint("Jumps to Included Material and Destination.")
                        .accessibilityIdentifier("batchExport.jumpToDestination.button")
                    }
                }
            }
            .fileImporter(
                isPresented: $isFolderImporterPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let folder = urls.first {
                        model.configureBatchExportFolder(url: folder)
                    }
                case .failure(let error):
                    model.reportBatchExportFolderFailure(error)
                }
            }
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
                    Text(model.batchExportFilter == .withInterjections ? "No sessions with interjections" : "No sessions yet")
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
                    .accessibilityLabel("\(selected ? "Deselect" : "Select") \(row.itemTitle), \(row.interjectionCount) interjections, \(row.session.completionPercent) percent complete")
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
                        Text("Source Notes").tag("source_interjections")
                        Text("Full Session").tag("full_session")
                    }
                    .pickerStyle(.segmented)
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
                    Toggle("Interjections", isOn: $model.exportIncludesInterjections)
                        .accessibilityIdentifier("batchExport.includeInterjections.toggle")
                        .onCompatibleChange(of: model.exportIncludesInterjections) { _ in model.exportOptionsChanged() }
                    Toggle("AI Turns", isOn: $model.exportIncludesTurns)
                        .accessibilityIdentifier("batchExport.includeTurns.toggle")
                        .onCompatibleChange(of: model.exportIncludesTurns) { _ in model.exportOptionsChanged() }
                }
            }
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Destination")
                .font(.headline)
            ProductPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(AppColors.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.hasBatchExportFolder ? model.batchExportFolderName : "Choose a folder")
                                .font(.subheadline.weight(.semibold))
                            Text("Spoken Margins remembers this destination for future exports.")
                                .font(.caption)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                    }
                    Button {
                        isFolderImporterPresented = true
                    } label: {
                        Label(model.hasBatchExportFolder ? "Change Folder" : "Choose Folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("batchExport.chooseFolder.button")

                    Button(action: model.exportSelectedSessionsToFolder) {
                        if model.isWritingBatchExport {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Exporting")
                            }
                        } else {
                            Label("Export \(model.selectedBatchExportSessionIds.count) Session\(model.selectedBatchExportSessionIds.count == 1 ? "" : "s")", systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.hasBatchExportFolder || model.isWritingBatchExport)
                    .accessibilityIdentifier("batchExport.write.button")
                }
            }
        }
    }

    private func exportResult(_ result: BatchSessionExportResult) -> some View {
        ProductPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Export Result")
                    .font(.headline)
                Text("\(result.exportedFileNames.count) saved to \(result.destinationName)")
                    .font(.subheadline)
                ForEach(result.exportedFileNames, id: \.self) { fileName in
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
