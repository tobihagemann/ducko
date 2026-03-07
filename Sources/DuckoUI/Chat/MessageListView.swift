import DuckoCore
import SwiftUI

struct MessageListView: View {
    @Environment(ThemeEngine.self) private var theme
    let windowState: ChatWindowState
    @State private var hoveredMessageID: UUID?

    private var messages: [ChatMessage] {
        windowState.messages
    }

    private var positions: [UUID: MessagePosition] {
        computeMessagePositions(messages)
    }

    private var stanzaIDMap: [String: ChatMessage] {
        var map: [String: ChatMessage] = [:]
        for message in messages {
            if let stanzaID = message.stanzaID {
                map[stanzaID] = message
            }
        }
        return map
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !windowState.hasReachedEnd {
                        Color.clear.frame(height: 1)
                            .onAppear {
                                Task { await windowState.loadOlderMessages() }
                            }
                    }

                    if windowState.isLoadingOlder {
                        ProgressView()
                            .padding()
                    }

                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let pos = positions[message.id] ?? MessagePosition(isFirstInGroup: true, isLastInGroup: true)
                        let repliedMessage = message.replyToID.flatMap({ stanzaIDMap[$0] })
                        let isSearchResult = windowState.searchResults.contains(message.id)

                        if theme.current.timestampStyle == .grouped, isNewDay(at: index) {
                            Text(message.timestamp.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }

                        MessageBubbleView(
                            message: message,
                            position: pos,
                            isHovered: hoveredMessageID == message.id,
                            repliedMessage: repliedMessage,
                            windowState: windowState
                        )
                        .id(message.id)
                        .padding(.top, pos.isFirstInGroup ? 8 : 2)
                        .padding(.horizontal)
                        .onHover { hovering in
                            hoveredMessageID = hovering ? message.id : nil
                        }
                        .background(
                            isSearchResult ? Color.yellow.opacity(0.15) : Color.clear,
                            in: .rect(cornerRadius: 8)
                        )
                    }
                }
            }
            .onChange(of: messages.last?.id) { _, lastID in
                guard let lastID else { return }
                withAnimation {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: windowState.currentSearchIndex) {
                guard !windowState.searchResults.isEmpty else { return }
                let targetID = windowState.searchResults[windowState.currentSearchIndex]
                withAnimation {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            }
        }
    }

    private func isNewDay(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(messages[index].timestamp, inSameDayAs: messages[index - 1].timestamp)
    }
}
