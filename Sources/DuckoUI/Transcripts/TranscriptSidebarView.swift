import DuckoCore
import SwiftUI

struct TranscriptSidebarView: View {
    @Bindable var state: TranscriptViewerState

    var body: some View {
        List(selection: Binding(
            get: { state.selectedConversation?.id },
            set: { newID in
                let conversation = state.allConversations.first { $0.id == newID }
                Task { await state.selectConversation(conversation) }
            }
        )) {
            ForEach(state.conversationsByAccount, id: \.account.id) { group in
                TranscriptSidebarSection(
                    title: group.account.displayName ?? group.account.jid.description,
                    conversations: group.conversations
                )
            }

            let imported = state.importedConversations
            if !imported.isEmpty {
                TranscriptSidebarSection(title: "Imported", conversations: imported)
            }
        }
        .searchable(text: $state.searchText, placement: .sidebar, prompt: "Filter conversations")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Type", selection: $state.typeFilter) {
                    ForEach(ConversationTypeFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .onChange(of: state.typeFilter) {
            Task { await state.clearSelectionIfFiltered() }
        }
    }
}

// MARK: - Section

private struct TranscriptSidebarSection: View {
    let title: String
    let conversations: [Conversation]

    var body: some View {
        DisclosureGroup {
            ForEach(conversations) { conversation in
                TranscriptSidebarRow(conversation: conversation)
                    .tag(conversation.id)
            }
        } label: {
            HStack {
                Text(title)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(conversations.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
