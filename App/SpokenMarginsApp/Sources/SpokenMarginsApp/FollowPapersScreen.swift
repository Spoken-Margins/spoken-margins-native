import SessionKit
import SessionKitFeeds
import SwiftUI
import UIKit

/// Follow papers (#4341), pushed from the Follow sheet's "Papers from Zotero" row: a how-to, one paste field for a
/// public Zotero group's collection, and, once the listener's own library is connected in Settings, Your collections to
/// follow with a tap. Any other link goes to today's feed follow. Following a list closes the sheet; the banner offers
/// Undo and Following shows the new row.
struct FollowPapersScreen: View {
    @EnvironmentObject private var model: Gate1AppModel
    @ObservedObject private var papers = PaperSourcesState.shared
    /// Closes the whole Follow sheet.
    let done: () -> Void

    @State private var link = ""
    @State private var problem: String?
    @State private var isFollowing = false

    var body: some View {
        List {
            Section {
                Text("Open a public group's collection on zotero.org and copy the address from the browser.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.text)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { field; buttons }
                    VStack(alignment: .leading, spacing: 10) { field; buttons }
                }
            } header: {
                Text("Zotero")
            } footer: {
                if let problem, !problem.isEmpty {
                    Text(problem)
                        .foregroundStyle(AppColors.text)
                        .accessibilityIdentifier("papers.follow.problem")
                } else if papers.connection == nil {
                    Text("Private library? Connect it in Settings.")
                }
            }
            if papers.connection != nil {
                yourCollections
            }
        }
        .background(AppColors.bone)
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
        .navigationTitle("Follow papers")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("papers.follow.screen")
        .task { await papers.loadCollections() }
    }

    private var field: some View {
        AppTextField("Paste a Zotero link", text: $link)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.URL)
            .keyboardType(.URL)
            .submitLabel(.go)
            .onSubmit { follow() }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(AppColors.border) }
            .accessibilityIdentifier("papers.follow.url")
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button {
                if let copied = UIPasteboard.general.string { link = copied.trimmingCharacters(in: .whitespacesAndNewlines) }
            } label: {
                Text("Paste").frame(minHeight: 46).contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .disabled(isFollowing)
            .accessibilityIdentifier("papers.follow.paste")
            Button { follow() } label: {
                Group {
                    if isFollowing { ProgressView() } else { Text("Follow") }
                }
                .frame(minHeight: 46).contentShape(Rectangle())
            }
            .filledActionButton()
            .disabled(isFollowing || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("papers.follow.button")
        }
    }

    @ViewBuilder
    private var yourCollections: some View {
        Section {
            followRow(title: PaperSourceFetcher.ownLibraryTitle, detail: "Every paper in your library", collection: nil)
            ForEach(papers.collections) { collection in
                followRow(
                    title: collection.name,
                    detail: collection.itemCount.map { "\($0) \($0 == 1 ? "entry" : "entries")" },
                    collection: collection
                )
            }
            if papers.isLoadingCollections && papers.collections.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 44)
            }
        } header: {
            Text("Your collections")
        } footer: {
            if let line = papers.collectionsProblem { Text(line).foregroundStyle(AppColors.text) }
        }
    }

    private func followRow(title: String, detail: String?, collection: ZoteroCollection?) -> some View {
        let source = papers.connection.map { PaperSource.zoteroUser(userID: $0.userID, collectionKey: collection?.key) }
        let followed = source.map { source in papers.records.contains { $0.id == source.identifier } } ?? false
        return Button {
            guard !isFollowing, !followed else { return }
            isFollowing = true
            problem = nil
            Task {
                let result = await papers.follow(collection: collection, model: model)
                isFollowing = false
                switch result {
                case .followed: done()
                case .problem(let line): problem = line
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: collection == nil ? "books.vertical" : "folder")
                    .foregroundStyle(AppColors.evergreen)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(AppColors.text)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(AppColors.secondaryText)
                    }
                }
                Spacer()
                if followed {
                    Label("Following", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFollowing)
        .accessibilityHint(followed ? "Already followed." : "Follows this collection's papers.")
        .accessibilityIdentifier("papers.collection.\(collection?.key ?? "library")")
    }

    private func follow() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isFollowing, !text.isEmpty else { return }
        isFollowing = true
        problem = nil
        Task {
            let result = await papers.follow(pasted: text, model: model)
            isFollowing = false
            switch result {
            case .followed: done()
            case .problem(let line): problem = line
            }
        }
    }
}
