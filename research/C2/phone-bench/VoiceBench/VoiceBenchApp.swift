// C2 M2 phone benchmark: the throwaway VoiceBench app (com.spokenmargins.voicebench). See ../README.md.
import SwiftUI

@main
struct VoiceBenchApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { VoiceBenchView() }
        }
    }
}
