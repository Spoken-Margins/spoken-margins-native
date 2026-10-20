import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension View {
    /// Keeps `isPresented` in step with the software keyboard, so the root can hide its mini player while typing.
    func tracksKeyboard(_ isPresented: Binding<Bool>) -> some View {
        #if canImport(UIKit)
        self
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isPresented.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isPresented.wrappedValue = false
            }
        #else
        self
        #endif
    }
}
