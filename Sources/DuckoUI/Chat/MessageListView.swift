import DuckoCore
import SwiftUI

struct MessageListView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(environment.chatService.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: environment.chatService.messages.last?.id) { _, lastID in
                guard let lastID else { return }
                withAnimation {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }
}
