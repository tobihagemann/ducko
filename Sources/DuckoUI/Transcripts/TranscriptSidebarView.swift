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
                DisclosureGroup {
                    ForEach(group.conversations) { conversation in
                        TranscriptSidebarRow(conversation: conversation)
                            .tag(conversation.id)
                    }
                } label: {
                    HStack {
                        Text(group.account.displayName ?? group.account.jid.description)
                            .fontWeight(.semibold)

                        Spacer()

                        Text("\(group.conversations.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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

            ToolbarItem(placement: .automatic) {
                Menu {
                    Button(TranscriptDateFilter.anyTime.label) { state.dateFilter = .anyTime }
                    Button(TranscriptDateFilter.today.label) { state.dateFilter = .today }
                    Button(TranscriptDateFilter.thisWeek.label) { state.dateFilter = .thisWeek }
                    Button(TranscriptDateFilter.thisMonth.label) { state.dateFilter = .thisMonth }
                } label: {
                    Label(
                        state.dateFilter.label,
                        systemImage: state.dateFilter == .anyTime ? "calendar" : "calendar.badge.clock"
                    )
                }
                .accessibilityIdentifier("transcript-date-filter-menu")
            }
        }
        .onChange(of: state.dateFilter) {
            Task { await state.clearSelectionIfFiltered() }
        }
    }
}
