import SwiftUI

struct MessageSearchBar: View {
    let windowState: ChatWindowState

    var body: some View {
        HStack(spacing: 8) {
            TextField("Search messages", text: Bindable(windowState).searchText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { windowState.performSearch() }

            if !windowState.searchResults.isEmpty {
                Text("\(windowState.currentSearchIndex + 1)/\(windowState.searchResults.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button {
                    windowState.previousSearchResult()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)

                Button {
                    windowState.nextSearchResult()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
            }

            Button("Done") {
                windowState.dismissSearch()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
        .accessibilityIdentifier("message-search-bar")
    }
}
