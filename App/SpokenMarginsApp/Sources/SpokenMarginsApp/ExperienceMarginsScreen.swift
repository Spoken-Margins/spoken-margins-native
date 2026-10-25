import SwiftUI
import SessionKit
import SessionKitPersistence

struct ExperienceMarginsScreen: View {
    private struct MarginGroup: Identifiable {
        let itemID: String
        let itemTitle: String
        let rows: [MarginRow]

        var id: String { itemID }


    }

    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedMargin: MarginRow?
    @State private var selectedSharedMargin: SharedMarginRow?
    @State private var markdownFileURL: URL?
    @State private var collections: [ItemCollection] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    MarginsSearchField(text: $model.marginCollectionQuery.text)
                        .padding(.bottom, 12)
                    scopeRow
                    filterBar
                        .padding(.bottom, 8)
                    if model.marginCollectionQuery.filter == .shared { sharedCollection } else { collection }
                }
                .padding(.horizontal, horizontalSizeClass == .regular ? 28 : 16)
                .padding(.vertical, 12)
                .frame(maxWidth: horizontalSizeClass == .regular ? 920 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.bone)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("margins.screen")
            .fileShareSheet($markdownFileURL)
            .navigationTitle("Margins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export Sessions", systemImage: "square.and.arrow.up.on.square", action: openBatchExport)
                        .accessibilityIdentifier("margins.export.button")
                }
            }
            .task {
                model.refreshMarginRows()
                loadCollections()
            }
            .refreshable { model.refreshMarginRows() }
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $selectedMargin) { row in
                ExperienceMarginDetailView(row: row).environmentObject(model)
            }
            .sheet(item: $selectedSharedMargin) { row in
                SharedMarginDetailView(row: row).environmentObject(model)
            }
            .miniPlayerKeepOut()
        }
    }

    private var scopeRow: some View {
        MarginsScopeRow(
            title: scopeTitle,
            countText: "\(model.marginCollectionQuery.filter == .shared ? model.visibleSharedMarginRows.count : filteredRows.count) Margins",
            selection: scopeTag,
            collections: collections,
            items: model.marginScopeItems
        )
    }

    /// What the scope control reads: the collection, the item, or all items.
    private var scopeTitle: String {
        let query = model.marginCollectionQuery
        if let scope = query.collection {
            return collections.first { $0.id == scope.collectionID }?.name ?? "Collection"
        }
        if let itemID = query.itemID {
            return model.marginScopeItems.first { $0.id == itemID }?.title ?? "Item"
        }
        return "All items"
    }

    /// The scope picker's choice: one item, one collection (#490) or all items.
    private var scopeTag: Binding<String?> {
        Binding(
            get: { model.marginCollectionQuery.scopeTag },
            set: { model.marginCollectionQuery.selectScope(tag: $0, collections: collections) }
        )
    }

    private func loadCollections() {
        guard let stored = try? model.store?.loadItemCollections() else { return }
        collections = stored
        model.marginCollectionQuery.refreshCollection(from: stored)
    }

    /// Export Sessions starts with only the scoped collection's sessions selected.
    private func openBatchExport() {
        model.openBatchExport(scopedTo: model.marginCollectionQuery.collection)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MarginCollectionFilter.allCases.filter { $0 != .attention }, id: \.self) { option in
                    Button { model.marginCollectionQuery.filter = option } label: {
                        ExperienceFilterChip(isActive: model.marginCollectionQuery.filter == option) { Text(option.title) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("margins.filter.\(option.rawValue)")
                }
            }
        }
    }

    /// The item heading, then Share and Share as Markdown. At accessibility sizes the buttons take their own
    /// row under the title instead of squeezing it (#1938).
    @ViewBuilder
    private func groupHeading(_ group: MarginGroup) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 0) {
                groupOpenItemButton(group)
                HStack(spacing: 8) {
                    groupShareButtons(group)
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(alignment: .top) {
                groupOpenItemButton(group)
                Spacer(minLength: 8)
                groupShareButtons(group)
            }
        }
    }

    @ViewBuilder
    private func groupOpenItemButton(_ group: MarginGroup) -> some View {
        // The heading opens the item, as the Library row does (#1256). The chevron says it goes somewhere.
        Button { model.openItem(id: group.itemID) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(group.itemTitle) \(Text(Image(systemName: "chevron.right")).font(.caption.weight(.bold)).foregroundStyle(AppColors.secondaryText))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(group.rows.count) Margins")
                    .font(.caption)
                    .foregroundStyle(AppColors.secondaryText)
            }
            .frame(minHeight: 44, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.itemTitle), \(group.rows.count) Margins")
        .accessibilityHint("Opens the item.")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("margins.openItem.\(group.itemID)")
    }

    @ViewBuilder
    private func groupShareButtons(_ group: MarginGroup) -> some View {
        Button { model.openMarginItemExport(itemID: group.itemID) } label: {
            Label("Share", systemImage: "square.and.arrow.up")
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Share Margins from \(group.itemTitle)")
        .accessibilityIdentifier("margins.shareItem.\(group.itemID)")
        // Every active Margin of the item, not only those the search shows (#493).
        Button {
            markdownFileURL = model.marginMarkdownFileURL(
                for: model.marginRows.filter { $0.interjection.itemId == group.itemID }.map(\.interjection),
                asItem: true
            )
        } label: {
            Image(systemName: "doc.text").frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Share Margins from \(group.itemTitle) as Markdown")
        .accessibilityIdentifier("margins.shareItemMarkdown.\(group.itemID)")
    }

    @ViewBuilder
    private var collection: some View {
        if filteredRows.isEmpty {
            SMExperienceEmptyState(
                systemImage: "quote.bubble",
                title: model.marginRows.isEmpty ? "No Margins yet" : "Nothing in this view",
                detail: model.marginRows.isEmpty ? "While listening, record or write what you want to remember." : "Try a different search or filter.",
                actionTitle: model.marginRows.isEmpty ? (model.hasActiveSession ? "Open Now Playing" : "Choose an item") : "Clear search & filters"
            ) {
                if model.marginRows.isEmpty {
                    if model.hasActiveSession { model.openPlayback() } else { model.openLibrary() }
                } else { model.marginCollectionQuery = MarginCollectionQuery() }
            }
        } else {
            ForEach(groupedRows) { group in
                VStack(alignment: .leading, spacing: 0) {
                    groupHeading(group)
                    .padding(.top, 16)
                    .padding(.bottom, 6)

                    ForEach(group.rows) { row in
                        Button { selectedMargin = row } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: row.interjection.isStarredForSharing == true ? "star.fill" : (row.needsAttention ? "exclamationmark.bubble.fill" : (row.isWritten ? "square.and.pencil" : "quote.bubble")))
                                    .foregroundStyle(row.needsAttention ? AppColors.coral : AppColors.evergreen)
                                    .frame(width: 28, height: 32)
                                    .overlay(alignment: .bottomTrailing) {
                                        // A starred Margin that needs attention shows the star, so the warning is
                                        // a second shape and not only coral against evergreen (#1925).
                                        if row.needsAttention && row.interjection.isStarredForSharing == true {
                                            Image(systemName: "exclamationmark.circle.fill")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(AppColors.coral)
                                                .background(Circle().fill(AppColors.panel))
                                                .accessibilityHidden(true)
                                        }
                                    }
                                VStack(alignment: .leading, spacing: 5) {
                                    // Where it was made comes first, then the opening words. A bold one-line gist
                                    // missed the point on 15 of 40 of the owner's real Margins, so none is shown (#777).
                                    Text(row.captionDescription())
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(row.needsAttention ? AppColors.coral : AppColors.text)
                                        .multilineTextAlignment(.leading)
                                    if row.interjection.replyTo != nil {
                                        Label("Reply to a shared Margin", systemImage: "arrowshape.turn.up.left")
                                            .font(.caption)
                                            .foregroundStyle(AppColors.secondaryText)
                                    }
                                    if !row.needsAttention || row.preview != row.attentionDescription {
                                        Text(row.preview)
                                            .font(.system(.body, design: .serif))
                                            .foregroundStyle(AppColors.secondaryText)
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(AppColors.secondaryText)
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(row.interjection.replyTo == nil ? "My Margin" : "My reply to a shared Margin"). \(row.captionDescription().trimmingCharacters(in: CharacterSet(charactersIn: "."))). \(row.needsAttention && row.preview == row.attentionDescription ? "" : "\(row.preview). ")\(group.itemTitle).")
                        // The star on the row is a picture; the listener hears it as the row's value.
                        .accessibilityValue(row.interjection.isStarredForSharing == true ? "Starred for sharing" : "")
                        .accessibilityIdentifier("margins.row.\(row.id)")
                        .contextMenu { ownMarginActions(row) }
                        // The same actions for VoiceOver and Switch Control, which can't long-press (#1917).
                        .accessibilityActions { ownMarginActions(row) }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(AppColors.border.opacity(0.75)).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func ownMarginActions(_ row: MarginRow) -> some View {
        Button("Play this moment", systemImage: "play.fill") { _ = model.playMarginMoment(row) }
        Button("Copy with Context", systemImage: "doc.on.doc") { model.copyInterjectionWithContext(row.interjection) }
        Button(row.interjection.isStarredForSharing == true ? "Unstar" : "Star", systemImage: "star") {
            model.setInterjectionStarredForSharing(row.interjection.id, sessionId: row.interjection.sessionId, starred: row.interjection.isStarredForSharing != true)
        }
    }

    @ViewBuilder
    private var sharedCollection: some View {
        if model.visibleSharedMarginRows.isEmpty {
            ContentUnavailableView(
                model.marginCollectionQuery.text.isEmpty ? "No shared Margins" : "No matches",
                systemImage: "person.2",
                description: Text("Imported Margins appear here separately from your own notes.")
            )
        } else {
            ForEach(sharedEntries) { entry in
                if let row = entry.shared {
                    sharedRowButton(row, depth: entry.depth, note: entry.note)
                } else if let own = entry.own {
                    ownReplyRowButton(own, depth: entry.depth, note: entry.note)
                }
            }
        }
    }

    /// One row of the Shared list: a friend's Margin, or the listener's own Margin in a conversation with it.
    private struct SharedListEntry: Identifiable {
        let id: String
        let depth: Int
        let note: String?
        var shared: SharedMarginRow?
        var own: MarginRow?
    }

    /// The shared Margins the filters keep, in conversations: replies indented under the Margin they answer, the
    /// listener's own replies among them, and every conversation kept whole when one of its Margins matches (#473).
    private var sharedEntries: [SharedListEntry] {
        let visible = model.visibleSharedMarginRows
        let visibleIDs = Set(visible.map(\.interjection.id))
        let sharedByID = Dictionary(model.sharedMarginRows.map { ($0.interjection.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ownByID = Dictionary(model.marginRows.map { ($0.interjection.id, $0) }, uniquingKeysWith: { first, _ in first })
        var itemIDs: [String] = []
        for itemID in visible.compactMap(\.layer.itemId) where !itemIDs.contains(itemID) { itemIDs.append(itemID) }
        var entries: [SharedListEntry] = []
        var placed = Set<String>()
        for itemID in itemIDs {
            let rows = model.marginThreadRows(itemId: itemID)
            let kept = MarginThreadPresentation.threads(in: rows) {
                if case .imported(let id) = $0.reference { return visibleIDs.contains(id) }
                return false
            }
            for threadRow in kept {
                switch threadRow.reference {
                case .imported(let id):
                    guard let row = sharedByID[id] else { continue }
                    placed.insert(id)
                    entries.append(SharedListEntry(id: threadRow.id, depth: threadRow.depth, note: threadRow.note, shared: row))
                case .local(let id):
                    guard let row = ownByID[id] else { continue }
                    entries.append(SharedListEntry(id: threadRow.id, depth: threadRow.depth, note: threadRow.note, own: row))
                }
            }
        }
        // A shared Margin whose source isn't in the Library has no conversation to sit in.
        for row in visible where !placed.contains(row.interjection.id) {
            entries.append(SharedListEntry(id: "unplaced-\(row.id)", depth: 0, note: nil, shared: row))
        }
        return entries
    }

    private func threadIndent(_ depth: Int) -> CGFloat { CGFloat(min(depth, 3)) * 20 }

    private func sharedRowButton(_ row: SharedMarginRow, depth: Int, note: String?) -> some View {
        VStack(spacing: 0) {
            Button { selectedSharedMargin = row } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Label(depth > 0 ? "Reply · \(row.collectionLabel)" : "Shared · \(row.collectionLabel)", systemImage: depth > 0 ? "arrowshape.turn.up.left" : "person.2")
                            .font(.caption)
                            .foregroundStyle(AppColors.secondaryText)
                        if row.isNew { NewMarginBadge() }
                    }
                    if let note {
                        Text(note)
                            .font(.caption.italic())
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Text(row.interjection.approvedTranscript)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(AppColors.text)
                        .lineLimit(3)
                    Text("\(row.itemTitle) · \(row.positionDescription)")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .multilineTextAlignment(.leading)
                .padding(.vertical, 14)
                .padding(.leading, threadIndent(depth))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("margins.shared.row.\(row.id)")
            Divider()
        }
    }

    /// The listener's own reply, shown in the conversation it belongs to.
    private func ownReplyRowButton(_ row: MarginRow, depth: Int, note: String?) -> some View {
        VStack(spacing: 0) {
            Button { selectedMargin = row } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Label(depth > 0 ? "Your reply" : "Your Margin", systemImage: depth > 0 ? "arrowshape.turn.up.left.fill" : "quote.bubble")
                        .font(.caption)
                        .foregroundStyle(AppColors.evergreen)
                    if let note {
                        Text(note)
                            .font(.caption.italic())
                            .foregroundStyle(AppColors.secondaryText)
                    }
                    Text(row.preview)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(AppColors.text)
                        .lineLimit(3)
                    Text("\(row.itemTitle) · \(row.placeDescription())")
                        .font(.caption)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .multilineTextAlignment(.leading)
                .padding(.vertical, 14)
                .padding(.leading, threadIndent(depth))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("margins.shared.ownRow.\(row.id)")
            Divider()
        }
    }

    private var filteredRows: [MarginRow] { model.visiblePrivateMarginRows }

    private var groupedRows: [MarginGroup] {
        let orderedItemIDs = filteredRows.reduce(into: [String]()) { result, row in
            if !result.contains(row.interjection.itemId) { result.append(row.interjection.itemId) }
        }
        let rowsByItem = Dictionary(grouping: filteredRows, by: \.interjection.itemId)
        return orderedItemIDs.compactMap { itemID in
            guard let rows = rowsByItem[itemID], let first = rows.first else { return nil }
            // Within an item, Margins read in the order they were heard (#777).
            let heardInOrder = rows.sorted { MarginSourceOrder.isOrderedBefore($0.interjection, $1.interjection) }
            return MarginGroup(itemID: itemID, itemTitle: first.itemTitle, rows: heardInOrder)
        }
    }

}

struct SharedMarginDetailView: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var shouldOpenItem = false
    @State private var pendingReply: ReplyKind?
    let row: SharedMarginRow
    /// The model's current copy, so placement progress updates while the sheet is open (#872).
    private var current: SharedMarginRow { model.sharedMarginRows.first { $0.id == row.id } ?? row }

    private enum ReplyKind { case voice, written }

    /// The Margin this one answers, when this Margin is itself a reply and the parent is in the Library (#473).
    private var parentContext: MarginThreadPresentation.ParentContext? {
        guard let itemId = row.layer.itemId, row.interjection.replyLinks?.isEmpty == false else { return nil }
        return model.marginParentContext(of: .imported(row.interjection.id), itemId: itemId)
    }

    private var isReplyWithoutParent: Bool {
        row.interjection.replyLinks?.isEmpty == false && parentContext == nil
    }

    /// The sheet closes first and the recorder opens when it has gone, as Open Item does.
    private func reply(inWriting: Bool) {
        pendingReply = inWriting ? .written : .voice
        dismiss()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Shared · \(row.collectionLabel)", systemImage: "person.2")
                        .font(.subheadline)
                    Text(row.interjection.approvedTranscript)
                        .font(.system(.title3, design: .serif))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let context = parentContext {
                    Section("Replying to") {
                        MarginParentContextView(context: context)
                    }
                } else if isReplyWithoutParent {
                    Section {
                        Label(MarginThreadPresentation.missingParentNote, systemImage: "arrowshape.turn.up.left")
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("sharedMargin.replyMissingParent.label")
                    }
                }
                if current.layer.itemId != nil, SharedMarginReplyPlace(current.interjection) != nil {
                    Section {
                        Button("Reply", systemImage: "arrowshape.turn.up.left.fill") { reply(inWriting: false) }
                            .accessibilityIdentifier("sharedMargin.reply.button")
                        Button("Reply in writing", systemImage: "square.and.pencil") { reply(inWriting: true) }
                            .accessibilityIdentifier("sharedMargin.replyWritten.button")
                    } footer: {
                        Text("Your reply is saved at this moment and goes out with the item. Their recording is not sent again.")
                    }
                }
                Section("Source & position") {
                    Text(row.itemTitle)
                    Text(current.positionDescription)
                    if row.layer.itemId != nil {
                        Button("Open item and shared controls", systemImage: "doc.text") {
                            shouldOpenItem = true
                            dismiss()
                        }
                    } else {
                        Text("The source is missing. Open the original shared file to match it.")
                    }
                }
                Section {
                    DisclosureGroup("Package details") {
                        Text("Package integrity checked. Sender identity is unverified; this does not restrict playback.")
                        Text("Imported \(row.layer.importedAt.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle("Shared Margin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onDisappear {
                if shouldOpenItem, let itemID = row.layer.itemId { model.openItem(id: itemID) }
                if let pendingReply { model.replyToSharedMargin(current, inWriting: pendingReply == .written) }
                pendingReply = nil
            }
        }
    }
}

/// The Margin a reply answers, named with its sender and words, and a way to hear it first (#473).
struct MarginParentContextView: View {
    @EnvironmentObject private var model: Gate1AppModel
    let context: MarginThreadPresentation.ParentContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(context.senderLabel)
                .font(.subheadline.weight(.semibold))
            if !context.text.isEmpty {
                Text(context.text)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(AppColors.secondaryText)
                    .lineLimit(6)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("margin.parentContext.text")
        Button("Hear what it answers", systemImage: "play.fill") { model.playMarginParent(context) }
            .accessibilityIdentifier("margin.parentContext.play.button")
    }
}

/// The scope control and the Margins count. The control is a menu whose label is one line, cut with an ellipsis,
/// so a long item title can't wrap into the filters and the group heading under it (#1631). The menu's own rows
/// still show the full titles. A view of its own so a test can measure its height without the screen around it.
struct MarginsScopeRow: View {
    let title: String
    let countText: String
    @Binding var selection: String?
    let collections: [ItemCollection]
    let items: [LibraryItemRow]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the count drops under the scope menu so the title keeps the full width (#1938).
        (dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 8))) {
            scopeMenu
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(countText)
                .font(.caption).foregroundStyle(AppColors.secondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var scopeMenu: some View {
        Menu {
            Picker("Scope", selection: $selection) {
                Text("All items").tag(String?.none)
                if !collections.isEmpty {
                    Section("Collections") {
                        ForEach(collections) { collection in
                            Text(collection.name).tag(Optional(MarginCollectionQuery.collectionTagPrefix + collection.id))
                        }
                    }
                }
                Section("Items") {
                    ForEach(items) { item in Text(item.title).tag(Optional(item.id)) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .frame(minHeight: 44, alignment: .leading)
        }
        .layoutPriority(1)
        .accessibilityLabel("Scope")
        .accessibilityValue(title)
        .accessibilityIdentifier("margins.scope.picker")
    }
}

/// The Margins search field, at least 44 pt tall (#151). The rounded-border style alone is about 34 pt.
struct MarginsSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        // A single-line field stays about 34 pt tall inside the 44 pt frame, so a tap catcher behind it focuses
        // the field when the tap lands in the extra room above or below. Taps on the field itself never reach it.
        TextField("Search your notes or an item", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .frame(minHeight: TapTarget.minimum)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isFocused = true }
            }
            .accessibilityIdentifier("margins.search.field")
    }
}
