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
            .accessibilityIdentifier("message-list")
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, lastID in
                guard let lastID else { return }
                scrollToBottom(proxy, id: lastID)
            }
            // Prepended history (MAM sync, loadOlderMessages) leaves the last
            // message's id unchanged but pushes it offscreen — re-anchor.
            .onChange(of: messages.count) {
                guard let lastID = messages.last?.id else { return }
                scrollToBottom(proxy, id: lastID)
            }
            // An edit/retract of the last message updates its body without
            // changing identity. Re-anchor so the change is visible.
            .onChange(of: messages.last?.body) {
                guard let lastID = messages.last?.id else { return }
                scrollToBottom(proxy, id: lastID)
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

    /// Double-pass scroll: LazyVStack hasn't reified the target before the
    /// in-update `scrollTo` commits, so a 50 ms deferred pass catches the
    /// now-materialized item and exposes its text to the accessibility
    /// bridge.
    private func scrollToBottom(_ proxy: ScrollViewProxy, id: UUID) {
        withAnimation {
            proxy.scrollTo(id, anchor: .bottom)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}
