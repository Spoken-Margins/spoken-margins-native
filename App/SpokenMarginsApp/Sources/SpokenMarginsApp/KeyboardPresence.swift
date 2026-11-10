import SwiftUI
import SessionKit
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

    /// Tells the Timeline editor's dock when the software keyboard arrives and when it has fully left (#4043).
    func tracksKeyboard(for dock: Binding<TimelineEditingDock>) -> some View {
        #if canImport(UIKit)
        self
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                dock.wrappedValue.keyboardWillShow()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                dock.wrappedValue.keyboardDidHide()
            }
        #else
        self
        #endif
    }
}
