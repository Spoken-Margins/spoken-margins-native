import Foundation
import Combine

@MainActor
final class RuntimeDiagnostics: ObservableObject {
    @Published var values: [String: String] = [:]
}
