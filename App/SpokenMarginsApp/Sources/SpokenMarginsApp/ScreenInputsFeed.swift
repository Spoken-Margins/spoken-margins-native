import Combine
import SwiftUI

/// What one tab screen reads from `Gate1AppModel`, published only when it differs from the last read (#4028).
///
/// The model publishes many times a second while audio renders and plays: each rendered chunk, each whole percent of
/// progress, a sleep timer's tick, a download's progress. A screen that watched the whole model (`@EnvironmentObject`)
/// reran its body on every one of them, 20 runs for 20 publishes on Following, Margins and Settings, and rebuilt every
/// visible row while the list was moving, which the owner felt as jerky scrolling. A screen that reads through a feed
/// instead holds the model only to run its buttons, and its body runs only when something it shows has changed.
///
/// `read` must take everything the screen's body shows from the model; a value read straight from the model in the body
/// would go stale until something in the feed changes. Buttons and tasks still read the model when they run.
@MainActor
final class ScreenInputsFeed<Inputs: Equatable>: ObservableObject {
    @Published private(set) var inputs: Inputs
    private let read: @MainActor (Gate1AppModel) -> Inputs
    private weak var model: Gate1AppModel?
    private var subscription: AnyCancellable?
    private var isReadPending = false

    init(model: Gate1AppModel, read: @escaping @MainActor (Gate1AppModel) -> Inputs) {
        self.model = model
        self.read = read
        inputs = read(model)
        subscription = model.objectWillChange.sink { [weak self] _ in self?.readAfterChange() }
    }

    /// `objectWillChange` fires before the model's value changes, so the read waits for the next turn of the main queue,
    /// where SwiftUI would have redrawn the screen too. Several publishes in one turn make one read. The main queue runs
    /// while a list is being dragged; a run-loop scheduler in its default mode would hold the read until the drag ended.
    private func readAfterChange() {
        guard !isReadPending else { return }
        isReadPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isReadPending = false
                guard let model = self.model else { return }
                let next = self.read(model)
                if next != self.inputs { self.inputs = next }
            }
        }
    }
}

extension Gate1AppModel {
    /// A binding to one of the model's values for a screen that does not watch the model: it reads the model when the
    /// control draws and writes straight to it. The screen redraws when its feed carries the new value.
    func screenBinding<Value>(_ keyPath: ReferenceWritableKeyPath<Gate1AppModel, Value>) -> Binding<Value> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}
