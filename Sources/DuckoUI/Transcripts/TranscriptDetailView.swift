import DuckoCore
import SwiftUI

struct TranscriptDetailView: View {
    @Environment(ThemeEngine.self) private var theme
    let state: TranscriptViewerState

    private var messages: [ChatMessage] {
        state.messages
    }

    private var positions: [UUID: MessagePosition] {
        computeMessagePositions(messages)
    }

    private var isGroupchat: Bool {
        state.selectedConversation?.type == .groupchat
    }

    var body: some View {
        if let conversation = state.selectedConversation {
            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text(conversation.displayName ?? conversation.jid.description)
                            .font(.headline)
                        Text(conversation.jid.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                // Messages
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !state.hasReachedEnd {
                            Color.clear.frame(height: 1)
                                .onAppear {
                                    Task { await state.loadOlderMessages() }
                                }
                        }

                        if state.isLoadingOlder {
                            ProgressView()
                                .padding()
                        }

                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let pos = positions[message.id] ?? MessagePosition(isFirstInGroup: true, isLastInGroup: true)

                            if theme.current.timestampStyle == .grouped, isNewDay(at: index) {
                                Text(message.timestamp.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }

                            TranscriptBubbleView(
                                message: message,
                                position: pos,
                                isGroupchat: isGroupchat,
                                isSearchResult: state.searchResults.contains(message.id)
                            )
                        }
                    }
                }
            }
            .searchable(text: Binding(
                get: { state.transcriptSearchText },
                set: { newValue in
                    state.transcriptSearchText = newValue
                    Task { await state.performTranscriptSearch() }
                }
            ), placement: .toolbar, prompt: "Search in conversation")
            .navigationTitle(conversation.displayName ?? conversation.jid.description)
        } else {
            ContentUnavailableView(
                "Select a Conversation",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Choose a conversation from the sidebar to view its transcript.")
            )
        }
    }

    private func isNewDay(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = messages[index].timestamp
        let previous = messages[index - 1].timestamp
        return !Calendar.current.isDate(current, inSameDayAs: previous)
    }
}
