import SessionKit
import SwiftUI

/// The Rules screen (#4046 PR 10b), pushed from the Lists screen's Rules row, or from a list's Rules for this list (then it
/// shows only that list's rules, and a new rule starts scoped to the list). Rules are in On and Off sections, each with its
/// sentence, an origin line and a switch. Turning on a skip rule that would skip almost everything is refused with an alert,
/// and the rule stays off. The Suggested section (PR 12) lists every live suggestion as a card, on the full screen only.
///
/// The model is passed in, not observed, so the screen redraws for the rules and lists it watches, not for every publish of
/// `Gate1AppModel` (#4028).
struct RulesScreen: View {
    let model: Gate1AppModel
    let subscriptions: [FeedSubscription]
    /// Rules for this list: only rules scoped to it, and New rule starts with it chosen.
    var onlyListID: String? = nil

    @ObservedObject private var rulesState = ListeningRulesState.shared
    @ObservedObject private var listsState = FollowListsState.shared
    @ObservedObject private var suggestionsState = RuleSuggestionsState.shared
    @State private var isAdding = false
    @State private var isTurningOn = false
    @State private var refusal: ListeningRuleScreens.Refusal?
    /// Per rule id, the shows a rule that is on is paused for. Worked out off the main thread from Following's entries.
    @State private var pausedShowTitles: [String: [String]] = [:]

    var body: some View {
        let sections = ListeningRuleScreens.sections(
            rules: rulesState.rules, lists: listsState.lists, subscriptions: subscriptions,
            pausedShowTitles: pausedShowTitles, onlyList: onlyListID
        )
        return List {
            if onlyListID == nil, !suggestionsState.suggestions.isEmpty {
                Section(RuleSuggestionWords.suggestedHeader) {
                    ForEach(suggestionsState.suggestions) { suggestion in
                        RuleSuggestionCard(suggestion: suggestion, isBusy: isTurningOn) {
                            turnOn(suggestion)
                        } notNow: {
                            Task { await model.putOffSuggestion(suggestion) }
                        } never: {
                            Task { await model.refuseSuggestion(suggestion) }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            if !rulesState.loaded {
                EmptyView()
            } else if sections.isEmpty {
                SMExperienceEmptyState(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: ListeningRuleScreens.emptyTitle,
                    detail: ListeningRuleScreens.emptyDetail,
                    actionTitle: ListeningRuleScreens.newRuleTitle
                ) { isAdding = true }
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("rules.empty")
            } else {
                if !sections.on.isEmpty {
                    Section("On") { ForEach(sections.on) { ruleRow($0) } }
                }
                if !sections.off.isEmpty {
                    Section("Off") { ForEach(sections.off) { ruleRow($0) } }
                }
                Section {
                    Button { isAdding = true } label: {
                        Label(ListeningRuleScreens.newRuleTitle, systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("rules.new")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.bone)
        .navigationTitle(ListeningRuleScreens.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.reloadListeningRules()
            await model.reloadFollowLists()
            if onlyListID == nil { await model.reloadRuleSuggestions() }
        }
        .task(id: PausedKey(rules: rulesState.rules, revision: rulesState.entriesRevision)) {
            pausedShowTitles = await pausedTitles()
        }
        .alert(
            refusal?.title ?? "",
            isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal?.message ?? "")
        }
        .trackedSheet(isPresented: $isAdding) {
            NewRuleSheet(model: model, subscriptions: subscriptions, initialScope: onlyListID.map { .list($0) } ?? .any)
        }
        .accessibilityIdentifier("rules.screen")
    }

    private func ruleRow(_ row: ListeningRuleScreens.Row) -> some View {
        HStack(spacing: 12) {
            NavigationLink {
                RuleScreen(model: model, subscriptions: subscriptions, ruleID: row.id)
                    .miniPlayerKeepOut()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.sentence).foregroundStyle(AppColors.text)
                    Text(row.originLine)
                        .font(.subheadline)
                        .foregroundStyle(AppColors.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            Toggle(isOn: Binding(get: { row.isOn }, set: { setOn(row.id, $0) })) { EmptyView() }
                .labelsHidden()
                .tint(AppColors.evergreen)
                .accessibilityLabel(row.accessibilityLabel)
                .accessibilityIdentifier("rules.toggle.\(row.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rules.row.\(row.id)")
    }

    private func turnOn(_ suggestion: RuleSuggestion) {
        guard !isTurningOn else { return }
        isTurningOn = true
        Task {
            let change = await model.turnOnSuggestion(suggestion)
            if let refused = change?.refusal { refusal = refused }
            if change?.isFull == true { refusal = ListeningRuleScreens.fullRefusal }
            isTurningOn = false
        }
    }

    private func setOn(_ id: String, _ isOn: Bool) {
        Task {
            if let refused = await model.setListeningRuleOn(id: id, isOn: isOn)?.refusal { refusal = refused }
        }
    }

    private struct PausedKey: Equatable {
        let rules: [ListeningRule]
        let revision: Int
    }

    /// The evaluator over Following's entries, with the rules as this screen shows them, so a rule switched on a moment ago
    /// already shows whether it is paused.
    private func pausedTitles() async -> [String: [String]] {
        let subscriptions = subscriptions, entries = model.followingShowEntries, library = model.followingLibraryEpisodes
        let inputs = FollowingRuleInputs(
            rules: rulesState.rules, lists: listsState.lists, marks: model.followingRuleInputs.marks)
        return await Task.detached(priority: .userInitiated) {
            let evaluation = FollowingRuleEvaluation.evaluate(
                subscriptions: subscriptions, entries: entries, inputs: inputs, libraryEpisodes: library)
            return ListeningRuleScreens.pausedShowTitles(in: evaluation, subscriptions: subscriptions)
        }.value
    }
}

/// One rule (#4046 PR 10b): its sentence, how many of the last 30 episodes in its scope it matches (with those listed),
/// its words to edit, and Delete rule.
struct RuleScreen: View {
    let model: Gate1AppModel
    let subscriptions: [FeedSubscription]
    let ruleID: String

    @ObservedObject private var rulesState = ListeningRulesState.shared
    @ObservedObject private var listsState = FollowListsState.shared
    @Environment(\.dismiss) private var dismiss
    @State private var wordsField = ""
    @State private var wordsProblem: String?
    @State private var matches: ListeningRuleScreens.Matches?
    @State private var isDeleting = false
    /// Set by Delete rule, so leaving the screen doesn't save words to a rule that is gone.
    @State private var isDeleted = false

    private var rule: ListeningRule? { rulesState.rules.first { $0.id == ruleID } }

    var body: some View {
        Group {
            if let rule {
                content(rule)
            } else {
                // Deleted here: nothing left to show. Only this branch dismisses, so one deletion pops one level.
                Color.clear.onAppear { dismiss() }
            }
        }
        .background(AppColors.bone)
        .onAppear { if let rule { wordsField = ListeningRuleScreens.wordsField(for: rule) } }
        .task(id: MatchKey(rule: rule, revision: rulesState.entriesRevision)) {
            guard let rule else { return }
            matches = await matchesFor(rule)
        }
    }

    private func content(_ rule: ListeningRule) -> some View {
        List {
            Section {
                Text(ListeningRuleScreens.sentence(for: rule, subscriptions: subscriptions, lists: listsState.lists))
                    .font(.headline)
                    .foregroundStyle(AppColors.text)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("rule.sentence")
            }
            Section {
                TextField("crypto, bitcoin*", text: $wordsField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { saveWords() }
                    .accessibilityLabel("Words")
                    .accessibilityIdentifier("rule.words")
                if let wordsProblem {
                    Text(wordsProblem)
                        .font(.footnote)
                        .foregroundStyle(AppColors.secondaryText)
                        .accessibilityIdentifier("rule.words.problem")
                }
            } header: {
                Text("Words")
            } footer: {
                Text("Separate words with commas. A word ending in * matches the start of a word.")
            }
            if let matches {
                Section {
                    ForEach(matches.matched, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).foregroundStyle(AppColors.text).lineLimit(2)
                            if let show = showTitle(of: entry) {
                                Text(show).font(.caption).foregroundStyle(AppColors.secondaryText)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text(matches.summary).accessibilityIdentifier("rule.matches")
                }
            }
            Section {
                Button(role: .destructive) { isDeleting = true } label: {
                    Label("Delete rule", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("rule.delete")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Rule")
        .navigationBarTitleDisplayMode(.inline)
        // Leaving with valid, changed words keeps them, as Settings fields do.
        .onDisappear { if !isDeleted, wordsField != ListeningRuleScreens.wordsField(for: rule) { saveWords() } }
        .confirmationDialog(ListeningRuleScreens.deleteQuestion, isPresented: $isDeleting, titleVisibility: .visible) {
            Button("Delete rule", role: .destructive) {
                isDeleted = true
                Task { await model.deleteListeningRule(id: rule.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityIdentifier("rule.screen")
    }

    private func saveWords() {
        let field = wordsField
        Task {
            let change = await model.setListeningRuleWords(id: ruleID, wordsField: field)
            wordsProblem = change?.problem?.message
            if change?.problem == nil, let saved = change?.rules.first(where: { $0.id == ruleID }) {
                wordsField = ListeningRuleScreens.wordsField(for: saved)
            }
        }
    }

    private func showTitle(of entry: FeedEntry) -> String? {
        subscriptions.first { $0.id == entry.subscriptionId }.map(FollowingShowRows.displayTitle(of:))
    }

    private struct MatchKey: Equatable {
        let rule: ListeningRule?
        let revision: Int
    }

    private func matchesFor(_ rule: ListeningRule) async -> ListeningRuleScreens.Matches {
        let subscriptions = subscriptions, entries = model.followingShowEntries, lists = listsState.lists
        return await Task.detached(priority: .userInitiated) {
            ListeningRuleScreens.matches(
                for: rule, shows: ListeningRuleScreens.shows(subscriptions: subscriptions, entries: entries), lists: lists)
        }.value
    }
}

/// The New rule form (#4046 PR 10b): Skip or Mark as a pick, the words, and where it applies. Save is disabled until there
/// is at least one word. A saved rule is switched on, unless it would skip almost everything for a show: then it is kept
/// off and the alert says why.
struct NewRuleSheet: View {
    let model: Gate1AppModel
    let subscriptions: [FeedSubscription]
    let initialScope: ListeningRuleScope

    @ObservedObject private var listsState = FollowListsState.shared
    @Environment(\.dismiss) private var dismiss
    /// One id for this form, so a second tap on Save finds the rule the first made (`burst`).
    @State private var ruleID = UUID().uuidString
    @State private var action: ListeningRuleScreens.ActionChoice = .skip
    @State private var wordsField = ""
    @State private var scope: ListeningRuleScope = .any
    @State private var didSetScope = false
    @State private var isSaving = false
    @State private var alert: ListeningRuleScreens.Refusal?

    var body: some View {
        let choices = ListeningRuleScreens.scopeChoices(lists: listsState.lists, subscriptions: subscriptions)
        let problem = ListeningRuleScreens.wordsProblem(wordsField)
        return NavigationStack {
            Form {
                Section {
                    Picker("Action", selection: $action) {
                        ForEach(ListeningRuleScreens.ActionChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .segmentedUnlessLargeText()
                    .accessibilityIdentifier("newRule.action")
                }
                Section {
                    TextField("crypto, bitcoin*", text: $wordsField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Episodes that mention")
                        .accessibilityIdentifier("newRule.words")
                    if let problem {
                        Text(problem.message)
                            .font(.footnote)
                            .foregroundStyle(AppColors.secondaryText)
                            .accessibilityIdentifier("newRule.words.problem")
                    }
                } header: {
                    Text("Episodes that mention")
                } footer: {
                    Text("Separate words with commas. A word ending in * matches the start of a word.")
                }
                Section {
                    Picker("From", selection: $scope) {
                        Text(choices.any.label).tag(choices.any.scope)
                        if !choices.lists.isEmpty {
                            Section("Lists") {
                                ForEach(choices.lists) { Text($0.label).tag($0.scope) }
                            }
                        }
                        if !choices.shows.isEmpty {
                            Section("Shows") {
                                ForEach(choices.shows) { Text($0.label).tag($0.scope) }
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("newRule.scope")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle(ListeningRuleScreens.newRuleTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("newRule.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving || !ListeningRuleScreens.canSave(wordsField: wordsField))
                        .accessibilityIdentifier("newRule.save")
                }
            }
            .alert(
                alert?.title ?? "",
                isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
            ) {
                // The rule is saved (off) or nothing was saved; either way the form is done.
                Button("OK", role: .cancel) { dismiss() }
            } message: {
                Text(alert?.message ?? "")
            }
        }
        .onAppear {
            guard !didSetScope else { return }
            didSetScope = true
            scope = initialScope
        }
        .accessibilityIdentifier("newRule.sheet")
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let id = ruleID, action = action.action, field = wordsField, scope = scope
        Task {
            let change = await model.createListeningRule(id: id, action: action, wordsField: field, scope: scope)
            isSaving = false
            guard let change else { return }
            if change.isFull {
                alert = ListeningRuleScreens.fullRefusal
            } else if let refusal = change.refusal {
                alert = refusal
            } else if change.problem == nil {
                dismiss()
            }
        }
    }
}
