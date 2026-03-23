import Foundation

enum TranscriptDateFilter: Equatable {
    case anyTime
    case today
    case thisWeek
    case thisMonth
    case before(Date)
    case after(Date)
    case range(from: Date, to: Date)

    var dateInterval: (after: Date?, before: Date?) {
        let calendar = Calendar.current
        let now = Date()

        switch self {
        case .anyTime:
            return (nil, nil)
        case .today:
            let start = calendar.startOfDay(for: now)
            return (start, nil)
        case .thisWeek:
            guard let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return (nil, nil) }
            return (start, nil)
        case .thisMonth:
            guard let start = calendar.dateInterval(of: .month, for: now)?.start else { return (nil, nil) }
            return (start, nil)
        case let .before(date):
            return (nil, date)
        case let .after(date):
            return (date, nil)
        case let .range(from, to):
            return (from, to)
        }
    }

    var label: String {
        switch self {
        case .anyTime: "Any Time"
        case .today: "Today"
        case .thisWeek: "This Week"
        case .thisMonth: "This Month"
        case .before: "Before..."
        case .after: "After..."
        case .range: "Custom Range"
        }
    }
}

enum ConversationTypeFilter: String, CaseIterable {
    case all = "All"
    case chats = "Chats"
    case rooms = "Rooms"
}
