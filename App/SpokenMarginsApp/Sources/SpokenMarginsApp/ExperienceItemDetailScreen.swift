import SwiftUI
import SessionKit
import SessionKitPersistence

struct ExperienceItemDetailScreen: View {
    /// The tab the back button lands on (#3214): the Item screen replaces the tab view, so back shows the tab
    /// the listener left. It names that tab instead of always saying "Library".
    let backTitle: String

    init(backTitle: String = AppRoot.library.itemBackTitle) {
        self.backTitle = backTitle
    }

    @EnvironmentObject private var model: Gate1AppModel
    @EnvironmentObject private var sharingCoordinator: Build23SharingCoordinator
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Saved live-session photos for Recent Margins (#4180), observed directly so they appear once the launch load finishes.
    @ObservedObject private var photoIndex = SavedMarginPhotoIndex.shared

    @State private var confirmsTrash = false
    /// Why Share has nothing to send, when it has none (#4229).
    @State private var shareExplanation: ItemShareStart.Explanation?
    /// Share is re-reading the item's Margins; a second tap meanwhile does nothing.
    @State private var checksShare = false
    @State private var confirmsNewSession = false
    @State private var showsAdvanced = false
    /// Set while Continue waits on the "hear new Margins first?" question (#474). The item screen asks it only when no friend Margins wait (#3219).
    @State private var pendingNewMarginsOffer: NewMarginsOfferRequest?
    @State private var episodeLinkStatus = ImportedFileEpisodeLinker.Status()
    /// True while a link or unlink saves, so a second tap cannot race it.
    @State private var isChangingEpisodeLink = false
    @State private var asksForEpisodeLink = false
    @State private var episodeLinkText = ""
    @State private var showsReactions = false
    @State private var collectionItem: LibraryItemRow?
    /// A Margin with no place, opened from Recent Margins (#4233): it has no moment to show in the Timeline.
    @State private var unplacedMargin: MarginRow?
    /// Whether the open item is a PDF, so the menu offers "Export PDF with Margins" (#4338). Looked up off the main thread
    /// when the item opens, with the kept copy of its file when this iPhone holds one (`keptPDFOriginal`). With no copy
    /// the sheet asks the listener to choose the file (PR 6).
    @State private var isPDFItem = false
    @State private var keptPDFOriginal: URL?
    /// The kept copy of this item's Word document, when it was added as one and this iPhone holds its file: the only
    /// case the menu offers "Export Word document with Margins" (#4595).
    @State private var keptWordOriginal: URL?
    @State private var pdfExport: PDFCommentExportModel?
    /// A tap on Play or "Skip to …" made before its start is possible, kept until it can run (#3788).
    @StateObject private var arrival = FriendArrivalPresenter()
    private let episodeLinker = ImportedFileEpisodeLinker()

    /// Finds whether the open item is a PDF, or a Word document with a kept original (#4338, #4595). A PDF needs only the
    /// Library row: with no kept .pdf the sheet asks for the file. Word needs a kept .docx, and a kept .docx wins over a
    /// row that reads as a PDF, so no row offers the wrong export.
    private func refreshKeptOriginal() async {
        let id = model.selectedItem.id
        guard !id.isEmpty, let row = model.libraryItems.first(where: { $0.id == id }) else {
            isPDFItem = false
            keptPDFOriginal = nil
            keptWordOriginal = nil
            return
        }
        let isPDF = LibraryQueryEngine.isPDF(row)
        let kept = await model.keptOriginal(itemId: id)
        guard id == model.selectedItem.id else { return }
        isPDFItem = isPDF && kept?.kind != .docx
        keptPDFOriginal = isPDF && kept?.kind == .pdf ? kept?.url : nil
        // The kept file's own kind is authoritative for Word: a file named "x.pdf.docx" reads as a PDF row by its name.
        keptWordOriginal = kept?.kind == .docx ? kept?.url : nil
    }

    private func openPDFExport() {
        guard isPDFItem else { return }
        openCommentExport(original: keptPDFOriginal, document: .pdf)
    }

    private func openWordExport() {
        guard let original = keptWordOriginal else { return }
        openCommentExport(original: original, document: .word)
    }

    private func openCommentExport(original: URL?, document: PDFCommentExportState.Document) {
        let id = model.selectedItem.id
        pdfExport = PDFCommentExportModel(
            itemId: id, itemTitle: model.selectedItem.title, original: original,
            margins: model.ownMargins(itemId: id), store: model.store, originals: try? model.pdfOriginalStore(),
            document: document)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // A plain stack, not a lazy one: on a friend's item the lazy stack's placement and its on-screen
                // bookkeeping fed each other and never settled, freezing the screen on scroll (#3781). The sections are short.
                VStack(alignment: .leading, spacing: 22) {
                    // A friend's waiting Margins lead: who sent them, then the title, then how many and what a
                    // Margin is (#3219). Mark complete stays in the options menu until they're heard (2026-11-02).
                    let friendIntro = FriendMarginsIntro(unheardFriendMargins: newSharedMargins.map(\.waitingMargin))
                    if let friendIntro { FriendMarginsSenderLine(intro: friendIntro) }
                    hero
                    if let friendIntro { FriendMarginsSummary(intro: friendIntro, receipt: sharingCoordinator.introReceipt) }
                    if let description = model.selectedItem.descriptionText {
                        ItemDescriptionPreview(text: description).id(model.selectedItem.id)
                    }
                    secondaryActions
                    if friendIntro == nil { completionControl }
                    downloadRecovery
                    ItemLastFailureCard(itemId: model.selectedItem.id)
                    if !sharingCoordinator.importedLayers.isEmpty {
                        Build23ImportedMarginPresentation(
                            coordinator: sharingCoordinator, hidesHeading: friendIntro != nil, friendIntroShowing: friendIntro != nil
                        )
                    }
                    reactionsEntry
                    SourceFollowSuggestionCard()
                    ManualSourceFollowButton()
                    if !model.selectedItem.overview.isEmpty { overview }
                    // A PDF's Paper note: purpose, findings and evidence from the listener's own Margins (#4340).
                    if model.offersPaperNote(itemId: model.selectedItem.id) { PaperNoteSection() }
                    sessions
                    structure
                    if let edition = model.selectedListeningEdition { ListeningEditionScenes(edition: edition) }
                    if !model.selectedItem.listeningMapScenes.isEmpty { listeningMap }
                    recentMargins
                    itemLinks
                    advanced
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 30 : 18)
                .padding(.vertical, 22)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            // The main listening button stays pinned at the bottom, within thumb reach, above the mini player (#149).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) { primaryPlaybackAction }
                    .padding(.horizontal, horizontalSizeClass == .regular ? 30 : 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                    .background(AppColors.bone)
            }
            .background(AppColors.bone)
            // A container, not a stamp: a bare identifier here is copied onto the pinned Play and "Skip to"
            // buttons in the inset above and replaces their own, so tests and journeys can't find them (#3818).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("item.screen")
            .announcesScreenChange()
            .navigationTitle(model.selectedItem.sourceNoun.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: model.openHome) {
                        Label(backTitle, systemImage: "arrow.left")
                    }
                    .accessibilityLabel("Back to \(backTitle)")
                    .accessibilityIdentifier("item.home.button")
                }
                // Share sits before the options menu, so the header reads back, title, Share, options (#4229). It is the
                // friend sheet the player opens; Export, in the menu, takes text out for yourself.
                if !model.selectedItem.id.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: share) {
                            Label("Share Margins", systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Share Margins")
                        .accessibilityHint("Sends your Margins here to a friend")
                        .accessibilityIdentifier("item.share.button")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !model.selectedItem.id.isEmpty {
                            Button("Share Margins", systemImage: "square.and.arrow.up", action: share)
                                .accessibilityIdentifier("item.menu.share.button")
                        }
                        Button("Export", systemImage: "doc.text") {
                            model.openExport(sessionId: model.selectedItem.sessions.first?.id)
                        }
                        .disabled(model.selectedItem.sessions.isEmpty)
                        // A copy of the PDF with the listener's own Margins as comments (#4338). For every PDF item: with no
                        // copy on this iPhone the sheet asks for the file. Off while the item has no Margin of the listener's own.
                        if isPDFItem {
                            Button(PDFCommentExportState.Document.pdf.menuTitle, systemImage: "doc.richtext", action: openPDFExport)
                                .disabled(model.ownMargins(itemId: model.selectedItem.id).isEmpty)
                                .accessibilityIdentifier("item.menu.exportPDF.button")
                        }
                        // The same for a Word document: a copy with the listener's own Margins as real Word comments (#4595).
                        if keptWordOriginal != nil {
                            Button(PDFCommentExportState.Document.word.menuTitle, systemImage: "doc.text", action: openWordExport)
                                .disabled(model.ownMargins(itemId: model.selectedItem.id).isEmpty)
                                .accessibilityIdentifier("item.menu.exportWord.button")
                        }
                        quickActionButtons
                        if episodeLinkStatus.canLink && !episodeLinkStatus.canChange {
                            Button("Episode can't change: friends' Margins are on it", systemImage: "link") {}
                                .disabled(true)
                        }
                        if episodeLinkStatus.canLink && episodeLinkStatus.canChange {
                            Button(
                                episodeLinkStatus.episodeTitle == nil ? "This is a podcast episode…" : "Change linked episode…",
                                systemImage: "link.badge.plus"
                            ) {
                                episodeLinkText = ""
                                asksForEpisodeLink = true
                            }
                            .disabled(isChangingEpisodeLink)
                            .accessibilityIdentifier("item.linkEpisode.button")
                            if episodeLinkStatus.episodeTitle != nil {
                                Button("Unlink episode", systemImage: "minus.circle") { unlinkEpisode() }
                                    .disabled(isChangingEpisodeLink)
                            }
                        }
                        // A friend's link opens its share page, where the report form is; no account and no key (#2239).
                        ForEach(sharingCoordinator.reportEntries) { entry in
                            Link(destination: entry.url) {
                                Label(entry.title, systemImage: "flag")
                            }
                            .accessibilityHint("Opens the share page in your browser, where you can report this link.")
                            .accessibilityIdentifier("item.reportLink.\(entry.id)")
                        }
                        if !model.selectedItem.id.isEmpty {
                            Button("Move to Recently Deleted", systemImage: "trash", role: .destructive) {
                                confirmsTrash = true
                            }
                            .accessibilityIdentifier("item.delete.button")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("\(model.selectedItem.sourceNoun.capitalized) options")
                }
            }
            .task(id: model.selectedItem.id) { await refreshEpisodeLinkStatus() }
            // Runs again when the item's Library row arrives, so the entry is not missed on a screen opened before the row.
            .task(id: "\(model.selectedItem.id)|\(model.libraryItems.contains { $0.id == model.selectedItem.id })") {
                await refreshKeptOriginal()
            }
            .task(id: WrittenMarginReadings.waitingKey(model.selectedItem)) { WrittenMarginReadings.prepare(newSharedMargins) } // readings ready before "Skip to the Margins" (#3365)
            .onDisappear {
                WrittenMarginReadings.leftItemScreen(model.selectedItem.id)
                arrival.cancel()
            }
            .trackedSheet(item: $pdfExport) { export in
                PDFCommentExportSheet(export: export) { count in
                    model.presentFeedback(UserFeedbackEvent(kind: .success, message: PDFCommentExportState.doneMessage(count: count)))
                }
            }
            .trackedSheet(item: $collectionItem) { item in
                ItemCollectionSheet(item: item).environmentObject(model)
            }
            .trackedSheet(isPresented: $showsReactions) {
                ExperienceReactionsScreen().environmentObject(model)
            }
            .trackedSheet(item: $unplacedMargin) { row in
                ExperienceMarginDetailView(row: row).environmentObject(model)
            }
            .alert("Which episode is this?", isPresented: $asksForEpisodeLink) {
                TextField("Episode link", text: $episodeLinkText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Link") { linkEpisode() }
            } message: {
                Text("Paste the link to this episode, like the one a friend shared. Margins a friend shares by link for it will then land on this file.")
            }
            .alert(
                shareExplanation?.title ?? "",
                isPresented: Binding(get: { shareExplanation != nil }, set: { if !$0 { shareExplanation = nil } }),
                presenting: shareExplanation
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { explanation in
                Text(explanation.message)
            }
            .alert("Move to Recently Deleted?", isPresented: $confirmsTrash) {
                Button("Cancel", role: .cancel) {}
                Button("Move to Recently Deleted", role: .destructive) {
                    model.moveItemToTrash(id: model.selectedItem.id)
                }
            } message: {
                Text("\(model.selectedItem.title) can be restored from Settings.")
            }
            .confirmationDialog("Start a separate listening session?", isPresented: $confirmsNewSession) {
                Button("Start New Session") { model.startNewSession(id: model.selectedItem.id) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your existing listening position and Margins remain in their current session.")
            }
            .newMarginsOffer($pendingNewMarginsOffer)
            .miniPlayerKeepOut()
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.selectedItem.title)
                .font(.title.weight(.bold))
                .screenTitle()
                .foregroundStyle(AppColors.text)
                .fixedSize(horizontal: false, vertical: true)
            // A meeting transcript's start, length and speakers (#2997). Read in `ItemDetailLoader`, off the main actor.
            if let meetingLine = model.selectedItem.meetingLine {
                Text(meetingLine)
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("item.meetingLine")
            }
            if let published = model.selectedItem.publishedDateText {
                Text("Published \(published)")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("item.publishedDate")
            }
            if let added = model.selectedItem.addedDateText {
                Text("Added \(added)")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryText)
                    .accessibilityIdentifier("item.addedDate")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { metadataPills }
                VStack(alignment: .leading, spacing: 7) { metadataPills }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func refreshEpisodeLinkStatus() async {
        let itemId = model.selectedItem.id
        guard let store = model.store, !itemId.isEmpty else {
            episodeLinkStatus = ImportedFileEpisodeLinker.Status()
            return
        }
        let read = await episodeLinker.status(itemId: itemId, store: store)
        // The listener may have moved to another item while the read ran; that item's own refresh sets its status.
        guard let status = read, !Task.isCancelled, model.selectedItem.id == itemId else { return }
        episodeLinkStatus = status
    }

    /// The header's Share and the menu's Share Margins (#4229): the friend sheet when there are Margins to send, otherwise
    /// an alert that says why. A second tap while the check runs or the sheet is up does nothing.
    private func share() {
        guard !checksShare, !model.isSharingInterjectionsPresented else { return }
        checksShare = true
        let itemId = model.selectedItem.id
        Task {
            defer { checksShare = false }
            let start = await model.itemShareStart()
            // The re-read can take a moment; if the listener has gone to another item, Share is for the one they tapped on.
            guard model.selectedItem.id == itemId else { return }
            switch start {
            // The sheet's store reads run on this task; label them for the hang probe (#4229).
            case .share: model.hangTelemetry.labels.scoped("itemShare") { model.openItemShareSheet() }
            case .nothingYet(let explanation): shareExplanation = explanation
            }
        }
    }

    private func linkEpisode() {
        guard let store = model.store, !isChangingEpisodeLink else { return }
        let itemId = model.selectedItem.id
        let pasted = episodeLinkText
        isChangingEpisodeLink = true
        Task { @MainActor in
            defer { isChangingEpisodeLink = false }
            do {
                let title = try await episodeLinker.link(itemId: itemId, to: pasted, store: store)
                await refreshEpisodeLinkStatus()
                model.hangTelemetry.labels.scoped("episodeLinked") {
                    model.refreshSpokenMarginsPackageImportAfterAddingSource()
                    model.reportConfirmation("Linked to \u{201C}\(title)\u{201D}. Margins a friend shares by link for it will land on this file.")
                }
            } catch {
                model.reportFailure(error, itemId: itemId)
            }
        }
    }

    private func unlinkEpisode() {
        guard let store = model.store, !isChangingEpisodeLink else { return }
        let itemId = model.selectedItem.id
        isChangingEpisodeLink = true
        Task { @MainActor in
            defer { isChangingEpisodeLink = false }
            do {
                try await episodeLinker.unlink(itemId: itemId, store: store)
                await refreshEpisodeLinkStatus()
                model.reportConfirmation("Episode unlinked. The file and its Margins are unchanged.")
            } catch {
                model.reportFailure(error, itemId: itemId)
            }
        }
    }

    @ViewBuilder
    private var metadataPills: some View {
        // The item's total length, first (#4186): the same words the Library row uses, always the total, never the time left.
        if let length = lengthPillWords {
            metadataPill(length.visible, systemImage: "clock", accessibilityLabel: length.spoken)
        }
        if let episodeTitle = episodeLinkStatus.episodeTitle {
            metadataPill("Episode: \(episodeTitle)", systemImage: "link")
        }
        if chapterCount > 0 {
            metadataPill("\(chapterCount) chapter\(chapterCount == 1 ? "" : "s")", systemImage: "list.bullet")
        }
        if !model.selectedItem.listeningMapScenes.isEmpty {
            let count = model.selectedItem.listeningMapScenes.count
            metadataPill(
                "\(count) map scene\(count == 1 ? "" : "s")",
                systemImage: "map"
            )
        }
        // Only while a friend's intro shows does it count the Margins itself (#3788); otherwise the listener's count stays.
        if !model.selectedItem.interjections.isEmpty, FriendMarginsIntro(unheardFriendMargins: newSharedMargins.map(\.waitingMargin)) == nil {
            let count = model.selectedItem.interjections.count
            metadataPill("\(count) Margin\(count == 1 ? "" : "s")", systemImage: "quote.bubble")
        }
        if let tableCount = model.selectedItem.documentStructure?.tables.count,
           tableCount > 0 {
            metadataPill(
                "\(tableCount) table\(tableCount == 1 ? "" : "s") skipped",
                systemImage: "tablecells"
            )
        }
    }

    /// Nil for a meeting transcript (its meeting line gives the length) and for text with no character count.
    private var lengthPillWords: (visible: String, spoken: String)? {
        let item = model.selectedItem
        return ItemLengthWords.pill(
            isNativeAudio: item.isNativeAudio,
            isMeetingTranscript: item.externalReferenceType == TranscriptItemText.referenceType,
            textCharacterCount: item.lengthTextCharacterCount,
            lengthMs: item.lengthMs,
            playbackSpeed: model.speechPlaybackRateMultiplier
        )
    }

    private var chapterCount: Int {
        model.selectedItem.chapters.isEmpty
            ? model.selectedItem.mediaChapters.count
            : model.selectedItem.chapters.count
    }

    /// The Library row's Mark Complete, Add to Collection and Prepare Offline, as visible menu entries (#1973).
    /// They call what the row's swipe and long-press call. The row is the Library's, so an item the Library
    /// doesn't list gets none.
    @ViewBuilder private var quickActionButtons: some View {
        if let row = model.libraryItems.first(where: { $0.id == model.selectedItem.id }) {
            ForEach(ItemQuickAction.actions(for: row), id: \.self) { action in
                switch action {
                case .markComplete:
                    Button("Mark Complete", systemImage: "checkmark.circle") { model.markItemCompleted(id: row.id) }
                        .accessibilityIdentifier("item.markComplete.button")
                case .markUnfinished:
                    Button("Mark Not Complete", systemImage: "arrow.uturn.backward.circle") { model.markItemUnfinished(id: row.id) }
                        .accessibilityIdentifier("item.markUnfinished.button")
                case .markMarginsHeard:
                    Button("Mark Margins Heard", systemImage: "checkmark.bubble") { model.markItemMarginsHeard(id: row.id) }
                        .accessibilityIdentifier("item.markMarginsHeard.button")
                case .playNext:
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.queuePlayNext(itemId: row.id) }
                        .accessibilityIdentifier("item.playNext.button")
                case .addToQueue:
                    Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { model.queueAppend(itemId: row.id) }
                        .accessibilityIdentifier("item.addToQueue.button")
                case .addToCollection:
                    Button("Add to Collection…", systemImage: "folder.badge.plus") { collectionItem = row }
                        .accessibilityIdentifier("item.addToCollection.button")
                case .prepareOffline:
                    Button("Prepare Offline", systemImage: "arrow.down.circle") { model.prioritizeOfflinePreparation(id: row.id) }
                        .accessibilityIdentifier("item.prepareOffline.button")
                }
            }
        }
    }

    /// Mark Complete where the listener is already looking, not only in the options menu (#2393). The same
    /// action and undo the Library swipe uses; an item that finished by listening shows nothing.
    @ViewBuilder private var completionControl: some View {
        if let row = model.libraryItems.first(where: { $0.id == model.selectedItem.id }),
           let action = ItemQuickAction.completionAction(for: row) {
            Button {
                switch action {
                case .markComplete: model.markItemCompleted(id: row.id)
                case .markMarginsHeard: model.markItemMarginsHeard(id: row.id)
                default: model.markItemUnfinished(id: row.id)
                }
            } label: {
                Label(
                    action == .markComplete ? "Mark complete" : action == .markMarginsHeard ? "Mark Margins heard" : "Mark not complete",
                    systemImage: action == .markComplete ? "checkmark.circle" : action == .markMarginsHeard ? "checkmark.bubble" : "arrow.uturn.backward.circle"
                )
                .frame(maxWidth: .infinity, minHeight: 40)
                .expandedHitArea(vertical: 2)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .accessibilityIdentifier(
                action == .markComplete ? "item.markCompleteVisible.button"
                    : action == .markMarginsHeard ? "item.markMarginsHeardVisible.button" : "item.markUnfinishedVisible.button")
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if model.selectedItemPreferredContinuationSession != nil || hasItemMargins {
            // Read once per render: the choices look through the item's Margins, and ViewThatFits builds its content twice.
            let quietMarginsLink = listeningChoices.marginsOnlyTitle != nil
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { secondaryActionButtons(quietMarginsLink: quietMarginsLink) }
                VStack(alignment: .leading, spacing: 8) { secondaryActionButtons(quietMarginsLink: quietMarginsLink) }
            }
        }
    }

    /// "Where people reacted" (#476): offered once the item has Margins from two or more people.
    @ViewBuilder
    private var reactionsEntry: some View {
        let item = model.selectedItem
        if MarginLayerSynthesis.offersReactions(
            itemId: item.id,
            layers: item.importedCommentaryLayers,
            interjections: item.importedCommentaryInterjections,
            ownMargins: model.ownMargins(itemId: item.id)
        ) {
            Button {
                showsReactions = true
            } label: {
                Label("Where people reacted", systemImage: "person.2.fill")
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .expandedHitArea(vertical: 2)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .accessibilityIdentifier("item.reactions.button")
        }
    }

    @ViewBuilder
    private var primaryPlaybackAction: some View {
        if [.waiting, .preparing].contains(model.selectedItemStartupAudioState) {
            HStack(spacing: 10) {
                if model.selectedItemStartupAudioState == .preparing {
                    ProgressView()
                        .tint(AppColors.evergreen)
                }
                Text(model.selectedItemStartupAudioProgressDescription)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(AppColors.secondaryText)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.selectedItemStartupAudioProgressDescription)
            .accessibilityIdentifier("item.start.preparing")
        }
        let choices = listeningChoices
        // While the friend's intro shows, a tap that can't start yet is kept (#3788). Otherwise the buttons act as before.
        let holdsEarlyTap = FriendMarginsIntro(unheardFriendMargins: newSharedMargins.map(\.waitingMargin)) != nil
        if let line = arrival.line {
            Text(line)
                .font(.subheadline)
                .foregroundStyle(AppColors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("item.arrival.waitingLine")
        }
        Button {
            tapped(.play, holdsEarlyTap: holdsEarlyTap)
        } label: {
            Label(choices.primaryTitle, systemImage: "play.fill")
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .filledActionButton()
        .accessibilityLabel(choices.primaryAccessibilityLabel ?? choices.primaryTitle)
        .accessibilityIdentifier("item.start.button")
        if let secondaryTitle = choices.secondaryTitle, let secondaryAction = choices.secondaryAction {
            Button {
                // Only "Skip to …" waits on a Margin's audio; "Listen without them" and "Play from the start" need none.
            tapped(.skip, holdsEarlyTap: holdsEarlyTap && secondaryAction == .reviewNewMargins(thenContinue: false))
            } label: {
                // Words only, as on the screens the owner reviewed (#3247): the line already says whose Margins.
                Text(secondaryTitle)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .accessibilityLabel(choices.secondaryAccessibilityLabel ?? secondaryTitle)
            .accessibilityIdentifier(secondaryAction == .reviewNewMargins(thenContinue: false) ? "item.reviewNewMargins.button" : "item.listenWithout.button")
        }
    }

    /// A tap on a pinned button. With the friend's intro showing it goes through the keeper, which runs it now or keeps it
    /// until it can start (#3788); the rest of the time it runs as it always did.
    private func tapped(_ choice: FriendArrivalStart.Choice, holdsEarlyTap: Bool) {
        guard holdsEarlyTap else { return start(choice) }
        arrival.tap(choice, model: model) { start($0) }
    }

    /// Plays or skips to the Margins, as the buttons are labelled now.
    private func start(_ choice: FriendArrivalStart.Choice) {
        let choices = listeningChoices
        let behind = marginsBehindPlace
        switch choice {
        case .play: perform(choices.primaryAction, behind: behind)
        case .skip: if let action = choices.secondaryAction { perform(action, behind: behind) }
        }
    }

    /// What a pinned button does. The choice is `ItemListeningChoices`'s; this only calls the model (#4125).
    private func perform(_ action: ItemListeningChoices.Action, behind: [SharedMarginReview.Entry]) {
        let itemId = model.selectedItem.id
        switch action {
        case .play:
            // Friend Margins ahead of the place play in place as the episode reaches them (#3219).
            model.continueListening(itemId: itemId, surface: .itemScreen) { pendingNewMarginsOffer = $0 }
        case .reviewNewMargins(let thenContinue):
            // In catch-up the big button plays only what is new and pauses after it (#4785).
            model.reviewNewMargins(
                itemId: itemId, thenContinue: thenContinue, entries: thenContinue ? behind : nil, catchUp: catchUp != nil)
        case .continueWithout:
            model.continueWithoutNewMargins(NewMarginsOfferRequest(itemId: itemId, entries: behind))
        case .startFromBeginning:
            model.startItemFromBeginning(itemId: itemId, entries: behind)
        }
    }

    private var marginsBehindPlace: [SharedMarginReview.Entry] {
        model.itemScreenMarginsBehindSavedPlace(itemId: model.selectedItem.id)
    }

    /// The start controls for this item: today's single button, or the two choices when a friend's Margins wait (#3219).
    private var listeningChoices: ItemListeningChoices {
        let catchUp = catchUp
        return ItemListeningChoices(
            unheardFriendMargins: newSharedMargins.map(\.waitingMargin),
            marginsBehindPlace: marginsBehindPlace.map(\.waitingMargin),
            placeIsAtEnd: model.selectedItemSavedPlaceIsAtEnd(),
            hasFinishedSession: hasFinishedSession,
            hasContinuationSession: model.selectedItemPreferredContinuationSession != nil,
            isPreparingAudio: [.waiting, .preparing].contains(model.selectedItemStartupAudioState),
            catchUp: catchUp,
            resumesShortOfEnd: catchUp != nil && model.selectedItemCatchUpResumesARelisten(),
            ownParentDurationsMs: catchUp.map { model.catchUpOwnParentLengthsMs($0) } ?? []
        )
    }

    /// Catch-up (#4785): the item is finished (the Library row's `isCompleted`, which is `ItemFinishedRule.isFinished`)
    /// and a new Margin answers one of the listener's own. Built from the same list as the intro's "Replies from" line,
    /// so the two can never disagree, with no read of its own.
    private var catchUp: ConversationCatchUp? {
        let finished = model.libraryItems.first(where: { $0.id == model.selectedItem.id })?.isCompleted ?? false
        return ConversationCatchUp.make(isFinished: finished, waiting: newSharedMargins.map(\.waitingMargin))
    }

    @ViewBuilder
    private func secondaryActionButtons(quietMarginsLink: Bool) -> some View {
        if model.selectedItemPreferredContinuationSession != nil {
            Button {
                confirmsNewSession = true
            } label: {
                Label("Start over", systemImage: "plus.circle")
                    .frame(minHeight: 40)
                    .expandedHitArea(vertical: 2)
            }
            .buttonStyle(.bordered)
            .tint(AppColors.evergreen)
            .accessibilityHint("Begins a separate pass. Your current place and Margins stay where they are.")
            .accessibilityIdentifier("item.startNew.button")
        }

        if hasItemMargins {
            Button {
                model.marginCollectionQuery = MarginCollectionQuery(itemID: model.selectedItem.id)
                model.openMargins()
            } label: {
                Label("Review Margins", systemImage: "quote.bubble")
                    .frame(minHeight: 40)
                    .expandedHitArea(vertical: 2)
            }
            // Beside the two start choices it is a quiet link, not a third peer button (#3219). Quiet means no fill,
            // not grey: grey text on a grey fill is how iOS draws a disabled button (#3854).
            .modifier(MarginsLinkStyleModifier(style: ItemMarginsLinkStyle.style(quiet: quietMarginsLink)))
            .accessibilityIdentifier("item.reviewMargins.button")
        }
    }

    private var hasFinishedSession: Bool {
        guard let session = model.selectedItemPreferredContinuationSession else { return false }
        return !SessionContinuation.continueResumes(session)
    }

    private var overview: some View {
        ExperienceSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text("Overview")
                    .font(.system(.title3, design: .serif).weight(.bold))
                Text(model.selectedItem.overview)
                    .font(.body)
                    .foregroundStyle(AppColors.secondaryText)
                    .lineSpacing(3)
            }
        }
    }

    private var structure: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Chapters", detail: "The chapters and headings in the source itself")
            if !model.selectedItem.navigation.isEmpty {
                ExperienceSurface {
                    ExperienceCanonicalNavigationTree(
                        nodes: model.selectedItem.navigation,
                        chapters: model.selectedItem.chapters,
                        action: { model.jumpToChapter($0) }
                    )
                }
            } else if !model.selectedItem.chapters.isEmpty {
                ExperienceSurface {
                    VStack(spacing: 0) {
                        ForEach(Array(model.selectedItem.chapters.enumerated()), id: \.element.id) { index, chapter in
                            if index > 0 { Divider() }
                            Button { model.jumpToChapter(chapter) } label: {
                                GutterRow(gutterWidth: 42, spacing: 8) {
                                    Text("\(chapter.percent)%")
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(AppColors.evergreen)
                                } content: {
                                    HStack {
                                        Text(chapter.title)
                                            .font(.headline)
                                            .foregroundStyle(AppColors.text)
                                        Spacer()
                                        Image(systemName: "play.fill")
                                            .foregroundStyle(AppColors.evergreen)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(minHeight: 52)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("chapter.jump.\(chapter.id)")
                        }
                    }
                }
            } else if !model.selectedItem.mediaChapters.isEmpty {
                ExperienceSurface {
                    VStack(spacing: 0) {
                        ForEach(Array(model.selectedItem.mediaChapters.sorted { $0.startMs < $1.startMs }.enumerated()), id: \.element.id) { index, chapter in
                            if index > 0 { Divider() }
                            Button { model.jumpToMediaChapter(chapter) } label: {
                                GutterRow(gutterWidth: 52, alignment: .center, spacing: 12) {
                                    Text(formatPlaybackTime(chapter.startMs))
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(AppColors.evergreen)
                                } content: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(chapter.title)
                                                .font(.headline)
                                                .foregroundStyle(AppColors.text)
                                                .multilineTextAlignment(.leading)
                                            if let description = chapter.description, !description.isEmpty {
                                                Text(description)
                                                    .font(.caption)
                                                    .foregroundStyle(AppColors.secondaryText)
                                                    .lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "play.fill")
                                            .foregroundStyle(AppColors.evergreen)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(minHeight: 52)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("mediaChapter.jump.\(chapter.id)")
                        }
                    }
                }
            } else {
                ExperienceSurface {
                    Label("No chapters in this source", systemImage: "doc.text")
                        .font(.headline)
                    Text("You can listen from the beginning. A Listening Map, if you want one, is under Advanced.")
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var listeningMap: some View {
        ExperienceListeningMapSection(
            scenes: model.selectedItem.listeningMapScenes,
            isCommunityMap: model.selectedItem.listeningMapIsCommunity,
            model: model
        )
            .equatable()
    }

    /// A Margin with a place opens in the Timeline at that place; one with no place opens its details (#4233).
    private func openRecentMargin(_ row: MarginRow) {
        switch MarginRowTap.action(for: row.interjection) {
        case .playMoment: model.openMarginInTimeline(row)
        case .openDetails: unplacedMargin = row
        }
    }

    @ViewBuilder
    private var recentMargins: some View {
        if !model.selectedItem.interjections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading("Recent Margins", detail: "Your thoughts on this \(model.selectedItem.sourceNoun.inSentence)")
                ExperienceSurface(tint: AppColors.coral.opacity(0.34)) {
                    VStack(spacing: 0) {
                        ForEach(Array(itemMargins.prefix(3).enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            // A live-session photo sits on the right at standard sizes and under the words at
                            // accessibility sizes, so the words keep the row's width (#4180). No photo, no slot.
                            let photo = photoIndex.photo(forMarginId: row.interjection.id)
                            Button { openRecentMargin(row) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "quote.bubble.fill")
                                        .foregroundStyle(AppColors.coral)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.preview)
                                            .font(.headline)
                                            .foregroundStyle(AppColors.text)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(2)
                                        Text(MarginPlacePresentation.itemScreenLine(for: row.interjection))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(AppColors.secondaryText)
                                        if let photo, dynamicTypeSize.isAccessibilitySize {
                                            LiveSessionPhotoThumbnail(source: .kept(photo.photo), surface: .page)
                                        }
                                    }
                                    Spacer()
                                    if let photo, !dynamicTypeSize.isAccessibilitySize {
                                        LiveSessionPhotoThumbnail(source: .kept(photo.photo), surface: .page)
                                    }
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(AppColors.secondaryText)
                                        .accessibilityHidden(true)
                                }
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .modifier(OptionalAccessibilityValue(
                                value: photo == nil ? nil : LiveSessionPhotoMargin.rowAccessibilityValue
                            ))
                        }
                    }
                }
            }
        }
    }

    /// "Open Original Source" and "Open in Readwise" side by side above Advanced, one under the other
    /// when they don't fit (narrow phones, large text).
    private var itemLinks: some View {
        ItemLinksRow(
            sync: model.readwiseHighlightSync,
            itemId: model.selectedItem.id,
            originalSource: model.selectedItem.originalSourceURL
        )
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Listening sessions", detail: "Each one keeps its own place and Margins")
            if model.selectedItem.sessionRows.isEmpty {
                ExperienceSurface { Text("No sessions yet.").foregroundStyle(AppColors.secondaryText) }
            } else {
                ExperienceSurface {
                    VStack(spacing: 0) {
                        ForEach(Array(model.selectedItem.sessionRows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            HStack(spacing: 12) {
                                Button { model.openSession(row.session) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(sessionTitle(row.session, index: index))
                                            .font(.headline)
                                            .foregroundStyle(AppColors.text)
                                        Text("\(row.session.completionPercent)% · \(row.interjectionCount) Margin\(row.interjectionCount == 1 ? "" : "s")")
                                            .font(.subheadline.monospacedDigit())
                                            .foregroundStyle(AppColors.secondaryText)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("session.inspect.\(row.session.id)")
                                Button { model.resumeSession(row.session) } label: {
                                    Image(systemName: "play.fill").frame(width: 44, height: 44)
                                }
                                .buttonStyle(.bordered)
                                .accessibilityLabel(RowAccessibilityLabel.label("Resume this session", row: sessionTitle(row.session, index: index), "\(row.session.completionPercent)%"))
                                .accessibilityIdentifier("session.resume.\(row.session.id)")
                                Button { model.openExport(sessionId: row.session.id) } label: {
                                    Image(systemName: "doc.text").frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(RowAccessibilityLabel.label("Export this session", row: sessionTitle(row.session, index: index), "\(row.session.completionPercent)%"))
                                .accessibilityIdentifier("session.export.\(row.session.id)")
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var downloadRecovery: some View {
        switch model.selectedPodcastDownloadState {
        case .waitingForWiFi, .streamingOnly, .failed, .evicted, .downloading:
            // The status beside its button, or one above the other when they don't fit (large text, #1938).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    downloadStatusLabel
                    Spacer(minLength: 8)
                    downloadRecoveryControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    downloadStatusLabel
                    downloadRecoveryControl
                }
            }
            .accessibilityIdentifier("item.podcastDownload.status")
        case .availableOffline:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    downloadStatusLabel
                        .accessibilityIdentifier("item.podcastDownload.saved")
                    Spacer(minLength: 8)
                    Button("Download Again", action: model.redownloadSelectedPodcast)
                        .buttonStyle(.bordered)
                }
                VStack(alignment: .leading, spacing: 8) {
                    downloadStatusLabel
                        .accessibilityIdentifier("item.podcastDownload.saved")
                    Button("Download Again", action: model.redownloadSelectedPodcast)
                        .buttonStyle(.bordered)
                }
            }
        case .none:
            EmptyView()
        }
    }

    private var downloadStatusLabel: some View {
        Label(readinessLabel, systemImage: readinessIcon)
            .font(.subheadline)
            .foregroundStyle(readinessColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var downloadRecoveryControl: some View {
        switch model.selectedPodcastDownloadState {
        case .waitingForWiFi, .streamingOnly:
            Button("Download Now", action: model.downloadSelectedPodcastNow)
                .buttonStyle(.bordered)
                .tint(AppColors.evergreen)
        case .failed, .evicted:
            Button("Retry Download", action: model.retrySelectedPodcastDownload)
                .buttonStyle(.bordered)
                .tint(AppColors.evergreen)
        case .downloading:
            if let progress = model.selectedPodcastDownloadProgress {
                ProgressView(value: progress)
                    .tint(readinessColor)
                    .frame(width: 72)
                    .accessibilityLabel("Download progress")
            } else {
                ProgressView()
                    .accessibilityLabel("Downloading")
                    .tint(readinessColor)
            }
        case .availableOffline, .none:
            EmptyView()
        }
    }

    private var advanced: some View {
        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                if !model.selectedItem.externalReference.isEmpty {
                    LabeledContent("Source reference") {
                        Text(model.selectedItem.externalReference)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .textSelection(.enabled)
                    }
                    .accessibilityIdentifier("item.externalReference")
                }
                if let reason = model.sharedListeningMapRefusal(itemId: model.selectedItem.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        FailureMessageLabel("A shared map couldn't be placed on your copy")
                            .font(.subheadline.weight(.semibold))
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("item.sharedMap.refusal")
                }
                if model.canGenerateListeningMap {
                    Button(model.episodeMapPreparationStatus == "Preparing" ? "Preparing Listening Map…" : "Prepare Listening Map", systemImage: "sparkles") {
                        model.startPublicSourceCheck(itemId: model.activeItemId) // the tap itself, not the shared function a finished transcript also calls (#3449)
                        model.generateListeningMapFromTap()
                    }
                    .disabled(model.isGeneratingListeningMap || model.episodeMapPreparationStatus == "Preparing")
                    .accessibilityIdentifier("item.generateMap.button")
                    if model.episodeMapPreparationStatus != "Not started" {
                        Text(model.episodeMapPreparationStatus)
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("item.episodeMap.status")
                    }
                } else if model.selectedItem.textSceneSummaries.offersRun, !model.selectedItem.chapters.isEmpty {
                    sceneSummariesControl
                } else {
                    Text(model.listeningMapGenerationAvailabilityDescription)
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
            }
            .padding(.top, 12)
        }
        .font(.headline)
        .padding(16)
        .background(AppColors.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(AppColors.border) }
    }

    /// An article or PDF that has chapters but not all of its scene summaries: write them, or pick up where a run that
    /// failed, was cancelled or paused stopped (#3461). The scenes already written are kept.
    private var sceneSummariesControl: some View {
        let state = model.selectedItem.textSceneSummaries
        let writing = model.isWritingSceneSummaries
        return VStack(alignment: .leading, spacing: 6) {
            Button(writing ? "Writing Scene Summaries…" : (state == .notStarted ? "Write Scene Summaries" : "Continue Scene Summaries"),
                   systemImage: "sparkles") {
                model.writeSceneSummaries()
            }
            .disabled(writing)
            .accessibilityIdentifier("item.writeSceneSummaries.button")
            Text(sceneSummariesCaption(state))
                .font(.caption)
                .foregroundStyle(AppColors.secondaryText)
                .accessibilityIdentifier("item.writeSceneSummaries.caption")
        }
    }

    private func sceneSummariesCaption(_ state: TextSceneSummaryProgress.State) -> String {
        switch state {
        case .partial(let decided, let total):
            return "\(decided) of \(total) scenes are done. Scenes already written are kept, and nothing leaves this device."
        default:
            return "The on-device model writes a short summary for each scene, for Skim. Nothing leaves this device."
        }
    }

    /// `!itemMargins.isEmpty` without building and sorting the rows, for the checks `body` makes on every render.
    private var hasItemMargins: Bool {
        model.selectedItem.interjections.contains { $0.status == "active" }
    }

    /// Shared Margins on this item that the listener hasn't heard (#474).
    private var newSharedMargins: [SharedMarginReview.Entry] {
        model.newSharedMargins(itemId: model.selectedItem.id)
    }

    private var itemMargins: [MarginRow] {
        model.selectedItem.interjections
            .filter { $0.status == "active" }
            .sorted { $0.createdAt > $1.createdAt }
            .map { MarginRow(interjection: $0, itemTitle: model.selectedItem.title, sessionDate: nil) }
    }

    private var readinessLabel: String {
        switch model.selectedPodcastDownloadState {
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .streamingOnly: "Streaming available"
        case .failed, .evicted: "Download needs attention"
        case .downloading: model.selectedPodcastDownloadStatusText ?? "Downloading"
        case .availableOffline: model.selectedPodcastDownloadStatusText ?? "Available offline"
        case .none: ""
        }
    }

    private var readinessIcon: String {
        switch model.selectedPodcastDownloadState {
        case .availableOffline: "arrow.down.circle.fill"
        case .failed, .evicted: "exclamationmark.arrow.circlepath"
        case .downloading: "arrow.down.circle.dotted"
        case .waitingForWiFi: "wifi.exclamationmark"
        case .streamingOnly, .none: "play.circle"
        }
    }

    private var readinessColor: Color {
        switch model.selectedPodcastDownloadState {
        case .failed, .evicted: AppColors.coral
        case .downloading, .waitingForWiFi: AppColors.ochreText
        case .availableOffline, .streamingOnly, .none: AppColors.evergreen
        }
    }

    private func metadataPill(_ text: String, systemImage: String, accessibilityLabel: String? = nil) -> some View {
        Label(text, systemImage: systemImage)
            .accessibilityLabel(accessibilityLabel ?? text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.secondaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(AppColors.panel, in: Capsule())
    }

    private func formatPlaybackTime(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.title3, design: .serif).weight(.bold)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.caption).foregroundStyle(AppColors.secondaryText)
        }
    }

    private func sessionTitle(_ session: Session, index: Int) -> String {
        let marker = index == 0 ? "Most recent" : "Earlier session"
        guard let date = session.updatedAt ?? session.createdAt else { return marker }
        return "\(marker) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

}

// Playback publishes frequent model updates. The scene section depends only on
// its value inputs; keep those updates from rebuilding every summary row.
private struct ExperienceListeningMapSection: View, Equatable {
    let scenes: [MediaTimelineChapter]
    let isCommunityMap: Bool
    let model: Gate1AppModel

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scenes == rhs.scenes && lhs.isCommunityMap == rhs.isCommunityMap && lhs.model === rhs.model
    }

    var body: some View {
        // Plain stacks: nothing on the item screen is lazy (#3781).
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                isCommunityMap ? "Community map" : "Listening Map",
                detail: isCommunityMap
                    ? "Made from other listeners' transcripts. Scene navigation and Skim summaries."
                    : "Scene navigation and Skim summaries"
            )
            .accessibilityIdentifier(isCommunityMap ? "listeningMap.heading.community" : "listeningMap.heading")
            ExperienceSurface(tint: AppColors.evergreen.opacity(0.18)) {
                VStack(spacing: 0) {
                    ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                        VStack(spacing: 0) {
                            if index > 0 { Divider() }
                            Button { model.jumpToListeningMapScene(scene) } label: {
                                GutterRow(gutterWidth: 52, alignment: .center, spacing: 12) {
                                    Text(formatPlaybackTime(scene.startMs))
                                        .font(.caption.monospacedDigit().weight(.bold))
                                        .foregroundStyle(AppColors.evergreen)
                                } content: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(scene.title)
                                                .font(.headline)
                                                .foregroundStyle(AppColors.text)
                                                .multilineTextAlignment(.leading)
                                            if let description = scene.description, !description.isEmpty {
                                                Text(description)
                                                    .font(.caption)
                                                    .foregroundStyle(AppColors.secondaryText)
                                                    .lineLimit(3)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "play.fill")
                                            .foregroundStyle(AppColors.evergreen)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .frame(minHeight: 52)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("listeningMap.scene.jump.\(scene.id)")
                        }
                    }
                }
            }
        }
    }

    private func formatPlaybackTime(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1_000)
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(.title3, design: .serif).weight(.bold)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.caption).foregroundStyle(AppColors.secondaryText)
        }
    }

}

/// The links off the Item screen: the original page (#1167), and Readwise once this item's Margins
/// have been sent there (#623). Nothing here fetches anything; the system browser opens the address.
private struct ItemLinksRow: View {
    @ObservedObject var sync: ReadwiseHighlightSync
    let itemId: String
    let originalSource: URL?

    var body: some View {
        let readwise = sync.links[itemId]
        if originalSource != nil || readwise != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { links(readwise: readwise) }
                VStack(alignment: .leading, spacing: 0) { links(readwise: readwise) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func links(readwise: URL?) -> some View {
        if let originalSource {
            Link(destination: originalSource) {
                // The height is inside the label so the whole 44 pt row takes the tap, not only the text.
                Label("Open Original Source", systemImage: "safari")
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("item.originalSource.link")
        }
        if let readwise {
            Link(destination: readwise) {
                // The height is inside the label so the whole 44 pt row takes the tap, not only the text.
                Label("Open in Readwise", systemImage: "arrow.up.right.square")
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("item.readwise.link")
        }
    }
}

/// "Review Margins" drawn as `ItemMarginsLinkStyle` says: an evergreen outline capsule with no fill, or the bordered
/// evergreen button (#3854). The outline is at least 44 pt tall, and its stroke is a shape cue as well as a colour.
private struct MarginsLinkStyleModifier: ViewModifier {
    let style: ItemMarginsLinkStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .outline:
            content
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.evergreen)
                .padding(.horizontal, 16)
                .frame(minHeight: TapTarget.minimum)
                .overlay { Capsule().stroke(AppColors.evergreen, lineWidth: 1) }
                .contentShape(Capsule())
        case .bordered:
            content
                .buttonStyle(.bordered)
                .tint(AppColors.evergreen)
        }
    }
}
