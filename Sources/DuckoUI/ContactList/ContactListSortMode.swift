enum ContactListSortMode: String, CaseIterable, Identifiable {
    case alphabetical, byStatus, recentConversation

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .alphabetical: "Alphabetical"
        case .byStatus: "By Status"
        case .recentConversation: "Recent Conversation"
        }
    }
}
