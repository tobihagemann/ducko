import SwiftUI

struct ChatTabBar: View {
    let tabManager: ChatTabManager

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabManager.tabs) { tab in
                ChatTabLabel(
                    tab: tab,
                    isSelected: tab.id == tabManager.selectedTabID,
                    onClose: { tabManager.closeTab(id: tab.id) }
                )
                .onTapGesture {
                    tabManager.selectedTabID = tab.id
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.windowBackgroundColor))
        .accessibilityIdentifier("chat-tab-bar")
    }
}
