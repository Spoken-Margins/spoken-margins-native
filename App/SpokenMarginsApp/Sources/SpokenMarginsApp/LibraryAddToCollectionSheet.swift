import SwiftUI
import SessionKit

/// Select's Add to Collection (#4720): pick a collection to add the ticked rows to, or name a new one here and it is made
/// holding them, in the order the listener sees. Either way the sheet closes and a banner gives the count.
struct LibraryAddToCollectionSheet: View {
    @EnvironmentObject private var model: Gate1AppModel
    @Environment(\.dismiss) private var dismiss

    let itemIDs: [String]
    /// The collection whose screen Select is on: adding to itself is not offered.
    let excludingCollectionID: String?
    let finished: () -> Void

    @State private var newName = ""
    @State private var problem: String?
    @State private var isSaving = false

    private var choices: [LibraryCollectionRow] {
        model.libraryCollectionRows.filter { $0.collectionID != excludingCollectionID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("New Collection") {
                    AppTextField("Name, such as HIST 210", text: $newName)
                        .submitLabel(.done)
                        .onSubmit(createNew)
                        .accessibilityIdentifier("library.addToCollection.newName")
                    Button("Create Collection", systemImage: "plus.circle", action: createNew)
                        .disabled(ItemCollectionEditing.normalizedName(newName) == nil || isSaving)
                        .accessibilityIdentifier("library.addToCollection.create")
                    if let problem {
                        Text(problem)
                            .font(.subheadline)
                            .foregroundStyle(AppColors.secondaryText)
                    }
                }
                if !choices.isEmpty {
                    Section("Collections") {
                        ForEach(choices) { choice in
                            Button { add(to: choice.collectionID) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(choice.name).foregroundStyle(AppColors.text)
                                    Text(choice.progress.detailLine)
                                        .font(.subheadline)
                                        .foregroundStyle(AppColors.secondaryText)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("library.addToCollection.\(choice.collectionID)")
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.bone)
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .accessibilityIdentifier("library.addToCollection.sheet")
    }

    private func add(to collectionID: String) {
        guard let collection = model.libraryCollections.collections.first(where: { $0.id == collectionID }) else { return }
        isSaving = true
        Task {
            let saved = await model.addItems(itemIDs, toCollection: collection)
            isSaving = false
            if saved { close() }
        }
    }

    private func createNew() {
        guard ItemCollectionEditing.normalizedName(newName) != nil, !isSaving else {
            problem = ItemCollectionEditing.Wording.nameRequired
            return
        }
        isSaving = true
        let name = newName
        Task {
            problem = await model.addItems(itemIDs, toNewCollectionNamed: name)
            isSaving = false
            if problem == nil { close() }
        }
    }

    private func close() {
        finished()
        dismiss()
    }
}
