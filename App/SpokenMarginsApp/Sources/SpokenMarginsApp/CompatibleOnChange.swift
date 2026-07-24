import SwiftUI

extension View {
    @ViewBuilder
    func onCompatibleChange<Value: Equatable>(
        of value: Value,
        perform action: @escaping (Value) -> Void
    ) -> some View {
        #if SPOKEN_MARGINS_LEGACY
        self.onChange(of: value, perform: action)
        #else
        self.onChange(of: value) { _, newValue in
            action(newValue)
        }
        #endif
    }
}
