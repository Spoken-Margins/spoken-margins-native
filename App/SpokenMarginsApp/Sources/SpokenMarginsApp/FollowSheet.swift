import SessionKit
import SwiftUI

/// Following's plus (#3205): one sheet that does one job, following a show. Paste follows a copied link at once and
/// the banner offers Undo; Browse opens the catalog; Papers from Zotero follows a reading list (#4341); Import from
/// Apple Podcasts opens its Shortcut's guide (#4290); Import from another app opens the file picker. Read Later and
/// Listening Edition imports live in Settings, Import & Export.
struct FollowSheet: View {
    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var catalogDrawer: CatalogDrawerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Closes this sheet and opens the catalog, which is presented from the root view.
    let browse: () -> Void
    @State private var isFollowing = false
    /// Why nothing was followed. The app's banner sits behind a sheet, so the line shows here.
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        run { await model.followFromClipboard() }
                    } label: {
                        Label("Paste a show link", systemImage: "doc.on.clipboard")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .disabled(isFollowing)
                    .accessibilityHint("Follows the show link you copied. You can undo it.")
                    .accessibilityIdentifier("sources.follow.paste")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            feedURLField
                            followButton
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            feedURLField
                            followButton
                        }
                    }
                    FollowCandidateChoices(choose: { candidate in
                        run { await model.followCandidateWithUndo(candidate) }
                    })
                } footer: {
                    if let problem {
                        Text(problem)
                            .foregroundStyle(AppColors.text)
                            .accessibilityIdentifier("sources.follow.problem")
                    } else {
                        Text(FollowPasteDecision.sheetFooter)
                            .accessibilityIdentifier("sources.follow.footer")
                    }
                }
                Section {
                    Button(action: browse) {
                        Label("Browse podcasts and writers", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("sources.browseCatalog")
                    // #4341: a reading list from Zotero, followed as papers.
                    NavigationLink {
                        FollowPapersScreen(done: { dismiss() })
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Papers from Zotero", systemImage: "doc.text.magnifyingglass")
                            Text("Follow a reading list")
                                .font(.footnote)
                                .foregroundStyle(AppColors.secondaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("sources.followPapers")
                    if let makeOPMLImport = catalogDrawer.makeOPMLImport {
                        #if !SPOKEN_MARGINS_LEGACY
                        // This sheet closes once the Shortcut's link is taken: the drawer the preview opens in can't
                        // present over it when the Shortcut brings the listener back (#4290).
                        ApplePodcastsImportRow(closeHostWhenOpened: { dismiss() })
                            .accessibilityIdentifier("sources.importApplePodcasts")
                        #endif
                        NavigationLink {
                            OPMLImportScreen(importer: makeOPMLImport(), opensFilePickerOnAppear: true)
                        } label: {
                            Label("Import from another app", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("sources.importOPML")
                    }
                }
            }
            .background(AppColors.bone)
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .accessibilityIdentifier("sources.manageFeeds.screen")
            .navigationTitle(FollowPasteDecision.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("sources.follow.cancel")
                }
            }
        }
    }

    private var feedURLField: some View {
        AppTextField("Paste an RSS feed link", text: $model.followedSourceURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.URL)
            .keyboardType(.URL)
            .submitLabel(.go)
            .onSubmit { run { await model.followTypedLink() } }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(AppColors.border) }
            .accessibilityIdentifier("sources.follow.url")
    }

    private var followButton: some View {
        Button { run { await model.followTypedLink() } } label: {
            Text("Follow").frame(minHeight: 46).contentShape(Rectangle())
        }
            .filledActionButton()
            .disabled(isFollowing || model.followedSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("sources.follow.button")
    }

    /// One follow at a time. The sheet closes once the show is followed, so the banner and the new row show.
    private func run(_ follow: @escaping () async -> Gate1AppModel.FollowLinkOutcome) {
        guard !isFollowing else { return }
        isFollowing = true
        problem = nil
        Task {
            let outcome = await follow()
            isFollowing = false
            switch outcome {
            case .followed: dismiss()
            case .needsChoice: problem = Gate1AppModel.chooseFeedMessage
            case .stopped(let line): problem = line
            }
        }
    }
}
