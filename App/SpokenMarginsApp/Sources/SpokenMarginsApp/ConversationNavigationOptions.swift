import SwiftUI

struct ConversationNavigationOptions: View {
    @EnvironmentObject private var model: Gate1AppModel
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { scope; context }
            VStack(alignment: .leading) { scope; context }
        }
        .font(.subheadline)
        .disabled(model.snapshot.isRecording)
    }
    private var scope: some View {
        Picker("Skim through", selection: $model.conversationScope) {
            ForEach(ConversationScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("conversation.scope")
    }
    private var context: some View {
        Picker("Context", selection: $model.conversationContextSeconds) {
            Text("No context").tag(0)
            Text("30 seconds").tag(30)
            Text("1 minute").tag(60)
            Text("2 minutes").tag(120)
            Text("5 minutes").tag(300)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("conversation.context")
    }
}
