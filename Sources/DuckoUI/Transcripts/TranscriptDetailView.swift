import DuckoCore
import SwiftUI

struct TranscriptDetailView: View {
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

                // Date list + messages
                VSplitView {
                    dateListView
                    messageListView
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

    // MARK: - Date List

    private var dateListView: some View {
        List(state.messageDates, id: \.self, selection: Binding(
            get: { state.selectedDate },
            set: { newDate in
                Task { await state.selectDate(newDate) }
            }
        )) { date in
            HStack {
                Text(date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt)))
                Spacer()
                if state.searchMatchDates.contains(date) {
                    Image(systemName: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .frame(minHeight: 100)
    }

    // MARK: - Message List

    private var messageListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(messages) { message in
                    let pos = positions[message.id] ?? MessagePosition(isFirstInGroup: true, isLastInGroup: true)

                    TranscriptBubbleView(
                        message: message,
                        position: pos,
                        isGroupchat: isGroupchat,
                        isSearchResult: state.searchResults.contains(message.id)
                    )
                }
            }
        }
        .frame(minHeight: 200)
    }
}
